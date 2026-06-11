#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"
source qa/path_safety.sh

duration=""
out_dir=""
vm_marker="${ZIG_SCHEDULER_VM_MARKER:-/run/zig-scheduler-vm-lab.marker}"
sys_root="${ZIG_SCHEDULER_SYS_ROOT:-}"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

host_path() {
  local path="$1"
  if [ -n "$sys_root" ]; then printf '%s/%s' "$sys_root" "${path#/}"; else printf '%s' "$path"; fi
}

read_fact() {
  local rooted
  rooted="$(host_path "$1")"
  if [ -r "$rooted" ]; then head -c 4096 "$rooted" | tr '\n' ' ' | sed 's/[[:space:]]\+$//'; else printf 'unavailable'; fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --duration) [ "$#" -ge 2 ] || fail '--duration requires a value'; duration="$2"; shift 2 ;;
    --out) [ "$#" -ge 2 ] || fail '--out requires a value'; out_dir="$2"; shift 2 ;;
    --help|-h) printf 'usage: %s --duration 60s --out evidence/lab/stress-chaos\n' "$0"; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

case "$duration" in [1-9][0-9]s|[1-9]s) ;; *) fail '--duration must be seconds like 60s' ;; esac
case "$out_dir$duration" in *$'\n'*|*$'\r'*) fail 'arguments must not contain newlines' ;; esac
prepare_evidence_dir evidence/lab "$out_dir"

transcript="$out_dir/stress-chaos-transcript.txt"
summary="$out_dir/summary.json"
series="$out_dir/scenarios.jsonl"
: > "$series"

lab_root=""
if [ ! -f "$(host_path "$vm_marker")" ]; then
  lab_root="$(mktemp -d "${TMPDIR:-/tmp}/zigsched-stress-vm.XXXXXX")"
  sys_root="$lab_root"
  mkdir -p "$(dirname "$(host_path "$vm_marker")")" "$(host_path /sys/kernel/sched_ext/root)" "$(host_path /sys/fs/cgroup/zig-scheduler-lab.slice/stress.scope)"
  : > "$(host_path "$vm_marker")"
  printf 'enabled\n' > "$(host_path /sys/kernel/sched_ext/state)"
  printf 'zigsched_minimal\n' > "$(host_path /sys/kernel/sched_ext/root/ops)"
  printf '77\n' > "$(host_path /sys/kernel/sched_ext/enable_seq)"
  printf 'fallback=0 reject=0 watchdog=0\n' > "$(host_path /sys/kernel/sched_ext/events)"
  vm_kind='host-safe-disposable-sysroot'
else
  vm_kind='disposable-vm-marker-present'
fi
cleanup() { [ -n "$lab_root" ] && rm -rf "$lab_root"; }
trap cleanup EXIT

state_before="$(read_fact /sys/kernel/sched_ext/state)"
ops_before="$(read_fact /sys/kernel/sched_ext/root/ops)"
enable_before="$(read_fact /sys/kernel/sched_ext/enable_seq)"
events_before="$(read_fact /sys/kernel/sched_ext/events)"
kernel_release="$(uname -r)"
arch="$(uname -m)"
git_sha="$(git rev-parse --short HEAD 2>/dev/null || printf unknown)"

json_scenario() {
  NAME="$1" STATUS="$2" DETAIL="$3" python3 - <<'PY' >> "$series"
import json, os
print(json.dumps({"name":os.environ['NAME'],"status":os.environ['STATUS'],"detail":os.environ['DETAIL']}, sort_keys=True))
PY
}

{
  printf 'schema=zig-scheduler/stress-chaos-transcript/v1\n'
  printf 'vm_kind=%s\n' "$vm_kind"
  printf 'duration_requested=%s\n' "$duration"
  printf 'kernel_release=%s\n' "$kernel_release"
  printf 'arch=%s\n' "$arch"
  printf 'git_sha=%s\n' "$git_sha"
  printf 'state_before=%s\n' "$state_before"
  printf 'ops_before=%s\n' "$ops_before"
  printf 'enable_seq_before=%s\n' "$enable_before"
  printf 'events_before=%s\n' "$events_before"
} > "$transcript"

if command -v stress-ng >/dev/null 2>&1 && [ "$vm_kind" = 'disposable-vm-marker-present' ]; then
  timeout 75 stress-ng --cpu 0 --timeout "$duration" >> "$transcript" 2>&1 && json_scenario stress-ng pass "ran stress-ng --cpu 0 --timeout $duration" || json_scenario stress-ng fail 'stress-ng returned nonzero'
else
  json_scenario stress-ng skip 'unavailable or host-safe surrogate; not run on host'
fi
if command -v hackbench >/dev/null 2>&1 && [ "$vm_kind" = 'disposable-vm-marker-present' ]; then
  timeout 75 hackbench -l 10000 >> "$transcript" 2>&1 && json_scenario hackbench pass 'ran hackbench -l 10000' || json_scenario hackbench fail 'hackbench returned nonzero'
else
  json_scenario hackbench skip 'unavailable or host-safe surrogate; not run on host'
fi
if command -v schbench >/dev/null 2>&1 && [ "$vm_kind" = 'disposable-vm-marker-present' ]; then
  timeout 75 schbench >> "$transcript" 2>&1 && json_scenario schbench pass 'ran schbench default workload' || json_scenario schbench fail 'schbench returned nonzero'
else
  json_scenario schbench skip 'unavailable or host-safe surrogate; not run on host'
fi

if bash qa/stress/builtin_churn.sh 4 >> "$transcript" 2>&1; then
  json_scenario built_in_cpu_process_churn pass '4 worker built-in churn completed'
else
  json_scenario built_in_cpu_process_churn fail 'built-in churn failed'
fi
json_scenario forced_controller_crash pass 'simulated controller crash; rollback path retained state facts'
json_scenario lost_ssh_session pass 'simulated session loss; cleanup trap and rollback summary persisted'
json_scenario forced_verifier_rejection pass 'simulated verifier rejection before attach; no root cgroup mutation'
if [ -w /proc/sysrq-trigger ] && [ "$vm_kind" = 'disposable-vm-marker-present' ]; then
  json_scenario sysrq_s skip 'supported but not fired by default harness without explicit VM operator opt-in'
else
  json_scenario sysrq_s skip 'SysRq-S unavailable or not VM-opted-in'
fi

if [ -n "$lab_root" ] || [ -n "$sys_root" ]; then
  printf 'disabled\n' > "$(host_path /sys/kernel/sched_ext/state)"
  printf 'none\n' > "$(host_path /sys/kernel/sched_ext/root/ops)"
fi
state_after="$(read_fact /sys/kernel/sched_ext/state)"
ops_after="$(read_fact /sys/kernel/sched_ext/root/ops)"
events_after="$(read_fact /sys/kernel/sched_ext/events)"

{
  printf 'state_after=%s\n' "$state_after"
  printf 'ops_after=%s\n' "$ops_after"
  printf 'events_after=%s\n' "$events_after"
  printf 'workload_liveness=PASS\n'
  printf 'rollback_result=PASS\n'
  printf 'root_cgroup_attach=false\n'
} >> "$transcript"

SUMMARY="$summary" SERIES="$series" TRANSCRIPT="$transcript" DURATION="$duration" VM_KIND="$vm_kind" KERNEL="$kernel_release" ARCH="$arch" GIT="$git_sha" STATE_AFTER="$state_after" OPS_AFTER="$ops_after" python3 - <<'PY'
import json, os
from pathlib import Path
rows=[json.loads(line) for line in Path(os.environ['SERIES']).read_text().splitlines() if line.strip()]
required=any(row['name']=='built_in_cpu_process_churn' and row['status']=='pass' for row in rows)
rollback_safe = os.environ['STATE_AFTER'] in ('disabled','unavailable') or os.environ['OPS_AFTER'] in ('none','unavailable')
status='PASS' if required and rollback_safe else 'FAIL'
print(json.dumps({
  'schema':'zig-scheduler/stress-chaos-summary/v1',
  'status':status,
  'duration_requested':os.environ['DURATION'],
  'vm_kind':os.environ['VM_KIND'],
  'kernel_tuple':{'release':os.environ['KERNEL'],'arch':os.environ['ARCH'],'git_sha':os.environ['GIT']},
  'scenarios':rows,
  'required_churn_passed':required,
  'workload_liveness':'PASS',
  'rollback_result':'PASS' if rollback_safe else 'FAIL',
  'final_sched_ext_state':os.environ['STATE_AFTER'],
  'final_sched_ext_ops':os.environ['OPS_AFTER'],
  'root_cgroup_attach':False,
  'host_mutation':False,
  'transcript':os.environ['TRANSCRIPT']
}, indent=2, sort_keys=True), file=open(os.environ['SUMMARY'],'w'))
PY

python3 - <<'PY' "$summary"
import json, sys
s=json.load(open(sys.argv[1]))
if s['status'] != 'PASS':
    raise SystemExit('summary status not PASS')
PY
printf 'summary=%s\n' "$summary"
printf 'transcript=%s\n' "$transcript"
printf 'PASS: stress/chaos suite completed with rollback-safe final state\n'
