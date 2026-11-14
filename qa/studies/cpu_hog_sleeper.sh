#!/bin/sh
# Study driver: CPU hogs plus sleepers.
#
# Two shell processes spin on CPU while two others block on short timers. This
# mixes forced preemption (timer interrupt switches a busy task out) with
# timer wakeups and off-CPU waits, which is the shape of an interactive
# latency problem: a busy CPU delaying a sleeper's wakeup.
#
# Runs a bounded 4 s workload, records it with the published binary, and writes
# evidence to --out: window.ndjson, why.json/why.txt, metrics.json, incident/,
# evidence.json, summary.txt. Structural invariants only: whether a particular
# process was preempted is host-dependent, so no count equality is asserted.
#
# Usage: sh qa/studies/cpu_hog_sleeper.sh --out DIR [--binary PATH] [--dry-run]
# Live mode: root inside a disposable Linux VM with XSPROF_STUDY_VM_CONFIRM=1.
set -eu
STUDY_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
STUDY_DESC="two CPU hogs + two timer sleepers: preemption mixed with off-CPU wakeups, ~4s bounded"
# shellcheck source=lib.sh
. "$STUDY_ROOT/qa/studies/lib.sh"

HOGS=2
SLEEPERS=2
WORKLOAD_SECONDS=4

workload() {
    i=0
    while [ "$i" -lt "$HOGS" ]; do
        sh -c 'while :; do :; done' &
        STUDY_CHILDREN="$STUDY_CHILDREN $!"
        i=$((i + 1))
    done
    i=0
    while [ "$i" -lt "$SLEEPERS" ]; do
        sh -c 'n=0; while :; do sleep 0.05; n=$((n + 1)); done' &
        STUDY_CHILDREN="$STUDY_CHILDREN $!"
        i=$((i + 1))
    done
    studies_note "workload: $HOGS CPU hogs + $SLEEPERS timer sleepers (bounded ${WORKLOAD_SECONDS}s)"
    sleep "$WORKLOAD_SECONDS"
    studies_kill_children
}

main() {
    studies_parse_common "cpu_hog_sleeper" "$@"
    if [ "$STUDY_DRY" -eq 1 ]; then
        studies_dry_run "cpu_hog_sleeper" "$STUDY_DESC" \
            "start bounded recorder, run $HOGS CPU hogs + $SLEEPERS sleepers for ${WORKLOAD_SECONDS}s, capture --last 60s, run why/metrics/incident"
        return 0
    fi
    studies_require_vm "$STUDY_BIN"
    studies_begin "cpu_hog_sleeper" "$STUDY_DESC"
    studies_probe_capture "$STUDY_BIN" "$STUDY_OUT"
    studies_start_daemon "$STUDY_BIN" "$STUDY_OUT/state" "$STUDY_OUT"
    workload
    studies_wait_daemon
    studies_analyze "$STUDY_BIN" "$STUDY_OUT/state" "$STUDY_OUT"
    counters=$(studies_assert_evidence "$STUDY_OUT")
    studies_write_evidence "$STUDY_OUT" "cpu_hog_sleeper" "$STUDY_DESC" "$counters"
    studies_cleanup
    printf 'study_cpu_hog_sleeper: PASS\n'
}

main "$@"
