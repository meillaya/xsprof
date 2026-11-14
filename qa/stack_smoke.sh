#!/bin/sh
# Experimental sampled-stack lane smoke.
#
# Default (analysis-only, no privileges, no perf): builds a tiny frame-pointer
# busy-loop fixture with the repo's Zig toolchain, synthesizes a canonical
# stack_sample capture plus its local maps sidecar in a temp dir, validates the
# wire/schema/metrics forms, runs the deterministic unit/integration tests for
# the sampler, symbolizer, folded writer, perf-script writer/parser and export
# command, and (when the `export` verb is wired into the CLI) checks the exact
# folded golden bytes against the fixture's own ELF symbols.
#
# --live (root inside a disposable Linux VM only, run by tools/vm_lab.sh):
# samples a known busy shell loop and a live `xsprof top` process, asserts at
# least one sampled stack, at least one user symbol and at least one kernel
# frame in the folded export, checks the maps sidecar and perf-script export,
# and records record-time overhead as a measurement (never a hard gate).
#
# Usage: sh qa/stack_smoke.sh [--analysis|--live] [--help]
# Exit:  0 PASS, 1 FAIL, 2 usage.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN=${XSPROF_BIN:-"$ROOT/zig-out/bin/xsprof"}
ZIG=${XSPROF_ZIG:-"$ROOT/tools/zig"}
MODE=analysis

: "${ZIG_GLOBAL_CACHE_DIR:=$ROOT/.zig-cache/global}"
: "${ZIG_LOCAL_CACHE_DIR:=$ROOT/.zig-cache}"
export ZIG_GLOBAL_CACHE_DIR ZIG_LOCAL_CACHE_DIR

usage() {
    cat <<'EOF'
Usage: sh qa/stack_smoke.sh [--analysis|--live] [--help]

  (default)  analysis-only: synthetic stack_sample capture + maps sidecar,
             schema/metrics validation, deterministic unit/integration tests,
             folded golden check when the export verb is wired. No root, no
             perf, no host policy change.
  --live     Linux disposable VM as root: sample a busy loop and a live
             `xsprof top`, assert user + kernel frames, perf-script export,
             and measure sampling overhead (measurement only).
  --help     show this help

Exit: 0 PASS, 1 FAIL, 2 usage.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
    --analysis) MODE=analysis ;;
    --live) MODE=live ;;
    -h | --help)
        usage
        exit 0
        ;;
    *)
        usage >&2
        exit 2
        ;;
    esac
    shift
done

fail() {
    printf '%s\n' "stack_smoke: FAIL: $*" >&2
    exit 1
}
say() { printf '%s\n' "stack_smoke: $*"; }

[ -x "$BIN" ] || fail "binary not found: $BIN (build first: ./tools/zig build)"
[ -x "$ZIG" ] || fail "zig toolchain not found: $ZIG (required by the analysis lane)"

TMP=$(mktemp -d)
cleanup() {
    if [ -n "${TOP_PID:-}" ]; then
        kill "$TOP_PID" 2>/dev/null || true
        wait "$TOP_PID" 2>/dev/null || true
    fi
    if [ -n "${LOOP_PID:-}" ]; then
        kill "$LOOP_PID" 2>/dev/null || true
        wait "$LOOP_PID" 2>/dev/null || true
    fi
    for load_pid in ${LOAD_A:-} ${LOAD_B:-}; do
        kill "$load_pid" 2>/dev/null || true
        wait "$load_pid" 2>/dev/null || true
    done
    if [ -n "${PROBE_PID:-}" ]; then
        kill "$PROBE_PID" 2>/dev/null || true
        wait "$PROBE_PID" 2>/dev/null || true
    fi
    rm -rf "$TMP"
}
trap cleanup EXIT HUP INT TERM

# Portable hex -> decimal (POSIX sh arithmetic is decimal-only).
hex2dec() {
    h=$1
    case "$h" in
    0x* | 0X*) h=${h#0x}; h=${h#0X} ;;
    esac
    d=0
    while [ -n "$h" ]; do
        c=${h%"${h#?}"}
        case "$c" in
        0) v=0 ;; 1) v=1 ;; 2) v=2 ;; 3) v=3 ;; 4) v=4 ;; 5) v=5 ;;
        6) v=6 ;; 7) v=7 ;; 8) v=8 ;; 9) v=9 ;;
        a | A) v=10 ;; b | B) v=11 ;; c | C) v=12 ;;
        d | D) v=13 ;; e | E) v=14 ;; f | F) v=15 ;;
        *) return 1 ;;
        esac
        d=$((d * 16 + v))
        h=${h#?}
    done
    printf '%s' "$d"
}

# JSON string escaping for the two local files this gate builds itself. The
# fixture paths under mktemp -d only contain [A-Za-z0-9._/-], but the maps
# walk can also see system library paths; quotes/backslashes are escaped and
# every other control byte is dropped rather than emitted raw.
json_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\000-\010\013\014\016-\037'
}

# The fixture prints its own exported function addresses and stays alive long
# enough for the maps snapshot; it is a normal unprivileged user process.
write_probe_source() {
    cat >"$TMP/stack_probe.zig" <<'EOF'
const std = @import("std");
const linux = std.os.linux;

var sink: u64 = 0;

export fn stack_probe_leaf(limit: u64) void {
    var i: u64 = 0;
    while (i < limit) : (i += 1) sink = sink *% 6364136223846793005 +% i;
}

export fn stack_probe_mid(limit: u64) void {
    stack_probe_leaf(limit);
}

pub fn main() noreturn {
    var buffer: [128]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "leaf=0x{x} mid=0x{x}\n", .{
        @intFromPtr(&stack_probe_leaf),
        @intFromPtr(&stack_probe_mid),
    }) catch "error\n";
    _ = linux.write(1, text.ptr, text.len);
    const request = linux.timespec{ .sec = 1, .nsec = 500_000_000 };
    _ = linux.nanosleep(&request, null);
    linux.exit(0);
}
EOF
}

build_probe() {
    write_probe_source
    say "analysis: building the frame-pointer fixture with the pinned toolchain"
    "$ZIG" build-exe "$TMP/stack_probe.zig" \
        -femit-bin="$TMP/stack_probe" --cache-dir "$TMP/zig-cache" >"$TMP/probe-build.log" 2>&1 ||
        fail "cannot build the fixture: $(tail -n 3 "$TMP/probe-build.log")"
    [ -x "$TMP/stack_probe" ] || fail "fixture binary missing after build"
}

# Starts the fixture, reads its printed symbol addresses, snapshots
# /proc/PID/maps into the local sidecar, and waits for it to exit.
run_probe_and_maps() { # CAPTURE_PATH
    capture=$1
    "$TMP/stack_probe" >"$TMP/probe.addr" 2>"$TMP/probe.err" &
    PROBE_PID=$!
    tries=0
    while [ ! -s "$TMP/probe.addr" ]; do
        tries=$((tries + 1))
        [ "$tries" -lt 100 ] || fail "fixture did not print its addresses"
        sleep 0.02
    done
    addresses=$(head -n 1 "$TMP/probe.addr")
    PROBE_LEAF_HEX=$(printf '%s' "$addresses" | sed -n 's/.*leaf=\(0x[0-9a-f]*\).*/\1/p')
    PROBE_MID_HEX=$(printf '%s' "$addresses" | sed -n 's/.*mid=\(0x[0-9a-f]*\).*/\1/p')
    [ -n "$PROBE_LEAF_HEX" ] && [ -n "$PROBE_MID_HEX" ] || fail "cannot parse fixture addresses: $addresses"
    PROBE_LEAF=$(hex2dec "$PROBE_LEAF_HEX")
    PROBE_MID=$(hex2dec "$PROBE_MID_HEX")
    [ -n "$PROBE_LEAF" ] && [ -n "$PROBE_MID" ] || fail "cannot convert fixture addresses"

    # Local maps sidecar: same reader/writer contract as the sampler's
    # `session.maps.ndjson`, one bounded row per path-backed mapping.
    sidecar=$(printf '%s' "$capture" | sed 's/\.ndjson$//').maps.ndjson
    PROBE_PID_RECORD=$PROBE_PID
    : >"$sidecar"
    while IFS= read -r line; do
        # shellcheck disable=SC2086
        set -- $line
        [ "$#" -ge 6 ] || continue
        range=$1
        perms=$2
        offset_hex=$3
        shift 5
        path="$*"
        # Only the fixture's own module is needed for analysis-time
        # symbolization; skip fixmap/vsyscall-style mappings whose unsigned
        # addresses do not fit portable shell arithmetic.
        [ "$path" = "$TMP/stack_probe" ] || continue
        start_hex=${range%%-*}
        end_hex=${range#*-}
        start=$(hex2dec "$start_hex") || continue
        end=$(hex2dec "$end_hex") || continue
        offset=$(hex2dec "$offset_hex") || continue
        escaped=$(json_escape "$path")
        printf '{"capture":"start","end":%s,"host_mutation":false,"offset":%s,"path":"%s","perms":"%s","pid":%s,"schema":"xsprof/session-maps/v0","start":%s,"ts_ns":1}\n' \
            "$end" "$offset" "$escaped" "$perms" "$PROBE_PID" "$start" >>"$sidecar"
    done <"/proc/$PROBE_PID/maps"
    [ -s "$sidecar" ] || fail "maps sidecar is empty"
    wait "$PROBE_PID" 2>/dev/null || true
    PROBE_PID=
}

write_capture() { # CAPTURE_PATH
    capture=$1
    {
        printf '%s\n' '{"a":0,"b":0,"c":0,"comm":"stack_probe","cpu":1,"event":"marker","host_mutation":false,"pid":-1,"schema":"xsprof/event/v1","tid":-1,"ts_ns":1}'
        # Two identical sampled stacks (leaf first, like PERF_SAMPLE_CALLCHAIN)
        # plus an explicit loss marker; frames are the fixture's real addresses.
        second=2
        while [ "$second" -ge 1 ]; do
            printf '{"a":%s,"b":0,"c":0,"comm":"stack_probe","cpu":2,"event":"stack_sample","host_mutation":false,"pid":%s,"schema":"xsprof/event/v1","stack":[%s,%s],"tid":%s,"ts_ns":%s000000}\n' \
                "$PROBE_LEAF" "$PROBE_PID_RECORD" "$PROBE_LEAF" "$PROBE_MID" "$PROBE_PID_RECORD" "$second"
            second=$((second - 1))
        done
        printf '%s\n' '{"a":0,"b":0,"c":0,"cpu":-1,"detail":"sample_loss stacks_perf_ring lost=3","event":"marker","host_mutation":false,"pid":-1,"schema":"xsprof/event/v1","tid":-1,"ts_ns":3000000}'
    } >"$capture"
    [ -s "$capture" ] || fail "synthetic capture is empty"
}

check_unit_tests() {
    say "analysis: deterministic unit/integration tests (sampler, maps, symbolizer, folded, perf-script, export)"
    "$ZIG" test "$ROOT/src/stacks_test.zig" >"$TMP/unit.log" 2>&1 ||
        fail "unit/integration tests failed: $(tail -n 5 "$TMP/unit.log")"
    grep -q "All .* tests passed\\|tests passed" "$TMP/unit.log" ||
        fail "unit test summary missing: $(tail -n 3 "$TMP/unit.log")"
}

check_wire_forms() { # CAPTURE_PATH
    capture=$1
    "$BIN" validate --schema event.v1 --file "$capture" >"$TMP/validate-event.txt" 2>&1 ||
        fail "synthetic capture failed event.v1 validation: $(cat "$TMP/validate-event.txt")"
    grep -q '"host_mutation":true' "$capture" && fail "synthetic capture claims host_mutation=true"
    grep -q '"event":"stack_sample"' "$capture" || fail "synthetic capture has no stack_sample rows"

    "$BIN" metrics --input "$capture" --json >"$TMP/metrics.json" 2>"$TMP/metrics.err" ||
        fail "metrics failed on the sampled capture: $(cat "$TMP/metrics.err")"
    grep -q '"stack_samples":2' "$TMP/metrics.json" || fail "metrics did not count 2 stack samples"
    grep -q '"stack_frames":4' "$TMP/metrics.json" || fail "metrics did not count 4 stack frames"
    grep -q '"offcpu_samples":' "$TMP/metrics.json" || fail "metrics lost its causal fields"
    "$BIN" validate --schema metrics.v1 --file "$TMP/metrics.json" >"$TMP/validate-metrics.txt" 2>&1 ||
        fail "sampled metrics failed metrics.v1 validation: $(cat "$TMP/validate-metrics.txt")"

    # Additive capture-summary `source: perf_sampling` + `stacks` object: the
    # exact canonical shape record emits. The tracepoint summary (no stacks)
    # must keep validating too, so old byte samples stay compatible.
    printf '%s\n' '{"capability":"READY","duration_ms":1000,"events_captured":3,"faults_major":0,"faults_minor":0,"host_mutation":false,"lost":3,"output":"session.ndjson","page_faults":0,"sched_migrations":0,"sched_switches":0,"sched_wakeups":0,"schema":"xsprof/capture-summary/v1","source":"perf_sampling","stacks":{"dropped":3,"freq_hz":199,"max_frames":32,"mode":"cpu","samples":2}}' >"$TMP/summary-sampled.json"
    "$BIN" validate --schema capture-summary.v1 --file "$TMP/summary-sampled.json" >"$TMP/validate-summary.txt" 2>&1 ||
        fail "sampled capture-summary failed schema validation: $(cat "$TMP/validate-summary.txt")"
    printf '%s\n' '{"capability":"READY","duration_ms":300,"events_captured":1,"faults_major":0,"faults_minor":0,"host_mutation":false,"lost":0,"output":"-","page_faults":0,"sched_migrations":0,"sched_switches":0,"sched_wakeups":0,"schema":"xsprof/capture-summary/v1","source":"perf_tracepoint"}' >"$TMP/summary-legacy.json"
    "$BIN" validate --schema capture-summary.v1 --file "$TMP/summary-legacy.json" >"$TMP/validate-summary-legacy.txt" 2>&1 ||
        fail "legacy capture-summary no longer validates: $(cat "$TMP/validate-summary-legacy.txt")"
    say "analysis: capture and metrics are schema-valid; samples/frames counted, no latency invented"
}

export_wired() {
    set +e
    "$BIN" export --format folded >/dev/null 2>&1
    rc=$?
    set -e
    [ "$rc" -eq 2 ]
}

check_export_cli() { # CAPTURE_PATH
    capture=$1
    if ! export_wired; then
        say "note: the export verb is not wired into this tree yet; the folded/symbolizer path is covered by the unit/integration tests above"
        return 0
    fi
    say "analysis: CLI folded + perf-script export against the fixture's own ELF symbols"
    "$BIN" export --format folded --input "$capture" --binary "$TMP/stack_probe" \
        >"$TMP/folded.txt" 2>"$TMP/folded.err" ||
        fail "folded export failed: $(cat "$TMP/folded.err")"
    EXPECTED='stack_probe;stack_probe_mid;stack_probe_leaf 2'
    [ "$(cat "$TMP/folded.txt")" = "$EXPECTED" ] ||
        fail "folded golden drift: expected '$EXPECTED', got '$(cat "$TMP/folded.txt")'"
    grep -q '"samples":2' "$TMP/folded.err" || fail "folded summary does not count 2 samples"
    grep -q '"dropped":3' "$TMP/folded.err" || fail "folded summary lost the explicit loss count"
    grep -q '"host_mutation":false' "$TMP/folded.err" || fail "folded summary missing host_mutation=false"

    "$BIN" export --format perf-script --input "$capture" --binary "$TMP/stack_probe" \
        >"$TMP/script.txt" 2>"$TMP/script.err" ||
        fail "perf-script export failed: $(cat "$TMP/script.err")"
    grep -q 'cpu-clock:' "$TMP/script.txt" || fail "perf-script export missing the sample header"
    grep -q 'stack_probe_leaf+0x' "$TMP/script.txt" || fail "perf-script export missing symbolized frames"
}

analysis_mode() {
    say "analysis: no privileges, no perf, host policy untouched"
    build_probe
    run_probe_and_maps "$TMP/capture.ndjson"
    # The fixture has exited by now; the wire rows carry its pid so the
    # capture is internally consistent (the maps sidecar keeps the same pid).
    [ -n "$PROBE_PID_RECORD" ] || PROBE_PID_RECORD=1
    write_capture "$TMP/capture.ndjson"
    check_wire_forms "$TMP/capture.ndjson"
    check_unit_tests
    check_export_cli "$TMP/capture.ndjson"
    say "PASS"
}

# Frames starting with [k] are kernel; plain tokens are resolved user symbols;
# 0x-prefixed tokens are explicitly unresolved user addresses.
count_folded_frames() { # FOLDED_FILE PATTERN
    awk -F';' -v pattern="$2" '
        /^$/ { next }
        {
            count = 0
            for (i = 2; i <= NF; i++) {
                token = $i
                sub(/ [0-9]+$/, "", token)
                if (token ~ pattern) count++
            }
            total += count
        }
        END { print total + 0 }
    ' "$1"
}

measure_overhead_baseline() {
    start=$(date +%s%N)
    sh -c 'i=0; while [ "$i" -lt 200000 ]; do i=$((i + 1)); done'
    end=$(date +%s%N)
    echo $(((end - start) / 1000000))
}

live_mode() {
    [ "$(uname -s)" = "Linux" ] || fail "--live is Linux only"
    [ "$(id -u)" = "0" ] || fail "--live samples perf events; run as root inside a disposable Linux VM"
    export_wired || fail "the export verb is not wired into this binary; wire export_cmd in the registry first"
    say "live: sampling inside the disposable VM only; no host policy change"

    "$BIN" record --sample cpu --stacks fp --pid "$$" --freq 99 --duration 1s \
        --output "$TMP/self.ndjson" >"$TMP/self.out" 2>"$TMP/self.err" ||
        fail "sampling the lane's own shell failed: $(cat "$TMP/self.err")"
    grep -qE '"capability":"(READY|DEGRADED)"' "$TMP/self.err" ||
        fail "sampling summary is not READY/DEGRADED: $(head -c 200 "$TMP/self.err")"

    baseline_ms=$(measure_overhead_baseline)
    sh -c 'i=0; while [ "$i" -lt 200000 ]; do i=$((i + 1)); done' &
    LOOP_PID=$!
    start_ns=$(date +%s%N)
    "$BIN" record --sample cpu --stacks fp --pid "$LOOP_PID" --freq 199 \
        --max-stack-frames 32 --duration 5s --output "$TMP/loop.ndjson" \
        >"$TMP/loop.out" 2>"$TMP/loop.err" || fail "sampling the busy loop failed: $(cat "$TMP/loop.err")"
    end_ns=$(date +%s%N)
    wait "$LOOP_PID" 2>/dev/null || true
    LOOP_PID=
    sampled_ms=$(((end_ns - start_ns) / 1000000))
    if [ "$baseline_ms" -gt 0 ]; then
        overhead_x100=$(((sampled_ms - baseline_ms) * 100 / baseline_ms))
        say "live: busy-loop wall time baseline=${baseline_ms}ms sampled=${sampled_ms}ms overhead=${overhead_x100}bpct (measurement only)"
    else
        say "live: busy-loop wall time sampled=${sampled_ms}ms (baseline unmeasurable; measurement only)"
    fi
    grep -q '"event":"stack_sample"' "$TMP/loop.ndjson" || fail "sampled busy loop produced no stack_sample rows"
    grep -q '"host_mutation":false' "$TMP/loop.err" || fail "loop sampling summary missing host_mutation=false"
    [ -s "${TMP}/loop.maps.ndjson" ] || fail "loop sampling wrote no maps sidecar"
    grep -q '"schema":"xsprof/session-maps/v0"' "${TMP}/loop.maps.ndjson" ||
        fail "maps sidecar is not the bounded local session-maps format"

    say "live: sampling a live xsprof top process for symbols and kernel frames"
    sh -c 'while :; do :; done' &
    LOAD_A=$!
    sh -c 'while :; do :; done' &
    LOAD_B=$!
    "$BIN" top --duration 30s --interval 100ms --json --top 5 >"$TMP/top.json" 2>"$TMP/top.err" &
    TOP_PID=$!
    sleep 0.5
    "$BIN" record --sample cpu --stacks fp --pid "$TOP_PID" --freq 499 \
        --max-stack-frames 32 --duration 5s --output "$TMP/stacks.ndjson" \
        >"$TMP/stacks.out" 2>"$TMP/stacks.summary" ||
        fail "sampling the top process failed: $(cat "$TMP/stacks.summary")"
    kill "$TOP_PID" 2>/dev/null || true
    wait "$TOP_PID" 2>/dev/null || true
    TOP_PID=
    kill "$LOAD_A" 2>/dev/null || true
    kill "$LOAD_B" 2>/dev/null || true
    wait "$LOAD_A" 2>/dev/null || true
    wait "$LOAD_B" 2>/dev/null || true
    LOAD_A=
    LOAD_B=

    grep -qE '"capability":"(READY|DEGRADED)"' "$TMP/stacks.summary" ||
        fail "stack sampling summary is not READY/DEGRADED: $(cat "$TMP/stacks.summary")"
    grep -q '"host_mutation":false' "$TMP/stacks.summary" || fail "stack sampling summary missing host_mutation=false"
    grep -q '"stacks":{"dropped":' "$TMP/stacks.summary" || fail "stack sampling summary missing the stacks object"
    [ -s "$TMP/stacks.maps.ndjson" ] || fail "stack sampling wrote no maps sidecar"
    grep -q '"schema":"xsprof/session-maps/v0"' "$TMP/stacks.maps.ndjson" ||
        fail "stacks maps sidecar is not the bounded local session-maps format"
    "$BIN" validate --schema capture-summary.v1 --file "$TMP/stacks.summary" >"$TMP/validate-summary.txt" 2>&1 ||
        fail "sampling summary failed capture-summary.v1 validation: $(cat "$TMP/validate-summary.txt")"
    SAMPLES=$(grep -c '"event":"stack_sample"' "$TMP/stacks.ndjson" || true)
    [ "$SAMPLES" -ge 1 ] || fail "no stack_sample events were captured"
    grep -v '"host_mutation":false' "$TMP/stacks.ndjson" >/dev/null && fail "sampled stream has a mutation row"
    say "live: stack samples=$SAMPLES"

    # Symbolization: the sampled process is this same xsprof binary, so
    # --binary resolves real user frames; /proc/kallsyms is root-readable.
    KALLSYMS=/proc/kallsyms
    [ -r "$KALLSYMS" ] || KALLSYMS=
    if [ -n "$KALLSYMS" ]; then
        "$BIN" export --format folded --input "$TMP/stacks.ndjson" --binary "$BIN" --kallsyms "$KALLSYMS" \
            >"$TMP/folded.txt" 2>"$TMP/folded.err" ||
            fail "folded export of the live capture failed: $(cat "$TMP/folded.err")"
    else
        "$BIN" export --format folded --input "$TMP/stacks.ndjson" --binary "$BIN" \
            >"$TMP/folded.txt" 2>"$TMP/folded.err" ||
            fail "folded export of the live capture failed: $(cat "$TMP/folded.err")"
    fi
    [ -s "$TMP/folded.txt" ] || fail "folded export is empty"
    user_symbols=$(count_folded_frames "$TMP/folded.txt" '^[A-Za-z_.$@]')
    kernel_frames=$(count_folded_frames "$TMP/folded.txt" '^\[k\]')
    [ "$user_symbols" -ge 1 ] || fail "folded export has no resolved user symbol: $(head -n 3 "$TMP/folded.txt")"
    [ "$kernel_frames" -ge 1 ] || fail "folded export has no kernel frame: $(head -n 3 "$TMP/folded.txt")"
    say "live: folded user_symbols=$user_symbols kernel_frames=$kernel_frames stacks=$(wc -l <"$TMP/folded.txt" | tr -d ' ')"

    if [ -n "$KALLSYMS" ]; then
        "$BIN" export --format perf-script --input "$TMP/stacks.ndjson" --binary "$BIN" --kallsyms "$KALLSYMS" \
            >"$TMP/script.txt" 2>"$TMP/script.err" ||
            fail "perf-script export of the live capture failed: $(cat "$TMP/script.err")"
    else
        "$BIN" export --format perf-script --input "$TMP/stacks.ndjson" --binary "$BIN" \
            >"$TMP/script.txt" 2>"$TMP/script.err" ||
            fail "perf-script export of the live capture failed: $(cat "$TMP/script.err")"
    fi
    grep -q 'cpu-clock:' "$TMP/script.txt" || fail "perf-script export missing sample headers"
    say "live: perf-script export bytes=$(wc -c <"$TMP/script.txt" | tr -d ' ')"
    say "PASS"
}

if [ "$MODE" = live ]; then
    live_mode
else
    analysis_mode
fi
