#!/bin/sh
# Shared helpers for the deterministic latency study drivers in qa/studies/.
#
# Sourced by the scenario scripts (never executed directly). The drivers run a
# bounded scheduler workload inside a disposable Linux VM as root, record it
# with the published `xsprof` binary, and write compact evidence (window,
# why/metrics JSON, incident bundle, evidence.json, summary.txt) under a
# caller-provided output directory.
#
# Safety contract:
#   * host-safe by default: --dry-run validates the plan and writes nothing.
#   * live mode refuses to run unless it is root on Linux *and* the caller set
#     XSPROF_STUDY_VM_CONFIRM=1 to certify this is a disposable VM/root context.
#   * bounded: the recorder runs for STUDY_DAEMON_MS (6 s) and every workload is
#     capped by a wall-clock sleep plus a cleanup trap. No network, no host
#     policy writes, no `/proc` or `/sys` writes; all state lives under --out.
#   * evidence generators, not equality gates: they assert structural
#     invariants (non-empty window, canonical schemas, host_mutation=false,
#     bounded cause chains), never exact latency numbers.
#
# Requires GNU coreutils `sleep` with fractional seconds inside the VM.

STUDY_DAEMON_MS=6000
STUDY_STATE_NAME=state
STUDY_DAEMON_PID=
STUDY_CHILDREN=
STUDY_NAME=

studies_say() { printf 'study: %s\n' "$*"; }
studies_note() { printf 'study: %s\n' "$*"; }

studies_fail() {
    printf 'study: FAIL: %s\n' "$*" >&2
    exit 1
}

studies_usage_common() { # NAME DESCRIPTION
    cat <<EOF
Usage: sh qa/studies/$1.sh --out DIR [--binary PATH] [--dry-run] [--help]

$2

Options:
  --out DIR       evidence output directory (required for a live run)
  --binary PATH   xsprof binary to drive (default: \$XSPROF_BIN or
                  <repo>/zig-out/bin/xsprof)
  --dry-run       validate arguments/plan only; no workload, no writes,
                  no root required (host-safe)
  --help          show this help

Live mode requires: Linux, root, readable sched tracefs, and
XSPROF_STUDY_VM_CONFIRM=1 (certifies a disposable VM/root context). Never run
it on a production host.
EOF
}

# studies_parse_common args... fills STUDY_OUT/STUDY_BIN/STUDY_DRY and returns
# non-zero on --help/usage handled by the caller.
STUDY_OUT=
STUDY_BIN=
STUDY_DRY=0

studies_parse_common() { # NAME ARGS...
    name=$1
    shift
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --out)
                [ "$#" -ge 2 ] || studies_fail "--out requires a directory"
                STUDY_OUT=$2
                shift 2
                ;;
            --binary)
                [ "$#" -ge 2 ] || studies_fail "--binary requires a path"
                STUDY_BIN=$2
                shift 2
                ;;
            --dry-run)
                STUDY_DRY=1
                shift
                ;;
            -h | --help)
                studies_usage_common "$name" "$STUDY_DESC"
                exit 0
                ;;
            *)
                studies_usage_common "$name" "$STUDY_DESC" >&2
                studies_fail "unknown option: $1"
                ;;
        esac
    done
    if [ "$STUDY_DRY" -eq 0 ] && [ -z "$STUDY_OUT" ]; then
        studies_fail "--out DIR is required (evidence output directory)"
    fi
    if [ -z "$STUDY_BIN" ]; then
        STUDY_BIN=${XSPROF_BIN:-"$STUDY_ROOT/zig-out/bin/xsprof"}
    fi
    STUDY_NAME=$name
}

studies_cleanup() {
    if [ -n "$STUDY_DAEMON_PID" ]; then
        kill -TERM "$STUDY_DAEMON_PID" 2>/dev/null || true
        wait "$STUDY_DAEMON_PID" 2>/dev/null || true
        STUDY_DAEMON_PID=
    fi
    for pid in $STUDY_CHILDREN; do
        kill -TERM "$pid" 2>/dev/null || true
    done
    for pid in $STUDY_CHILDREN; do
        wait "$pid" 2>/dev/null || true
    done
    STUDY_CHILDREN=
}

studies_trap() {
    trap 'studies_cleanup' EXIT HUP INT TERM
}

# studies_kill_children terminates and reaps every workload child. Drivers call
# it after a fixed wall-clock bound so a stuck child can never extend a study.
studies_kill_children() {
    for pid in $STUDY_CHILDREN; do
        kill -TERM "$pid" 2>/dev/null || true
    done
    for pid in $STUDY_CHILDREN; do
        wait "$pid" 2>/dev/null || true
    done
    STUDY_CHILDREN=
}

# studies_require_vm BIN validates the live-mode preconditions. It never
# elevates and never guesses: a missing condition is a hard REFUSE.
studies_require_vm() {
    bin=$1
    [ "$(uname -s)" = Linux ] || studies_fail "live mode is Linux-only (found $(uname -s))"
    [ "$(id -u)" = 0 ] || studies_fail "live mode records perf events; run as root inside a disposable Linux VM"
    [ "${XSPROF_STUDY_VM_CONFIRM:-}" = 1 ] ||
        studies_fail "refusing live capture without XSPROF_STUDY_VM_CONFIRM=1 (disposable VM/root context marker)"
    [ -x "$bin" ] || studies_fail "xsprof binary not executable: $bin"
    tracefs=
    for candidate in /sys/kernel/tracing /sys/kernel/debug/tracing; do
        if [ -r "$candidate/events/sched/sched_switch/id" ]; then
            tracefs=$candidate
            break
        fi
    done
    [ -n "$tracefs" ] || studies_fail "readable sched_switch tracefs event not found (mount tracefs in the VM)"
    studies_note "preconditions: Linux root, tracefs=$tracefs, VM confirm marker set"
}

# studies_probe_capture BIN OUT runs one 1 s capture to prove perf is usable
# before starting the recorder. READY and DEGRADED are accepted (partial
# coverage is explicit in the summary); SKIP/REFUSE fail closed.
studies_probe_capture() {
    bin=$1
    out=$2
    studies_note "probe: 1s read-only capture to prove perf tracepoints work"
    "$bin" record --duration 1s --output "$out/probe.ndjson" 2>"$out/probe.summary" ||
        studies_fail "probe capture failed; see $out/probe.summary"
    grep -qE '"capability":"(READY|DEGRADED)"' "$out/probe.summary" ||
        studies_fail "probe capture did not reach READY/DEGRADED: $(head -c 200 "$out/probe.summary" 2>/dev/null)"
    grep -q '"host_mutation":false' "$out/probe.summary" ||
        studies_fail "probe capture summary is missing host_mutation=false"
}

# studies_start_daemon BIN STATE OUT starts the bounded foreground recorder and
# waits for its manifest. The daemon self-stops after STUDY_DAEMON_MS.
studies_start_daemon() {
    bin=$1
    state=$2
    out=$3
    mkdir -p "$state"
    studies_note "recorder: foreground daemon, ${STUDY_DAEMON_MS}ms bounded window -> $state"
    "$bin" daemon --foreground --dir "$state" --retain 10m --max-bytes 64M \
        --duration "$STUDY_DAEMON_MS" >"$out/daemon.out" 2>"$out/daemon.err" &
    STUDY_DAEMON_PID=$!
    i=0
    while [ "$i" -lt 50 ]; do
        if [ -f "$state/manifest.json" ]; then
            studies_note "recorder: manifest ready"
            return 0
        fi
        kill -0 "$STUDY_DAEMON_PID" 2>/dev/null || studies_fail "recorder daemon exited before writing manifest; see $out/daemon.err"
        sleep 0.1
        i=$((i + 1))
    done
    studies_fail "recorder manifest not written within 5s; see $out/daemon.err"
}

# studies_wait_daemon waits for the bounded recorder to stop. If it outlives
# the budget it is terminated and that is a failure (the workload is bounded).
studies_wait_daemon() {
    i=0
    while [ "$i" -lt 100 ]; do
        if ! kill -0 "$STUDY_DAEMON_PID" 2>/dev/null; then
            wait "$STUDY_DAEMON_PID" 2>/dev/null || true
            STUDY_DAEMON_PID=
            studies_note "recorder: stopped"
            return 0
        fi
        sleep 0.1
        i=$((i + 1))
    done
    studies_fail "recorder did not stop within 10s"
}

# studies_analyze BIN STATE OUT captures the window and runs why/metrics/
# incident. Every artifact is required; the caller asserts their content.
studies_analyze() {
    bin=$1
    state=$2
    out=$3
    studies_note "analysis: capture --last 60s, why, metrics, incident"
    "$bin" capture --last 60s --dir "$state" --out "$out/window.ndjson" >"$out/capture.out" 2>"$out/capture.err" ||
        studies_fail "capture failed; see $out/capture.err"
    [ -s "$out/window.ndjson" ] || studies_fail "captured window is empty"
    "$bin" why --input "$out/window.ndjson" --json >"$out/why.json" 2>"$out/why-json.err" ||
        studies_fail "why --json failed; see $out/why-json.err"
    "$bin" why --input "$out/window.ndjson" >"$out/why.txt" 2>"$out/why.err" ||
        studies_fail "why failed; see $out/why.err"
    "$bin" metrics --input "$out/window.ndjson" --json >"$out/metrics.json" 2>"$out/metrics.err" ||
        studies_fail "metrics failed; see $out/metrics.err"
    "$bin" incident --last 60s --dir "$state" --out "$out/incident" --max-window-bytes 8M \
        >"$out/incident.json" 2>"$out/incident.err" ||
        studies_fail "incident bundle failed; see $out/incident.err"
    studies_note "analysis: capture/why/metrics/incident artifacts written"
}

# studies_value TEXT KEY reads the first KEY=<digits> in a `why` text summary.
studies_value() { # TEXT FILE
    text_file=$1
    key=$2
    sed -n -e "s/^$key=\([0-9][0-9]*\).*/\1/p" \
        -e "s/.*[ {]$key=\([0-9][0-9]*\).*/\1/p" "$text_file" | head -1
}

# studies_assert_evidence OUT prints "key=value ..." counters after checking
# the structural invariants shared by all scenarios.
studies_assert_evidence() {
    out=$1
    for artifact in window.ndjson why.json why.txt metrics.json incident.json; do
        [ -s "$out/$artifact" ] || studies_fail "missing analysis artifact: $artifact"
    done
    for artifact in window.ndjson summary.json report.html trace.json; do
        [ -s "$out/incident/$artifact" ] || studies_fail "incident bundle is missing $artifact"
    done
    grep -q '"schema":"xsprof/why/v1"' "$out/why.json" || studies_fail "why.json wire schema missing"
    grep -q '"schema":"xsprof/metrics/v1"' "$out/metrics.json" || studies_fail "metrics.json wire schema missing"
    grep -q '"schema":"xsprof/incident-summary/v1"' "$out/incident/summary.json" ||
        studies_fail "incident summary schema missing"
    grep -q '"host_mutation":false' "$out/why.json" || studies_fail "why.json host_mutation missing"
    grep -q '"host_mutation":false' "$out/metrics.json" || studies_fail "metrics.json host_mutation missing"
    grep -q '"host_mutation":false' "$out/incident/summary.json" ||
        studies_fail "incident summary host_mutation missing"
    if grep -v '"host_mutation":false' "$out/window.ndjson" | grep -q .; then
        studies_fail "captured window contains a row that is not host_mutation=false"
    fi
    if grep -Eq 'https?://' "$out/incident/report.html"; then
        studies_fail "incident report.html contains an external URL"
    fi
    grep -q '"latency":{"causes":' "$out/why.json" || studies_fail "why latency causes missing"
    grep -q '"chains":\[' "$out/why.json" || studies_fail "why critical chains missing"

    header=$(grep '^switches=' "$out/why.txt" | head -1 || true)
    [ -n "$header" ] || studies_fail "why text header line missing"
    summary=$(grep '^latency:' "$out/why.txt" | head -1 || true)
    [ -n "$summary" ] || studies_fail "why latency summary line missing"
    window_rows=$(wc -l <"$out/window.ndjson" | tr -d ' ')
    events=$(grep -o '"events":[0-9]*' "$out/why.json" | head -1 | sed 's/.*://')
    switches=$(studies_value "$out/why.txt" switches)
    wakeups=$(studies_value "$out/why.txt" wakeups)
    offcpu=$(studies_value "$out/why.txt" offcpu_samples)
    causes=$(studies_value "$out/why.txt" causes)
    preemptions=$(studies_value "$out/why.txt" preemptions)
    edges=$(studies_value "$out/why.txt" chain_edges)
    roots=$(studies_value "$out/why.txt" chain_roots)
    for parsed in "$window_rows" "$events" "$switches" "$wakeups" "$offcpu" "$causes" "$preemptions" "$edges" "$roots"; do
        [ -n "$parsed" ] || studies_fail "cannot parse a structural counter from the analysis artifacts"
    done
    [ "$events" -gt 0 ] || studies_fail "why reports zero events for a non-empty window"
    [ "$switches" -gt 0 ] || studies_fail "window has no sched_switch rows (not scheduler evidence)"
    [ "$causes" -le "$offcpu" ] || studies_fail "cause totals exceed off-CPU samples"
    [ "$preemptions" -le "$switches" ] || studies_fail "preemptions exceed switches"
    [ "$roots" -le "$edges" ] || studies_fail "chain roots exceed chain edges"
    depths=$(grep '^  root=' "$out/why.txt" | sed -n 's/.*depth=\([0-9][0-9]*\).*/\1/p' || true)
    for depth in $depths; do
        [ "$depth" -le 8 ] || studies_fail "critical chain depth $depth exceeds the bound (8)"
    done

    printf 'window_rows=%s events=%s switches=%s wakeups=%s offcpu_samples=%s causes=%s preemptions=%s chain_edges=%s chain_roots=%s\n' \
        "$window_rows" "$events" "$switches" "$wakeups" "$offcpu" "$causes" "$preemptions" "$edges" "$roots"
}

# studies_write_evidence OUT NAME DESCRIPTION COUNTERS writes the compact
# machine report (evidence.json, canonical key order) and summary.txt.
studies_write_evidence() {
    out=$1
    name=$2
    description=$3
    counters=$4
    get() { # counters KEY
        for pair in $counters; do
            case "$pair" in
                "$1="*) printf '%s' "${pair#*=}" && return 0 ;;
            esac
        done
        return 1
    }
    window_rows=$(get window_rows) || studies_fail "missing window_rows counter"
    events=$(get events) || studies_fail "missing events counter"
    switches=$(get switches) || studies_fail "missing switches counter"
    wakeups=$(get wakeups) || studies_fail "missing wakeups counter"
    offcpu=$(get offcpu_samples) || studies_fail "missing offcpu_samples counter"
    causes=$(get causes) || studies_fail "missing causes counter"
    preemptions=$(get preemptions) || studies_fail "missing preemptions counter"
    edges=$(get chain_edges) || studies_fail "missing chain_edges counter"
    roots=$(get chain_roots) || studies_fail "missing chain_roots counter"
    version=$("$STUDY_BIN" version 2>/dev/null | head -1 || printf 'unknown')
    kernel=$(uname -r 2>/dev/null || printf 'unknown')
    started=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf 'unknown')
    printf '%s\n' \
        "{\"binary\":\"$STUDY_BIN\",\"binary_version\":\"$version\",\"causes\":$causes," \
        "\"chain_edges\":$edges,\"chain_roots\":$roots,\"description\":\"$description\"," \
        "\"events\":$events,\"host_mutation\":false,\"incident_artifacts\":true," \
        "\"kernel\":\"$kernel\",\"offcpu_samples\":$offcpu,\"preemptions\":$preemptions," \
        "\"scenario\":\"$name\",\"schema\":\"xsprof/study-evidence/v1\",\"started_utc\":\"$started\"," \
        "\"status\":\"PASS\",\"switches\":$switches,\"wakeups\":$wakeups,\"window_rows\":$window_rows}" \
        >"$out/evidence.json"
    {
        printf 'study: %s\n' "$name"
        printf 'description: %s\n' "$description"
        printf 'result: PASS\n'
        printf 'binary: %s (%s)\n' "$STUDY_BIN" "$version"
        printf 'kernel: %s\n' "$kernel"
        printf 'window: rows=%s events=%s switches=%s wakeups=%s\n' \
            "$window_rows" "$events" "$switches" "$wakeups"
        printf 'latency: offcpu_samples=%s causes=%s preemptions=%s chain_edges=%s chain_roots=%s\n' \
            "$offcpu" "$causes" "$preemptions" "$edges" "$roots"
        printf 'artifacts: window.ndjson why.json why.txt metrics.json incident/\n'
        printf 'note: structural invariants only; no exact latency number is asserted\n'
    } >"$out/summary.txt"
    studies_note "evidence: $out/evidence.json + $out/summary.txt"
}

# studies_dry_run NAME DESCRIPTION PLAN prints the plan and passes host-safely.
studies_dry_run() {
    name=$1
    description=$2
    plan=$3
    studies_note "DRY RUN scenario=$name"
    studies_note "description: $description"
    studies_note "plan: $plan"
    studies_note "live requirements: Linux, root, readable sched tracefs, XSPROF_STUDY_VM_CONFIRM=1"
    studies_note "dry run writes nothing and captures nothing"
    printf 'study_%s: PASS (dry run: plan validated; live run requires the disposable VM/root context)\n' "$name"
}

# studies_begin NAME DESCRIPTION sets up the driver, out dir, and cleanup trap.
studies_begin() {
    name=$1
    description=$2
    STUDY_NAME=$name
    studies_trap
    if [ -n "$STUDY_OUT" ]; then
        mkdir -p "$STUDY_OUT" || studies_fail "cannot create output directory: $STUDY_OUT"
        if [ -n "$(ls -A "$STUDY_OUT" 2>/dev/null)" ]; then
            studies_fail "output directory is not empty: $STUDY_OUT (use a fresh evidence directory)"
        fi
    fi
    studies_note "scenario=$name"
    studies_note "description: $description"
}
