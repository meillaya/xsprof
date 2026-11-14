#!/bin/sh
# Noise-aware compare regression-gate smoke: analysis only, tool-light, and
# privilege-free. Builds small synthetic scheduler captures, then proves the
# three contract exit codes:
#
#   * noise control    -> 0 (a shift smaller than the run-to-run noise floor)
#   * injected regression -> 3 (candidate p95 far outside the noise floor)
#   * usage error      -> 2 (--min-runs shortfall before any file is read)
#
# It also checks the canonical `xsprof/compare/v1` wire shape (schema string,
# host_mutation, fail_reasons, noise_pct) and validates the report against the
# committed compare schema. No root, no network, no host mutation, no display.
#
# Usage: sh qa/compare_ci_smoke.sh [--help]
# Exit:  0 PASS, 1 assertion or setup failure, 2 usage error.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN=${XSPROF_BIN:-"$ROOT/zig-out/bin/xsprof"}
TMP=
trap 'if [ -n "$TMP" ]; then rm -rf "$TMP"; fi' EXIT HUP INT TERM

usage() {
    cat <<'EOF'
Usage: sh qa/compare_ci_smoke.sh

Run the noise-aware compare gate against synthetic captures:
  - multi-run noise control exits 0 and reports the noise floor
  - an injected regression exits 3 with a fail reason
  - a usage error exits 2
  - the report validates against schemas/xsprof/compare.v1.schema.json

Environment:
  XSPROF_BIN  xsprof binary to test (default: <repo>/zig-out/bin/xsprof)

Exit: 0 PASS, 1 assertion/setup failure, 2 usage error.
EOF
}

fail() {
    echo "compare_ci_smoke: FAIL: $*" >&2
    exit 1
}

note() {
    echo "compare_ci_smoke: $*"
}

# emit_capture PATH SAMPLES WAIT_US writes one canonical NDJSON capture with
# SAMPLES wakeup-to-run waits of WAIT_US microseconds for a single "worker"
# task. Every wait is preceded by a blocking switch-out and a wakeup, so the
# metrics index attributes exactly one latency sample per loop.
emit_capture() { # PATH SAMPLES WAIT_US
    path=$1
    samples=$2
    wait_ns=$(($3 * 1000))
    : >"$path"
    ts=0
    printf '{"schema":"xsprof/event/v1","event":"sched_switch","host_mutation":false,"ts_ns":0,"cpu":0,"pid":1,"tid":1,"a":1,"b":0,"c":1,"comm":"worker"}\n' >>"$path"
    i=0
    while [ "$i" -lt "$samples" ]; do
        ts=$((ts + 1000000))
        printf '{"schema":"xsprof/event/v1","event":"sched_switch","host_mutation":false,"ts_ns":%s,"cpu":0,"pid":0,"tid":0,"a":0,"b":1,"c":1}\n' "$ts" >>"$path"
        ts=$((ts + 1000000))
        printf '{"schema":"xsprof/event/v1","event":"sched_wakeup","host_mutation":false,"ts_ns":%s,"cpu":0,"pid":0,"tid":0,"a":1,"comm":"worker"}\n' "$ts" >>"$path"
        ts=$((ts + wait_ns))
        printf '{"schema":"xsprof/event/v1","event":"sched_switch","host_mutation":false,"ts_ns":%s,"cpu":0,"pid":1,"tid":1,"a":1,"b":0,"c":0,"comm":"worker"}\n' "$ts" >>"$path"
        i=$((i + 1))
    done
}

# expect_status PATH COMMAND... runs COMMAND, redirecting stdout to PATH, and
# asserts the exit code requested through EXPECTED_STATUS.
expect_status() { # EXPECTED_STATUS OUT_PATH COMMAND...
    expected=$1
    out_path=$2
    shift 2
    status=0
    "$@" >"$out_path" 2>"$out_path.stderr" || status=$?
    if [ "$status" -ne "$expected" ]; then
        message=$(cat "$out_path.stderr" 2>/dev/null || true)
        fail "expected exit $expected, got $status${message:+: $message}"
    fi
}

check_report() { # PATH
    report=$1
    grep -q '"schema":"xsprof/compare/v1"' "$report" || fail "wire schema string"
    grep -q '"host_mutation":false' "$report" || fail "host_mutation must be false"
    "$BIN" validate --schema "$ROOT/schemas/xsprof/compare.v1.schema.json" \
        --file "$report" >/dev/null 2>&1 || fail "report does not validate against compare.v1"
}

main() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h | --help)
                usage
                return 0
                ;;
            *)
                echo "compare_ci_smoke: unknown argument: $1" >&2
                usage >&2
                return 2
                ;;
        esac
    done
    if [ ! -x "$BIN" ]; then
        fail "binary not found: $BIN (build with ./tools/zig build)"
    fi
    TMP=$(mktemp -d "${TMPDIR:-/tmp}/xsprof-compare-ci.XXXXXX")
    note "binary: $BIN"

    # Baseline: one dense run (100 x 1ms waits, p95 1024us) plus one sparse
    # run (one 3ms wait, run p95 4096us). The pooled baseline p95 stays at
    # 1024us, but the run-to-run spread is 3072us -> a 300% noise floor.
    emit_capture "$TMP/base-dense.ndjson" 100 1000
    emit_capture "$TMP/base-sparse.ndjson" 1 3000

    # Noise control: candidate is consistently slower (p95 2048us, +100%) but
    # inside the baseline's 300% run-to-run noise, so the gate must pass.
    emit_capture "$TMP/control-a.ndjson" 100 1500
    emit_capture "$TMP/control-b.ndjson" 1 1500
    expect_status 0 "$TMP/control.json" \
        "$BIN" compare \
        --base "$TMP/base-dense.ndjson" --base "$TMP/base-sparse.ndjson" \
        --candidate "$TMP/control-a.ndjson" --candidate "$TMP/control-b.ndjson" \
        --fail-on wait.p95=0% --json
    check_report "$TMP/control.json"
    grep -q '"base_runs":2' "$TMP/control.json" || fail "base_runs must count repeated captures"
    grep -q '"candidate_runs":2' "$TMP/control.json" || fail "candidate_runs must count repeated captures"
    grep -q '"noise_pct":300' "$TMP/control.json" || fail "noise floor must be reported"
    grep -q '"fail_reasons":\[\]' "$TMP/control.json" || fail "noise control must have no fail reasons"
    grep -q '"regression":false' "$TMP/control.json" || fail "noise control must not regress"

    # Injected regression: p95 jumps to 16384us (+1500%), far outside the noise
    # floor, so the gate must fail with exit 3 and a machine-readable reason.
    emit_capture "$TMP/regress-a.ndjson" 100 12000
    emit_capture "$TMP/regress-b.ndjson" 1 12000
    expect_status 3 "$TMP/regression.json" \
        "$BIN" compare \
        --base "$TMP/base-dense.ndjson" --base "$TMP/base-sparse.ndjson" \
        --candidate "$TMP/regress-a.ndjson" --candidate "$TMP/regress-b.ndjson" \
        --fail-on wait.p95=0% --json
    check_report "$TMP/regression.json"
    grep -q '"fail_reasons":\["wait.p95:worker' "$TMP/regression.json" || fail "missing fail reason"
    grep -q '"regression":true' "$TMP/regression.json" || fail "regression must be flagged"

    # Usage error: --min-runs 3 cannot be satisfied by two baseline captures
    # (and one candidate capture) and must exit 2 before reading data.
    expect_status 2 "$TMP/usage.json" \
        "$BIN" compare \
        --base "$TMP/base-dense.ndjson" --base "$TMP/base-sparse.ndjson" \
        --candidate "$TMP/control-a.ndjson" --min-runs 3 --json
    expect_status 2 "$TMP/usage-rule.json" \
        "$BIN" compare --base "$TMP/base-dense.ndjson" \
        --candidate "$TMP/control-a.ndjson" --fail-on wait.p90=5 --json

    # A single capture per side keeps the legacy threshold-only semantics.
    expect_status 3 "$TMP/legacy.json" \
        "$BIN" compare --base "$TMP/base-dense.ndjson" \
        --candidate "$TMP/control-a.ndjson" --fail-on wait.p95=10% --json
    grep -q '"base_runs":1' "$TMP/legacy.json" || fail "single-run report must show base_runs 1"

    note "PASS (noise-aware compare: control exit 0, regression exit 3, usage exit 2)"
}

main "$@"
