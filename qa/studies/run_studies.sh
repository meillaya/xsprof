#!/bin/sh
# Deterministic latency study runner: evidence generators for a release bundle.
#
# Runs the three bounded scheduler scenarios in qa/studies/ against one xsprof
# binary and writes compact evidence under --out:
#
#   <out>/pingpong/            two-process blocking/wakeup ping-pong
#   <out>/sleep_wake_burst/    eight parallel timer sleep/wake bursts
#   <out>/cpu_hog_sleeper/     CPU hogs mixed with timer sleepers
#   <out>/run-summary.json     per-scenario PASS/FAIL + artifact paths
#   <out>/run-summary.txt      human-readable run summary
#
# Each scenario writes window.ndjson, why.json, why.txt, metrics.json,
# incident/{window.ndjson,summary.json,report.html,trace.json}, evidence.json,
# and summary.txt. Assertions are structural (canonical schemas,
# host_mutation=false, non-empty scheduler evidence, bounded chains); no exact
# latency number is compared. These are evidence generators for a release
# bundle, not CI equality gates.
#
# Host safety:
#   * `--dry-run` is host-safe: it validates every driver and prints its plan,
#     requires no root, captures nothing, and writes no evidence.
#   * live mode refuses unless it runs as root on Linux inside a disposable VM
#     context certified by XSPROF_STUDY_VM_CONFIRM=1. It never elevates, never
#     touches host scheduler policy, and never uses the network.
#
# Usage: sh qa/studies/run_studies.sh [--out DIR] [--binary PATH]
#                                     [--scenario NAME] [--dry-run] [--help]
# Exit: 0 all requested scenarios PASS (or dry run), 1 scenario failure, 2 usage.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
BIN=${XSPROF_BIN:-"$ROOT/zig-out/bin/xsprof"}
ALL_SCENARIOS="pingpong sleep_wake_burst cpu_hog_sleeper"
OUT=
DRY=0
SELECTED=

usage() {
    cat <<'EOF'
Usage: sh qa/studies/run_studies.sh [options]

Run the deterministic latency study scenarios and write release-bundle
evidence (window/why/metrics/incident + compact evidence.json per scenario).

Options:
  --out DIR          evidence output directory
                     (default: <repo>/dist/studies/<UTC-timestamp>)
  --binary PATH      xsprof binary to drive (default: $XSPROF_BIN or
                     <repo>/zig-out/bin/xsprof)
  --scenario NAME    run one scenario: pingpong | sleep_wake_burst |
                     cpu_hog_sleeper (default: all three)
  --dry-run          validate every driver and print the plan; host-safe, no
                     root, no capture, no evidence writes
  --help             show this help

Live mode requires Linux, root, readable sched tracefs, and
XSPROF_STUDY_VM_CONFIRM=1. Never run it on a production host: run it inside the
write-scoped disposable VM and attach the output to the release evidence.

Exit: 0 PASS (or dry run), 1 scenario failure, 2 usage error.
EOF
}

fail() {
    echo "run_studies: FAIL: $*" >&2
    exit 1
}

note() {
    echo "run_studies: $*"
}

scenario_known() { # NAME
    for known in $ALL_SCENARIOS; do
        [ "$known" = "$1" ] && return 0
    done
    return 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --out)
            [ "$#" -ge 2 ] || { usage >&2; fail "--out requires a directory"; }
            OUT=$2
            shift 2
            ;;
        --binary)
            [ "$#" -ge 2 ] || { usage >&2; fail "--binary requires a path"; }
            BIN=$2
            shift 2
            ;;
        --scenario)
            [ "$#" -ge 2 ] || { usage >&2; fail "--scenario requires a name"; }
            scenario_known "$2" || { usage >&2; fail "unknown scenario: $2"; }
            SELECTED=$2
            shift 2
            ;;
        --dry-run)
            DRY=1
            shift
            ;;
        -h | --help)
            usage
            return_help=1
            shift
            ;;
        *)
            usage >&2
            fail "unknown option: $1"
            ;;
    esac
done
if [ "${return_help:-0}" -eq 1 ]; then
    exit 0
fi

if [ -n "$SELECTED" ]; then
    SCENARIOS=$SELECTED
else
    SCENARIOS=$ALL_SCENARIOS
fi

if [ "$DRY" -eq 0 ]; then
    [ -n "$OUT" ] || OUT="$ROOT/dist/studies/$(date -u +%Y%m%dT%H%M%SZ)"
    mkdir -p "$OUT" || fail "cannot create output directory: $OUT"
fi

logs=
if [ "$DRY" -eq 0 ]; then
    logs=$OUT
else
    logs=$(mktemp -d "${TMPDIR:-/tmp}/xsprof-studies-dry.XXXXXX") ||
        fail "cannot create a temporary directory"
    trap 'rm -rf "$logs"' EXIT HUP INT TERM
fi

passed=
failed=
for scenario in $SCENARIOS; do
    script="$ROOT/qa/studies/$scenario.sh"
    [ -f "$script" ] || fail "missing scenario driver: qa/studies/$scenario.sh"
    sh -n "$script" || fail "scenario driver has a shell syntax error: qa/studies/$scenario.sh"
    log="$logs/$scenario.run.log"
    if [ "$DRY" -eq 1 ]; then
        note "plan: $scenario"
        if ! sh "$script" --dry-run --binary "$BIN" >"$log" 2>&1; then
            cat "$log" 2>/dev/null || true
            failed="$failed $scenario"
            continue
        fi
        cat "$log"
        if ! grep -Fq "study_$scenario: PASS" "$log"; then
            failed="$failed $scenario"
            continue
        fi
        passed="$passed $scenario"
    else
        note "run: $scenario -> $OUT/$scenario"
        if ! sh "$script" --out "$OUT/$scenario" --binary "$BIN" >"$log" 2>&1; then
            cat "$log" 2>/dev/null || true
            failed="$failed $scenario"
            continue
        fi
        cat "$log"
        if ! grep -Fq "study_$scenario: PASS" "$log"; then
            failed="$failed $scenario"
            continue
        fi
        passed="$passed $scenario"
    fi
done

if [ -n "$failed" ]; then
    fail "scenario(s) failed:$failed"
fi

if [ "$DRY" -eq 1 ]; then
    note "PASS (dry run: scenarios planned:$passed; no capture, no evidence writes)"
    note "live mode requires Linux root inside a disposable VM with XSPROF_STUDY_VM_CONFIRM=1"
    exit 0
fi

version=$("$BIN" version 2>/dev/null | head -1 || printf 'unknown')
kernel=$(uname -r 2>/dev/null || printf 'unknown')
started=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf 'unknown')
{
    printf '{"binary":"%s","binary_version":"%s","host_mutation":false,"kernel":"%s",' \
        "$BIN" "$version" "$kernel"
    printf '"out":"%s","scenarios":[' "$OUT"
    sep=
    for scenario in $passed; do
        printf '%s{"evidence":"%s","scenario":"%s","status":"PASS"}' \
            "$sep" "$OUT/$scenario/evidence.json" "$scenario"
        sep=,
    done
    printf '],"schema":"xsprof/study-run/v1","started_utc":"%s","status":"PASS"}\n' "$started"
} >"$OUT/run-summary.json"
{
    printf 'xsprof latency studies: PASS\n'
    printf 'binary: %s (%s)\n' "$BIN" "$version"
    printf 'kernel: %s\n' "$kernel"
    printf 'out: %s\n' "$OUT"
    for scenario in $passed; do
        printf '  %s: PASS (evidence: %s)\n' "$scenario" "$OUT/$scenario/evidence.json"
    done
    printf 'note: structural invariants only; these are evidence generators, not equality gates\n'
} >"$OUT/run-summary.txt"

note "evidence: $OUT/run-summary.json"
note "PASS (scenarios:$passed; attach $OUT to the release bundle)"
