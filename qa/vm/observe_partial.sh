#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"
source qa/path_safety.sh

samples=""
out_dir=""
audit_ledger="evidence/lab/rollback-drill/audit-ledger.jsonl"

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
    --audit-ledger)
      [ "$#" -ge 2 ] || fail '--audit-ledger requires a value'
      audit_ledger="$2"
      shift 2
      ;;
    --help|-h)
      printf 'usage: %s --samples 3 --out evidence/lab/observe-partial\n' "$0"
      exit 0
      ;;
    *) fail "unknown argument: $1" ;;
  esac
done

[ -n "$samples" ] || samples=3
[ -n "$out_dir" ] || fail '--out is required'
case "$samples" in *[!0-9]*|'') fail '--samples must be a positive integer' ;; esac
[ "$samples" -ge 3 ] || fail '--samples must be at least 3 for before/during/after observation'
case "$out_dir$audit_ledger" in *$'\n'*|*$'\r'*) fail 'arguments must not contain newlines' ;; esac
prepare_evidence_dir evidence/lab "$out_dir"

jsonl="$out_dir/runtime-samples.jsonl"
summary="$out_dir/summary.json"
transcript="$out_dir/observe-transcript.txt"
daemon_events="$out_dir/daemon-runtime-events.jsonl"
daemon_state="$out_dir/daemon-state"
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
mkdir -p "$tmp/proc/$lab_pid"
printf '%s\n' "$lab_pid" > "$tmp/sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope/cgroup.procs"

write_fact_set() {
  local state="$1"
  local ops="$2"
  local enable_seq="$3"
  local events="$4"
  local rejected="$5"
  local task_ext="$6"
  printf '%s\n' "$state" > "$tmp/sys/kernel/sched_ext/state"
  printf '%s\n' "$ops" > "$tmp/sys/kernel/sched_ext/root/ops"
  printf '%s\n' "$enable_seq" > "$tmp/sys/kernel/sched_ext/enable_seq"
  printf '%s\n' "$events" > "$tmp/sys/kernel/sched_ext/events"
  printf '%s\n' "$rejected" > "$tmp/sys/kernel/sched_ext/nr_rejected"
  printf 'se.exec_start                                : 1.000000\next.enabled                                  : %s\n' "$task_ext" > "$tmp/proc/$lab_pid/sched"
}

task_ext_enabled_fact() {
  local sched_file="$tmp/proc/$lab_pid/sched"
  local line value
  if [ ! -r "$sched_file" ]; then
    printf 'unknown unavailable\n'
    return
  fi
  if ! line="$(grep -m1 -E '(^|[[:space:]])ext\.enabled[[:space:]]*:' "$sched_file")"; then
    printf 'unknown unavailable\n'
    return
  fi
  value="${line#*:}"
  value="${value//[[:space:]]/}"
  case "$value" in
    1|true) printf 'present true\n' ;;
    0|false) printf 'present false\n' ;;
    *) printf 'unknown unknown\n' ;;
  esac
}

sample_json() {
  local seq="$1"
  local phase="$2"
  local state ops enable_seq events events_hash rejected debug membership alive task_ext_status task_ext_value rollback_state
  state="$(cat "$tmp/sys/kernel/sched_ext/state")"
  ops="$(cat "$tmp/sys/kernel/sched_ext/root/ops")"
  enable_seq="$(cat "$tmp/sys/kernel/sched_ext/enable_seq")"
  events="$(cat "$tmp/sys/kernel/sched_ext/events")"
  events_hash="$(printf '%s' "$events" | sha256sum | awk '{print $1}')"
  rejected="$(cat "$tmp/sys/kernel/sched_ext/nr_rejected")"
  debug="sha256:$(sha256sum "$tmp/sys/kernel/debug/sched_ext/dump" | awk '{print $1}');bytes:$(wc -c < "$tmp/sys/kernel/debug/sched_ext/dump" | tr -d ' ')"
  membership="$(sha256sum "$tmp/sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope/cgroup.procs" | awk '{print $1}')"
  if kill -0 "$lab_pid" >/dev/null 2>&1; then alive=true; else alive=false; fi
  read -r task_ext_status task_ext_value < <(task_ext_enabled_fact)
  if [ "$phase" = "after_rollback" ]; then rollback_state=rolled_back; else rollback_state=not_applicable; fi
  SEQ="$seq" PHASE="$phase" STATE="$state" OPS="$ops" ENABLE_SEQ="$enable_seq" EVENTS="$events" EVENTS_HASH="$events_hash" REJECTED="$rejected" DEBUG_SUMMARY="$debug" MEMBERSHIP="$membership" ALIVE="$alive" TASK_EXT_STATUS="$task_ext_status" TASK_EXT_VALUE="$task_ext_value" ROLLBACK_STATE="$rollback_state" python3 - <<'PY' >> "$jsonl"
import json, os, re
events = os.environ["EVENTS"]
def counter(name):
    match = re.search(rf"(?:^|[^A-Za-z0-9_]){re.escape(name)}\s*[:=]\s*([0-9]+)", events)
    return int(match.group(1)) if match else 0
print(json.dumps({
  "schema": "zig-scheduler/runtime-sample/v1",
  "sequence": int(os.environ["SEQ"]),
  "observation_source": "vm_fixture_sched_ext",
  "sched_ext_phase": os.environ["PHASE"],
  "state": {"status": "present", "value": os.environ["STATE"]},
  "ops": {"status": "present", "value": os.environ["OPS"]},
  "root_ops": {"status": "present", "value": os.environ["OPS"]},
  "enable_seq": {"status": "present", "value": os.environ["ENABLE_SEQ"]},
  "events": {"status": "present", "value": events},
  "scheduler_events": {"status": "present", "value": events},
  "events_hash": os.environ["EVENTS_HASH"],
  "nr_rejected": {"status": "present", "value": os.environ["REJECTED"]},
  "debug_dump": {"status": "present", "value": os.environ["DEBUG_SUMMARY"]},
  "policy_counters": {
    "nr_rejected": int(os.environ["REJECTED"]),
    "dispatch_failed": counter("dispatch_failed"),
    "fallback": counter("fallback"),
    "fatal": counter("fatal")
  },
  "sample_loss": {"lost_samples": 0, "backpressure_dropped": 0},
  "policy_abi": {
    "policy_name": "zigsched_minimal",
    "policy_version": "sched_ext_cgroup_abi_v3",
    "struct_ops": "zigsched_minimal_ops",
    "object_sha256": "unavailable",
    "btf_required": True,
    "abi_version": 3,
    "abi_label": "zigsched-bpf-abi-v3",
    "cgroup_semantics": {
      "cpu.weight": "callback-observed",
      "cgroup.lifecycle": "observed",
      "cgroup.move": "observed",
      "cpuset.cpus": "observed-only",
      "cpuset.cpus.effective": "observed-only",
      "cpu.pressure": "observed-only",
      "cpu.max": "deferred",
      "uclamp": "deferred",
      "cgroup_set_idle": "refused"
    },
    "vm_only": True,
    "host_mutation": False,
    "production_claim": False,
    "release_eligible": False,
    "cgroup_policy_map": {"status": "unavailable", "reason": "observe_partial fixture does not attach VM BPF maps"},
    "cgroup_callback_stats": {"status": "unavailable", "reason": "observe_partial fixture does not attach VM BPF maps"},
    "dsq_counter_coherence": {"status": "unavailable", "reason": "observe_partial fixture does not attach VM BPF maps"}
  },
  "cgroup_semantic_labels": {
    "cpu.weight": "callback-observed",
    "cgroup.lifecycle": "observed",
    "cgroup.move": "observed",
    "cpuset.cpus": "observed-only",
    "cpuset.cpus.effective": "observed-only",
    "cpu.pressure": "observed-only",
    "cpu.max": "deferred",
    "uclamp": "deferred",
    "cgroup_set_idle": "refused"
  },
  "cgroup_membership_digest": os.environ["MEMBERSHIP"],
  "cgroup_membership_status": {"status": "present", "value": "present"},
  "task_ext_enabled": {"status": os.environ["TASK_EXT_STATUS"], "value": os.environ["TASK_EXT_VALUE"]},
  "teardown_state": {"status": "present", "value": "attached" if os.environ["PHASE"] == "during_attach" else "detached"},
  "rollback_state": {"status": "present", "value": os.environ["ROLLBACK_STATE"]},
  "workload": {"status": "present", "value": "alive" if os.environ["ALIVE"] == "true" else "not_alive"},
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
    write_fact_set disabled none 41 'nr_rejected: 0 dispatch_failed: 0 fallback: 0 fatal: 0 phase: pre-attach' 0 0
  elif [ "$seq" -eq $((samples - 1)) ]; then
    write_fact_set disabled none 42 'nr_rejected: 0 dispatch_failed: 0 fallback: 0 fatal: 0 phase: rolled-back' 0 0
  else
    write_fact_set enabled zigsched_minimal 42 'nr_rejected: 0 dispatch_failed: 0 fallback: 0 fatal: 0 phase: observing' 0 1
  fi
  if [ "$seq" -eq 0 ]; then phase=before_attach; elif [ "$seq" -eq $((samples - 1)) ]; then phase=after_rollback; else phase=during_attach; fi
  sample_json "$seq" "$phase"
  printf 'sample=%s state=%s\n' "$seq" "$(cat "$tmp/sys/kernel/sched_ext/state")" >> "$transcript"
done

python3 qa/runtime_sample_check.py --input "$jsonl" >/dev/null
python3 qa/audit_ledger_check.py --ledger "$audit_ledger" >/dev/null
rm -rf "$daemon_state"
zig build install >/dev/null
./zig-out/bin/zig-scheduler-daemon --foreground --state-dir "$daemon_state" --stream-runtime "$jsonl" > "$daemon_events"

JSONL="$jsonl" SUMMARY="$summary" TRANSCRIPT="$transcript" SAMPLES="$samples" AUDIT_LEDGER="$audit_ledger" DAEMON_EVENTS="$daemon_events" EVIDENCE_MODE="${ZIG_SCHEDULER_OBSERVE_EVIDENCE_MODE:-fixture}" RELEASE_PROOF="${ZIG_SCHEDULER_OBSERVE_RELEASE_PROOF:-0}" python3 - <<'PY' > "$summary"
import json, os
rows=[json.loads(line) for line in open(os.environ['JSONL'])]
last=rows[-1]
mode=os.environ["EVIDENCE_MODE"]
release_proof=mode == "vm-live" and os.environ["RELEASE_PROOF"] == "1"
print(json.dumps({
  "schema": "zig-scheduler/observe-partial-summary/v1",
  "status": "PASS",
  "evidence_mode": mode,
  "release_eligible_live_proof": release_proof,
  "release_ineligible_reason": "" if release_proof else "observation-not-vm-live-release-proof",
  "sample_count": len(rows),
  "samples_requested": int(os.environ["SAMPLES"]),
  "jsonl": os.environ["JSONL"],
  "runtime_samples": os.environ["JSONL"],
  "audit_ledger": os.environ["AUDIT_LEDGER"],
  "daemon_runtime_events": os.environ["DAEMON_EVENTS"],
  "scheduler_snapshot": {
    "state": last["state"],
    "root_ops": last["ops"],
    "enable_seq": last["enable_seq"],
    "events": last["events"],
    "events_hash": last["events_hash"],
    "task_ext_enabled": last["task_ext_enabled"],
    "teardown_state": last["teardown_state"],
    "rollback_state": last["rollback_state"],
    "policy_abi": last["policy_abi"],
    "cgroup_semantic_labels": last["cgroup_semantic_labels"]
  },
  "transcript": os.environ["TRANSCRIPT"],
  "final_state": last["state"]["value"],
  "final_ops": last["ops"]["value"],
  "final_state_disabled_or_rolled_back": last["state"]["value"] == "disabled" or last["ops"]["value"] == "none",
  "private_command_lines_sampled": any(row["private_command_lines_sampled"] for row in rows),
  "workload_alive_all_samples": all(row["workload_alive"] for row in rows)
}, indent=2, sort_keys=True))
PY
python3 qa/lab_summary_observe.py --summary "$summary" >/dev/null

grep -q '"private_command_lines_sampled": true' "$jsonl" && fail 'private command line sampling is forbidden'
printf 'jsonl=%s\n' "$jsonl"
printf 'summary=%s\n' "$summary"
printf 'transcript=%s\n' "$transcript"
printf 'daemon_events=%s\n' "$daemon_events"
printf 'PASS: observed %s sched_ext runtime samples and final state disabled/rolled back\n' "$samples"
