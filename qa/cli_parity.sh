#!/bin/sh
# Process-level CLI gate: read-only commands, canonical refusal, timeline shape.
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

"$BIN" help >"$TMP/help"
check_contains "$TMP/help" "xsprof" "help"
"$BIN" version >"$TMP/version"
check_contains "$TMP/version" "xsprof 0.2.0" "version"

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

"$BIN" preflight --json >"$TMP/preflight"
check_contains "$TMP/preflight" '"schema":"xsprof/preflight/v1"' "preflight"
check_contains "$TMP/preflight" '"host_mutation":false' "preflight"
"$BIN" capabilities --json >"$TMP/capabilities"
check_contains "$TMP/capabilities" '"host_mutation":false' "capabilities"
"$BIN" advise --json >"$TMP/advise"
check_contains "$TMP/advise" '"schema":"xsprof/advisor-report/v1"' "advise"
"$BIN" advise --md >"$TMP/advise-md"
check_contains "$TMP/advise-md" "Performance Advisor Report" "advise-md"

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
    echo "snapshot replay: bad PNG signature ($SIG)" >&2
    fail=1
fi

if "$BIN" preflight >/dev/null 2>&1; then
    echo "cli_parity: preflight without --json exited zero" >&2
    fail=1
fi
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
