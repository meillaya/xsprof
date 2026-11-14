#!/bin/sh
# Causal latency attribution smoke.
#
# Default (analysis-only, no privileges): runs `xsprof why` on committed
# fixtures and asserts the v0.7 causal fields, the canonical bytes of the
# `why --json` golden, schema conformance, and the structural invariants that
# must hold for any window (cause totals <= measured off-CPU samples,
# preemptions <= switches, bounded chain depth). No exact latency number is
# asserted: durations are noisy by nature.
#
# --live (root inside a disposable Linux VM only): records 3 s, then repeats the
# structural invariants on the real window. It never asserts a number that a
# real machine may produce differently, never changes host policy, and never
# elevates privileges; it refuses to run as non-root.
#
# Usage: sh qa/latency_smoke.sh [--live]
# Exit:  0 PASS, 1 FAIL, 2 usage.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN=${XSPROF_BIN:-"$ROOT/zig-out/bin/xsprof"}
FIXTURE="$ROOT/fixtures/ui/latency-mixed.ndjson"
GOLDEN="$ROOT/tests/golden/root/why_latency_golden.json"
MODE=analysis

usage() {
    cat <<'EOF'
Usage: sh qa/latency_smoke.sh [--live] [--help]

  (default)  analysis-only: why --json on committed fixtures, golden bytes,
             schema validation, structural invariants. No root.
  --live     record 3 s and check structural latency invariants.
             Linux disposable VM as root only; never a production host.
  --help     show this help

Exit: 0 PASS, 1 FAIL, 2 usage.
EOF
}

fail() {
    echo "latency_smoke: FAIL: $*" >&2
    exit 1
}
say() { echo "latency_smoke: $*"; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --live) MODE=live ;;
        --analysis) MODE=analysis ;;
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

[ -x "$BIN" ] || fail "binary not found: $BIN (build first: ./tools/zig build)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

# value KEY reads KEY=<digits> from the first line in $1 that starts KEY=... The
# caller passes the machine-readable `latency:`/header line of `why` text.
value() { # line key
    printf '%s\n' "$1" | sed -n \
        -e "s/^$2=\([0-9][0-9]*\).*/\1/p" \
        -e "s/.*[ {]$2=\([0-9][0-9]*\).*/\1/p" | head -1
}

# assert_why_invariants TEXT_JSON TEXT_WHY checks the structural guarantees of
# one analysis window. Exit code 1 through fail() on violation.
assert_why_invariants() { # json_file text_file fixture_label
    json_file=$1
    text_file=$2
    label=$3
    grep -q '"schema":"xsprof/why/v1"' "$json_file" || fail "$label: why schema missing"
    grep -q '"host_mutation":false' "$json_file" || fail "$label: why host_mutation missing"
    if grep -q '"host_mutation":true' "$json_file"; then
        fail "$label: why claims host_mutation=true"
    fi
    grep -q '"latency":{"causes":' "$json_file" || fail "$label: latency causes missing"
    grep -q '"chains":\[' "$json_file" || fail "$label: critical chains missing"
    grep -q '"offcpu_samples":' "$json_file" || fail "$label: offcpu_samples missing"
    grep -q '"preemptions":' "$json_file" || fail "$label: preemptions missing"
    grep -q '"chain_cycles_cut":' "$json_file" || fail "$label: chain counters missing"

    header=$(grep '^switches=' "$text_file" | head -1 || true)
    [ -n "$header" ] || fail "$label: why text header missing"
    summary=$(grep '^latency:' "$text_file" | head -1 || true)
    [ -n "$summary" ] || fail "$label: why latency summary line missing"

    switches=$(value "$header" switches)
    offcpu=$(value "$summary" offcpu_samples)
    causes=$(value "$summary" causes)
    preemptions=$(value "$summary" preemptions)
    unresolved=$(value "$summary" offcpu_unresolved)
    edges=$(value "$summary" chain_edges)
    roots=$(value "$summary" chain_roots)
    for parsed in "$switches" "$offcpu" "$causes" "$preemptions" "$unresolved" "$edges" "$roots"; do
        [ -n "$parsed" ] || fail "$label: cannot parse why summary counters"
    done
    [ "$causes" -le "$offcpu" ] || fail "$label: cause totals ($causes) exceed off-CPU samples ($offcpu)"
    [ "$preemptions" -le "$switches" ] || fail "$label: preemptions ($preemptions) exceed switches ($switches)"
    [ "$unresolved" -le "$switches" ] || fail "$label: unresolved off-CPU ($unresolved) exceeds switches ($switches)"
    [ "$roots" -le "$edges" ] || fail "$label: chain roots ($roots) exceed edges ($edges)"

    depths=$(grep '^  root=' "$text_file" | sed -n 's/.*depth=\([0-9][0-9]*\).*/\1/p' || true)
    for depth in $depths; do
        [ "$depth" -le 8 ] || fail "$label: chain depth $depth exceeds the bound (8)"
    done
    cycles=$(value "$summary" chain_cycles)
    [ -n "$cycles" ] || fail "$label: cannot parse chain_cycles"
}

analysis_mode() {
    cd "$ROOT"

    # 1. Fixtures are canonical event rows: schema-checked and mutation-free.
    "$BIN" validate --schema event.v1 --file fixtures/ui/latency-mixed.ndjson --json >"$TMP/validate.json" ||
        fail "latency fixture failed event.v1 validation"
    grep -q '"ok":true' "$TMP/validate.json" || fail "latency fixture not canonical"
    if grep -v '"host_mutation":false' fixtures/ui/latency-mixed.ndjson | grep -q .; then
        fail "latency fixture contains a host_mutation=true row"
    fi

    # 2. Canonical why JSON plus byte-stable golden.
    "$BIN" why --input fixtures/ui/latency-mixed.ndjson --json >"$TMP/why.json" ||
        fail "why failed on the latency fixture"
    cmp -s "$TMP/why.json" "$GOLDEN" ||
        fail "why golden drift: regenerate tests/golden/root/why_latency_golden.json deliberately"
    "$BIN" validate --schema why.v1 --file "$GOLDEN" --json >"$TMP/why-validate.json" ||
        fail "why golden failed why.v1 validation"
    grep -q '"ok":true' "$TMP/why-validate.json" || fail "why golden not canonical"

    "$BIN" why --input fixtures/ui/latency-mixed.ndjson >"$TMP/why.txt" ||
        fail "why text failed on the latency fixture"
    assert_why_invariants "$TMP/why.json" "$TMP/why.txt" "latency fixture"
    say "analysis: golden stable, schema valid, invariants hold"

    # 3. A real committed capture with legacy prev_state values must not break
    # attribution (unknown/other causes stay explicit, never crash).
    "$BIN" why --input fixtures/real/macos-vm-sched.ndjson --json >"$TMP/real.json" ||
        fail "why failed on the real capture fixture"
    "$BIN" why --input fixtures/real/macos-vm-sched.ndjson >"$TMP/real.txt" ||
        fail "why text failed on the real capture fixture"
    assert_why_invariants "$TMP/real.json" "$TMP/real.txt" "real fixture"
    say "analysis: real capture attribution ok"

    say "PASS"
}

live_mode() {
    [ "$(uname -s)" = Linux ] || fail "--live is Linux only"
    [ "$(id -u)" = 0 ] || fail "--live records perf events; run as root inside a disposable Linux VM"
    say "live: recording 3s (disposable VM only; no host policy change)"
    "$BIN" record --duration 3s --output "$TMP/rec.ndjson" \
        >"$TMP/record.out" 2>"$TMP/record.summary" || fail "record failed"
    grep -qE '"capability":"(READY|DEGRADED)"' "$TMP/record.summary" ||
        fail "record did not reach READY/DEGRADED: $(head -c 200 "$TMP/record.summary")"
    grep -q '"host_mutation":false' "$TMP/record.summary" || fail "record summary mutation flag missing"
    if grep -v '"host_mutation":false' "$TMP/rec.ndjson" | grep -q .; then
        fail "recorded stream contains a host_mutation=true row"
    fi

    "$BIN" why --input "$TMP/rec.ndjson" --json >"$TMP/why.json" ||
        fail "why failed on the recorded window"
    "$BIN" why --input "$TMP/rec.ndjson" >"$TMP/why.txt" ||
        fail "why text failed on the recorded window"
    grep -q '"tasks":\[{' "$TMP/why.json" || fail "live: no task rows in the window"
    grep -q '"pairs":\[{' "$TMP/why.json" || fail "live: no wakeup pairs in the window"
    assert_why_invariants "$TMP/why.json" "$TMP/why.txt" "live window"

    # Unknown attribution must stay bounded by the measured samples; an
    # all-unknown window would mean the decoder is broken, not a busy host.
    summary=$(grep '^latency:' "$TMP/why.txt" | head -1)
    offcpu=$(value "$summary" offcpu_samples)
    causes=$(value "$summary" causes)
    lines=$(wc -l <"$TMP/rec.ndjson" | tr -d ' ')
    say "live: events=$lines offcpu_samples=$offcpu causes=$causes"
    say "PASS"
}

if [ "$MODE" = live ]; then
    live_mode
else
    analysis_mode
fi
