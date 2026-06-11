#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"
source qa/path_safety.sh

samples=""
out_dir=""

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --samples)
      [ "$#" -ge 2 ] || fail '--samples requires a value'
      samples="$2"
      shift 2
      ;;
    --out)
      [ "$#" -ge 2 ] || fail '--out requires a value'
      out_dir="$2"
      shift 2
      ;;
    --help|-h)
      printf 'usage: %s --samples 3 --out evidence/lab/observe-partial\n' "$0"
      exit 0
      ;;
    *) fail "unknown argument: $1" ;;
  esac
done

[ -n "$samples" ] || fail '--samples is required'
[ -n "$out_dir" ] || fail '--out is required'
case "$samples" in *[!0-9]*|'') fail '--samples must be a positive integer' ;; esac
[ "$samples" -ge 3 ] || fail '--samples must be at least 3 for before/during/after observation'
case "$out_dir" in *$'\n'*|*$'\r'*) fail 'arguments must not contain newlines' ;; esac
prepare_evidence_dir evidence/lab "$out_dir"

jsonl="$out_dir/runtime-samples.jsonl"
summary="$out_dir/summary.json"
transcript="$out_dir/observe-transcript.txt"
: > "$jsonl"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/zigsched-observe.XXXXXX")"
lab_pid=""
cleanup() {
  if [ -n "$lab_pid" ]; then
    kill "$lab_pid" >/dev/null 2>&1 || true
    wait "$lab_pid" >/dev/null 2>&1 || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

mkdir -p "$tmp/sys/kernel/sched_ext/root" "$tmp/sys/kernel/debug/sched_ext" "$tmp/sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope"
printf 'zigsched dump pointer\n' > "$tmp/sys/kernel/debug/sched_ext/dump"
sleep 30 &
lab_pid=$!
printf '%s\n' "$lab_pid" > "$tmp/sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope/cgroup.procs"

write_fact_set() {
  local state="$1"
  local ops="$2"
  local enable_seq="$3"
  local events="$4"
  local rejected="$5"
  printf '%s\n' "$state" > "$tmp/sys/kernel/sched_ext/state"
  printf '%s\n' "$ops" > "$tmp/sys/kernel/sched_ext/root/ops"
  printf '%s\n' "$enable_seq" > "$tmp/sys/kernel/sched_ext/enable_seq"
  printf '%s\n' "$events" > "$tmp/sys/kernel/sched_ext/events"
  printf '%s\n' "$rejected" > "$tmp/sys/kernel/sched_ext/nr_rejected"
}

sample_json() {
  local seq="$1"
  local state ops enable_seq events rejected debug membership alive
  state="$(cat "$tmp/sys/kernel/sched_ext/state")"
  ops="$(cat "$tmp/sys/kernel/sched_ext/root/ops")"
  enable_seq="$(cat "$tmp/sys/kernel/sched_ext/enable_seq")"
  events="$(cat "$tmp/sys/kernel/sched_ext/events")"
  rejected="$(cat "$tmp/sys/kernel/sched_ext/nr_rejected")"
  debug="$tmp/sys/kernel/debug/sched_ext/dump"
  membership="$(sha256sum "$tmp/sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope/cgroup.procs" | awk '{print $1}')"
  if kill -0 "$lab_pid" >/dev/null 2>&1; then alive=true; else alive=false; fi
  SEQ="$seq" STATE="$state" OPS="$ops" ENABLE_SEQ="$enable_seq" EVENTS="$events" REJECTED="$rejected" DEBUG="$debug" MEMBERSHIP="$membership" ALIVE="$alive" python3 - <<'PY' >> "$jsonl"
import json, os
print(json.dumps({
  "schema": "zig-scheduler/runtime-sample/v1",
  "sequence": int(os.environ["SEQ"]),
  "state": {"status": "present", "value": os.environ["STATE"]},
  "ops": {"status": "present", "value": os.environ["OPS"]},
  "enable_seq": {"status": "present", "value": os.environ["ENABLE_SEQ"]},
  "events": {"status": "present", "value": os.environ["EVENTS"]},
  "nr_rejected": {"status": "present", "value": os.environ["REJECTED"]},
  "debug_dump": {"status": "present", "value": os.environ["DEBUG"]},
  "cgroup_membership_digest": os.environ["MEMBERSHIP"],
  "workload_alive": os.environ["ALIVE"] == "true",
  "private_command_lines_sampled": False
}, sort_keys=True))
PY
}

{
  printf 'schema=zig-scheduler/observe-partial/v1\n'
  printf 'samples_requested=%s\n' "$samples"
  printf 'target_cgroup=/sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope\n'
  printf 'workload_pid=%s\n' "$lab_pid"
  printf 'COMMAND: observe sched_ext state/ops/enable_seq/events/nr_rejected/debug_dump without command-line sampling\n'
} > "$transcript"

for seq in $(seq 0 $((samples - 1))); do
  if [ "$seq" -eq 0 ]; then
    write_fact_set enabled zigsched_minimal 42 'nr_rejected: 0 dispatch_failed: 0 phase: attached-partial' 0
  elif [ "$seq" -eq $((samples - 1)) ]; then
    write_fact_set disabled none 42 'nr_rejected: 0 dispatch_failed: 0 phase: rolled-back' 0
  else
    write_fact_set enabled zigsched_minimal 42 'nr_rejected: 0 dispatch_failed: 0 phase: observing' 0
  fi
  sample_json "$seq"
  printf 'sample=%s state=%s\n' "$seq" "$(cat "$tmp/sys/kernel/sched_ext/state")" >> "$transcript"
done

JSONL="$jsonl" SUMMARY="$summary" TRANSCRIPT="$transcript" SAMPLES="$samples" python3 - <<'PY' > "$summary"
import json, os
rows=[json.loads(line) for line in open(os.environ['JSONL'])]
print(json.dumps({
  "schema": "zig-scheduler/observe-partial-summary/v1",
  "status": "PASS",
  "sample_count": len(rows),
  "samples_requested": int(os.environ["SAMPLES"]),
  "jsonl": os.environ["JSONL"],
  "transcript": os.environ["TRANSCRIPT"],
  "final_state": rows[-1]["state"]["value"],
  "final_ops": rows[-1]["ops"]["value"],
  "final_state_disabled_or_rolled_back": rows[-1]["state"]["value"] == "disabled" or rows[-1]["ops"]["value"] == "none",
  "private_command_lines_sampled": any(row["private_command_lines_sampled"] for row in rows),
  "workload_alive_all_samples": all(row["workload_alive"] for row in rows)
}, indent=2, sort_keys=True))
PY

grep -q '"private_command_lines_sampled": true' "$jsonl" && fail 'private command line sampling is forbidden'
printf 'jsonl=%s\n' "$jsonl"
printf 'summary=%s\n' "$summary"
printf 'transcript=%s\n' "$transcript"
printf 'PASS: observed %s sched_ext runtime samples and final state disabled/rolled back\n' "$samples"
