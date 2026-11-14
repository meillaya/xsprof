#!/bin/sh
# Study driver: two-process blocking/wakeup ping-pong (futex-like wake pairs).
#
# Two shell processes alternate a token over named pipes: each `read` blocks
# off-CPU and each write wakes the peer, so a correct scheduler produces a
# long alternating sched_switch/sched_wakeup chain. This is the same wait/wake
# pattern a futex ping-pong shows, implemented with POSIX pipes so it needs no
# compiler and no third-party runtime inside the VM.
#
# Runs a bounded 4 s workload, records it with the published binary, and writes
# evidence to --out: window.ndjson, why.json/why.txt, metrics.json, incident/,
# evidence.json, summary.txt. Structural invariants only; never an equality
# gate on latency numbers.
#
# Usage: sh qa/studies/pingpong.sh --out DIR [--binary PATH] [--dry-run]
# Live mode: root inside a disposable Linux VM with XSPROF_STUDY_VM_CONFIRM=1.
set -eu
STUDY_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
STUDY_DESC="two-process pipe ping-pong: alternating blocking read + wakeup, ~4s bounded"
# shellcheck source=lib.sh
. "$STUDY_ROOT/qa/studies/lib.sh"

ROUND_TRIPS=900
WORKLOAD_SECONDS=4

workload() {
    fifo_a=$STUDY_OUT/work/a.fifo
    fifo_b=$STUDY_OUT/work/b.fifo
    rm -f "$fifo_a" "$fifo_b"
    mkfifo "$fifo_a" "$fifo_b"

    # Each child opens both FIFOs read-write so open(2) never blocks; both then
    # wait for a token and pass it on. Opening a FIFO O_RDWR keeps a reader on
    # the pipe, which is what makes the alternating read/write safe.
    sh -c '
        fa=$1; fb=$2; rounds=$3
        exec 3<>"$fa" 4<>"$fb"
        i=0
        while [ "$i" -lt "$rounds" ]; do
            read -r token <&3 || exit 0
            printf "token\n" >&4
            i=$((i + 1))
            sleep 0.005
        done
    ' sh "$fifo_a" "$fifo_b" "$ROUND_TRIPS" &
    a=$!
    sh -c '
        fb=$1; fa=$2; rounds=$3
        exec 3<>"$fb" 4<>"$fa"
        i=0
        while [ "$i" -lt "$rounds" ]; do
            read -r token <&3 || exit 0
            printf "token\n" >&4
            i=$((i + 1))
            sleep 0.005
        done
    ' sh "$fifo_b" "$fifo_a" "$ROUND_TRIPS" &
    b=$!
    STUDY_CHILDREN="$a $b"
    studies_note "workload: 2 processes, $ROUND_TRIPS round trips of blocking read + wake (bounded ${WORKLOAD_SECONDS}s)"
    printf 'start\n' >"$fifo_a"
    sleep "$WORKLOAD_SECONDS"
    studies_kill_children
}

main() {
    studies_parse_common "pingpong" "$@"
    if [ "$STUDY_DRY" -eq 1 ]; then
        studies_dry_run "pingpong" "$STUDY_DESC" \
            "start bounded recorder, run two-process pipe ping-pong ${WORKLOAD_SECONDS}s, capture --last 60s, run why/metrics/incident"
        return 0
    fi
    studies_require_vm "$STUDY_BIN"
    studies_begin "pingpong" "$STUDY_DESC"
    mkdir -p "$STUDY_OUT/work"
    studies_probe_capture "$STUDY_BIN" "$STUDY_OUT"
    studies_start_daemon "$STUDY_BIN" "$STUDY_OUT/state" "$STUDY_OUT"
    workload
    studies_wait_daemon
    studies_analyze "$STUDY_BIN" "$STUDY_OUT/state" "$STUDY_OUT"
    counters=$(studies_assert_evidence "$STUDY_OUT")
    studies_write_evidence "$STUDY_OUT" "pingpong" "$STUDY_DESC" "$counters"
    studies_cleanup
    printf 'study_pingpong: PASS\n'
}

main "$@"
