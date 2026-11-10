#!/bin/sh
# Process-level CLI gate: read-only commands, canonical refusal, timeline shape,
# UI-first surface, and compact/legacy recorder extraction.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN="$ROOT/zig-out/bin/xsprof"
[ -x "$BIN" ] || { echo "cli_parity: build first (zig build)" >&2; exit 1; }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

fail=0
check_contains() { # file needle label
    if ! grep -q -- "$2" "$1"; then
        echo "cli_parity: $3: missing '$2'" >&2
        fail=1
    fi
}
check_not_contains() { # file needle label
    if grep -q -- "$2" "$1"; then
        echo "cli_parity: $3: unexpected '$2'" >&2
        fail=1
    fi
}

"$BIN" >"$TMP/quickstart"
check_contains "$TMP/quickstart" "xsprof" "quickstart"
check_contains "$TMP/quickstart" "help --all" "quickstart-all"
check_contains "$TMP/quickstart" "native console" "quickstart-native"
check_not_contains "$TMP/quickstart" "browser console" "quickstart-no-browser"
check_not_contains "$TMP/quickstart" "xsprof serve" "quickstart-no-serve"
"$BIN" help >"$TMP/help"
check_contains "$TMP/help" "xsprof" "help"
check_contains "$TMP/help" "PRIMARY COMMANDS" "help-primary"
check_not_contains "$TMP/help" "advise" "help-hides-automation"
check_not_contains "$TMP/help" "serve" "help-hides-serve"
"$BIN" help --all >"$TMP/help-all"
check_contains "$TMP/help-all" "advise" "help-all"
check_contains "$TMP/help-all" "capture" "help-all-capture"
check_contains "$TMP/help-all" "verify" "help-all-verify"
check_not_contains "$TMP/help-all" "serve" "help-all-no-serve"
"$BIN" help demo >"$TMP/help-demo"
check_contains "$TMP/help-demo" "native console" "help-demo-native"
"$BIN" demo --help >/dev/null
"$BIN" help top >"$TMP/help-top"
check_contains "$TMP/help-top" "top" "help-top"
"$BIN" top --help >/dev/null
"$BIN" why --help >/dev/null
"$BIN" completions bash >"$TMP/completions"
check_contains "$TMP/completions" "top" "completions"
check_contains "$TMP/completions" "ui" "completions-ui"
check_contains "$TMP/completions" "demo" "completions-demo"
check_not_contains "$TMP/completions" "advise" "completions-primary"
check_not_contains "$TMP/completions" "serve" "completions-no-serve"
"$BIN" completions bash --all >"$TMP/completions-all"
check_contains "$TMP/completions-all" "advise" "completions-all"
"$BIN" doctor >"$TMP/doctor"
check_contains "$TMP/doctor" "status=" "doctor-human"
check_not_contains "$TMP/doctor" "web_assets" "doctor-no-web-assets"
# Version comes from the package manifest so a release bump does not break the gate.
"$BIN" version >"$TMP/version"
EXPECTED_VERSION=$(sed -n 's/.*\.version = "\(.*\)".*/\1/p' "$ROOT/build.zig.zon" | head -1)
check_contains "$TMP/version" "xsprof $EXPECTED_VERSION" "version"
XSPROF_NO_UI=1 "$BIN" >"$TMP/no-ui"
check_contains "$TMP/no-ui" "xsprof" "no-ui-quickstart"

for verb in load attach enable mutate apply sched-ext-attach setaffinity setpriority bind; do
    if "$BIN" "$verb" >"$TMP/refusal" 2>/dev/null; then
        echo "cli_parity: unsafe verb '$verb' exited zero" >&2
        fail=1
    fi
    check_contains "$TMP/refusal" '"host_mutation":false' "refusal($verb)"
    check_contains "$TMP/refusal" '"event":"refusal"' "refusal($verb)"
done

if "$BIN" no-such-verb >"$TMP/unknown" 2>/dev/null; then
    echo "cli_parity: unknown verb exited zero" >&2
    fail=1
fi
check_contains "$TMP/unknown" '"event":"refusal"' "unknown"

# The web surface is removed; the verb must fail with an explicit reason.
if "$BIN" serve >"$TMP/removed" 2>"$TMP/removed.err"; then
    echo "cli_parity: removed serve verb exited zero" >&2
    fail=1
fi
check_contains "$TMP/removed.err" "removed in 0.5.0" "removed-serve"

# demo is native-only: on a headless Linux host it explains the failure and
# never opens a window. macOS skips this (a real display is presumed).
if [ "$(uname -s)" = Linux ]; then
    if env -u DISPLAY -u WAYLAND_DISPLAY "$BIN" demo >"$TMP/demo.out" 2>"$TMP/demo.err"; then
        echo "cli_parity: demo exited zero without a display" >&2
        fail=1
    fi
    check_contains "$TMP/demo.err" "display unavailable" "demo-headless-reason"
fi

"$BIN" preflight --json >"$TMP/preflight"
check_contains "$TMP/preflight" '"schema":"xsprof/preflight/v1"' "preflight"
check_contains "$TMP/preflight" '"host_mutation":false' "preflight"
"$BIN" capabilities --json >"$TMP/capabilities"
check_contains "$TMP/capabilities" '"host_mutation":false' "capabilities"
"$BIN" advise --json >"$TMP/advise"
check_contains "$TMP/advise" '"schema":"xsprof/advisor-report/v1"' "advise"
"$BIN" advise --md >"$TMP/advise-md"
check_contains "$TMP/advise-md" "Performance Advisor Report" "advise-md"
"$BIN" why --input "$ROOT/fixtures/real/macos-vm-sched.ndjson" --json >"$TMP/why"
check_contains "$TMP/why" '"schema":"xsprof/why/v1"' "why"
check_contains "$TMP/why" '"pairs":\[' "why-pairs"
check_contains "$TMP/why" '"out_of_order":9' "why-order"
"$BIN" advise --input "$ROOT/fixtures/real/vm-fragmented.ndjson" >"$TMP/advise-input"
check_contains "$TMP/advise-input" '"schema":"xsprof/advisor-report/v1"' "advise-input"
check_contains "$TMP/advise-input" '"rules":' "advise-input"
check_contains "$TMP/advise-input" '"id":"allocator-fragmentation"' "advise-input"
check_contains "$TMP/advise-input" '"status":"finding"' "advise-input"
check_contains "$TMP/advise-input" '"status":"skip"' "advise-input"
check_contains "$TMP/advise-input" '"host_mutation":false' "advise-input"
if "$BIN" advise --input "$TMP/does-not-exist.ndjson" >/dev/null 2>&1; then
    echo "cli_parity: missing advise input exited zero" >&2
    fail=1
fi

# Legacy NDJSON state (pre-0.4) must stay readable.
STATE="$TMP/state"
mkdir -p "$STATE/segments"
cat >"$STATE/segments/0-0.ndjson" <<'EOF'
{"schema":"xsprof/event/v1","event":"marker","ts_ns":0,"cpu":-1,"pid":7,"tid":7,"comm":"xsprof","detail":"capture_owner","host_mutation":false}
{"schema":"xsprof/event/v1","event":"marker","ts_ns":0,"cpu":-1,"detail":"host_memory buddy_fragmentation=0.75","host_mutation":false}
{"schema":"xsprof/event/v1","event":"sched_switch","ts_ns":61000000000,"cpu":0,"pid":7,"tid":7,"a":9,"b":0,"c":0,"comm":"worker","host_mutation":false}
{"schema":"xsprof/event/v1","event":"sched_wakeup","ts_ns":61100000000,"cpu":0,"pid":7,"tid":7,"a":9,"comm":"worker","host_mutation":false}
{"schema":"xsprof/event/v1","event":"sched_wakeup","ts_ns":61200000000,"cpu":0,"pid":7,"tid":7,"a":9,"comm":"worker","host_mutation":false}
EOF
BODY_BYTES=$(wc -c <"$STATE/segments/0-0.ndjson" | tr -d ' ')
NOW_S=$(date +%s)
START_S=$((NOW_S - 120))
START_NS="${START_S}000000000"
END_NS="${NOW_S}000000000"
cat >"$STATE/manifest.json" <<EOF
{"host_mutation":false,"max_age_ms":600000,"max_bytes":2147483648,"schema":"xsprof/recorder-manifest/v1","segments":[{"bytes":$BODY_BYTES,"closed":true,"codec":"ndjson","end_mono_ns":70000000000,"end_wall_ns":$END_NS,"events":5,"path":"segments/0-0.ndjson","start_mono_ns":0,"start_wall_ns":$START_NS}],"session_id":"incident-smoke","started_mono_ns":0,"started_wall_ns":$START_NS,"state":"stopped","updated_wall_ns":$END_NS}
EOF
"$BIN" incident --last 60s --dir "$STATE" --out "$TMP/incident" --max-window-bytes 1M >"$TMP/incident-result"
check_contains "$TMP/incident-result" '"schema":"xsprof/incident-result/v1"' "incident-result"
check_contains "$TMP/incident-result" '"host_mutation":false' "incident-result"
for artifact in window.ndjson summary.json report.html trace.json; do
    if [ ! -s "$TMP/incident/$artifact" ]; then
        echo "cli_parity: incident missing $artifact" >&2
        fail=1
    fi
done
check_contains "$TMP/incident/summary.json" '"schema":"xsprof/incident-summary/v1"' "incident-summary"
check_contains "$TMP/incident/summary.json" '"host_mutation":false' "incident-summary"
check_contains "$TMP/incident/summary.json" '"status":"finding"' "incident-summary"
check_contains "$TMP/incident/report.html" "xsprof incident" "incident-report"
check_contains "$TMP/incident/report.html" "window.ndjson" "incident-report"
if grep -Eq 'https?://' "$TMP/incident/report.html"; then
    echo "cli_parity: incident report has an external URL" >&2
    fail=1
fi

# Compact v1 golden segment: decode must match the committed canonical extract.
GSTATE="$TMP/golden-state"
mkdir -p "$GSTATE/segments"
cp "$ROOT/tests/golden/recorder/segments/segment_v1_golden.xsraw" "$GSTATE/segments/"
GBYTES=$(wc -c <"$GSTATE/segments/segment_v1_golden.xsraw" | tr -d ' ')
GEVENTS=$(wc -l <"$ROOT/tests/golden/recorder/segment_v1_golden.ndjson" | tr -d ' ')
cat >"$GSTATE/manifest.json" <<EOF
{"host_mutation":false,"max_age_ms":600000,"max_bytes":2147483648,"raw_codec":"compact_v1","schema":"xsprof/recorder-manifest/v1","segments":[{"bytes":$GBYTES,"closed":true,"codec":"compact_v1","end_mono_ns":70000000000,"end_wall_ns":$END_NS,"events":$GEVENTS,"path":"segments/segment_v1_golden.xsraw","start_mono_ns":0,"start_wall_ns":$START_NS}],"session_id":"golden-compact","started_mono_ns":0,"started_wall_ns":$START_NS,"state":"stopped","updated_wall_ns":$END_NS}
EOF
"$BIN" capture --last 1h --dir "$GSTATE" --out "$TMP/golden.ndjson"
if ! cmp -s "$TMP/golden.ndjson" "$ROOT/tests/golden/recorder/segment_v1_golden.ndjson"; then
    echo "cli_parity: compact golden extraction differs from the canonical extract" >&2
    fail=1
fi
check_contains "$TMP/golden.ndjson" '"host_mutation":false' "golden-extract"
check_contains "$TMP/golden.ndjson" '"event":"sched_switch"' "golden-switch"
if grep -q 'capture_corrupt\|capture_truncated' "$TMP/golden.ndjson"; then
    echo "cli_parity: clean golden extraction emitted a gap marker" >&2
    fail=1
fi
if ! "$BIN" verify --dir "$GSTATE" --json >"$TMP/verify"; then
    echo "cli_parity: verify did not exit zero on the clean golden state" >&2
    fail=1
fi
check_contains "$TMP/verify" '"schema":"xsprof/recorder-verify/v1"' "verify-schema"
check_contains "$TMP/verify" '"state":"READY"' "verify-clean"
check_contains "$TMP/verify" '"host_mutation":false' "verify-safety"

HSTATE="$TMP/history-state"
mkdir -p "$HSTATE/metrics"
HNS="$(date +%s)000000000"
cat >"$HSTATE/metrics/${HNS}-0.json" <<'EOF'
{"cpus":[],"events":10,"faults_major":0,"faults_minor":2,"first_us":0,"host_mutation":false,"last_us":1,"lost":0,"migrations":1,"quantiles":{},"schema":"xsprof/metrics/v1","switches":5,"tasks":[],"unnecessary_wakeups":1,"unresolved_wakeups":0,"wakeups":2}
EOF
"$BIN" history --dir "$HSTATE" --last 1h >"$TMP/history"
check_contains "$TMP/history" '"schema":"xsprof/history/v1"' "history"
check_contains "$TMP/history" '"switches":5' "history"
check_contains "$TMP/history" '"host_mutation":false' "history-safety"
check_contains "$TMP/history" '"sidecars":1' "history"
"$BIN" history --dir "$HSTATE" --last 1h --md >"$TMP/history-md"
check_contains "$TMP/history-md" "xsprof sidecar history" "history-md"
"$BIN" pressure --json >"$TMP/pressure" 2>/dev/null || true
check_contains "$TMP/pressure" '"schema":"xsprof/pressure/v1"' "pressure"
check_contains "$TMP/pressure" '"host_mutation":false' "pressure"
"$BIN" cgroup --json >"$TMP/cgroup" 2>/dev/null || true
check_contains "$TMP/cgroup" '"schema":"xsprof/cgroup/v1"' "cgroup"
check_contains "$TMP/cgroup" '"host_mutation":false' "cgroup"

"$BIN" timeline --input "$ROOT/tests/golden/root/journal_v1_golden.json" >"$TMP/trace"
check_contains "$TMP/trace" '"traceEvents"' "timeline"
check_contains "$TMP/trace" '"displayTimeUnit":"ms"' "timeline-units"
"$BIN" timeline --input "$ROOT/tests/golden/root/journal_v1_golden.json" \
    --output "$TMP/trace-output" >/dev/null
check_contains "$TMP/trace-output" '"traceEvents"' "timeline-output"

"$BIN" snapshot --out "$TMP/snapshot.png" --width 320 --height 200 >/dev/null
SIG=$(od -An -tx1 -N8 "$TMP/snapshot.png" | tr -d ' \n')
if [ "$SIG" != "89504e470d0a1a0a" ]; then
    echo "snapshot: bad PNG signature ($SIG)" >&2
    fail=1
fi
"$BIN" snapshot --replay "$ROOT/fixtures/ui/healthy.ndjson" --view timeline \
    --out "$TMP/timeline.png" --width 640 --height 360 >/dev/null
SIG=$(od -An -tx1 -N8 "$TMP/timeline.png" | tr -d ' \n')
if [ "$SIG" != "89504e470d0a1a0a" ]; then
    echo "cli_parity: snapshot replay bad PNG signature ($SIG)" >&2
    fail=1
fi

if "$BIN" preflight >/dev/null 2>&1; then
    echo "cli_parity: preflight without --json exited zero" >&2
    fail=1
fi
if "$BIN" top --duration 1 --json >"$TMP/top" 2>/dev/null; then
    echo "cli_parity: top unexpectedly succeeded on this host" >&2
    fail=1
fi
check_contains "$TMP/top" '"host_mutation":false' "top-refusal"
if "$BIN" record --duration 1 >"$TMP/record" 2>/dev/null; then
    echo "cli_parity: record unexpectedly succeeded on this host" >&2
    fail=1
fi
check_contains "$TMP/record" '"host_mutation":false' "record-refusal"
if "$BIN" bpf-gate --json >"$TMP/bpf" 2>/dev/null; then
    echo "cli_parity: bpf-gate unexpectedly READY on this host" >&2
    fail=1
fi
check_contains "$TMP/bpf" '"host_mutation":false' "bpf-gate"
check_contains "$TMP/bpf" '"schema":"xsprof/bpf-gate/v1"' "bpf-gate"
if "$BIN" timeline --input "$TMP/does-not-exist" >/dev/null 2>&1; then
    echo "cli_parity: missing journal exited zero" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "cli_parity: FAIL" >&2
    exit 1
fi
echo "cli_parity: PASS"