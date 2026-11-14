#!/bin/sh
# Study driver: sleep/wake burst.
#
# Eight processes sleep on short timers in parallel and wake on the timer tick,
# producing repeated wakeup bursts across CPUs: the scheduler's timer-wakeup
# path, wakeup->run latency, and runqueue wakeups are all exercised without any
# external workload tool.
#
# Runs a bounded ~4 s workload, records it with the published binary, and
# writes evidence to --out: window.ndjson, why.json/why.txt, metrics.json,
# incident/, evidence.json, summary.txt. Structural invariants only; no exact
# latency or count equality is asserted (host noise is data here).
#
# Usage: sh qa/studies/sleep_wake_burst.sh --out DIR [--binary PATH] [--dry-run]
# Live mode: root inside a disposable Linux VM with XSPROF_STUDY_VM_CONFIRM=1.
set -eu
STUDY_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
STUDY_DESC="eight parallel timer sleepers: repeated sleep/wake bursts, ~4s bounded"
# shellcheck source=lib.sh
. "$STUDY_ROOT/qa/studies/lib.sh"

SLEEPERS=8
ITERATIONS=36
SLEEP_SECONDS=0.1
WORKLOAD_SECONDS=4

workload() {
    i=0
    while [ "$i" -lt "$SLEEPERS" ]; do
        sh -c '
            n=0
            while [ "$n" -lt "$1" ]; do
                sleep "$2"
                n=$((n + 1))
            done
        ' sh "$ITERATIONS" "$SLEEP_SECONDS" &
        STUDY_CHILDREN="$STUDY_CHILDREN $!"
        i=$((i + 1))
    done
    studies_note "workload: $SLEEPERS sleepers x $ITERATIONS timer waits of ${SLEEP_SECONDS}s (bounded ${WORKLOAD_SECONDS}s)"
    sleep "$WORKLOAD_SECONDS"
    studies_kill_children
}

main() {
    studies_parse_common "sleep_wake_burst" "$@"
    if [ "$STUDY_DRY" -eq 1 ]; then
        studies_dry_run "sleep_wake_burst" "$STUDY_DESC" \
            "start bounded recorder, run $SLEEPERS timeout sleepers for ${WORKLOAD_SECONDS}s, capture --last 60s, run why/metrics/incident"
        return 0
    fi
    studies_require_vm "$STUDY_BIN"
    studies_begin "sleep_wake_burst" "$STUDY_DESC"
    studies_probe_capture "$STUDY_BIN" "$STUDY_OUT"
    studies_start_daemon "$STUDY_BIN" "$STUDY_OUT/state" "$STUDY_OUT"
    workload
    studies_wait_daemon
    studies_analyze "$STUDY_BIN" "$STUDY_OUT/state" "$STUDY_OUT"
    counters=$(studies_assert_evidence "$STUDY_OUT")
    studies_write_evidence "$STUDY_OUT" "sleep_wake_burst" "$STUDY_DESC" "$counters"
    studies_cleanup
    printf 'study_sleep_wake_burst: PASS\n'
}

main "$@"
