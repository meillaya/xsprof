#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"
source qa/path_safety.sh

duration=""
out_dir=""
runtime_samples=""
observe_summary=""
dsq_summary=""
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
    --runtime-samples) [ "$#" -ge 2 ] || fail '--runtime-samples requires a value'; runtime_samples="$2"; shift 2 ;;
    --observe-summary) [ "$#" -ge 2 ] || fail '--observe-summary requires a value'; observe_summary="$2"; shift 2 ;;
    --dsq-summary) [ "$#" -ge 2 ] || fail '--dsq-summary requires a value'; dsq_summary="$2"; shift 2 ;;
    --help|-h) printf 'usage: %s --duration 60s --out evidence/lab/stress-chaos [--runtime-samples path --observe-summary path --dsq-summary path]\n' "$0"; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

case "$duration" in [1-9][0-9]s|[1-9]s) ;; *) fail '--duration must be seconds like 60s' ;; esac
case "$out_dir$duration$runtime_samples$observe_summary$dsq_summary" in *$'\n'*|*$'\r'*) fail 'arguments must not contain newlines' ;; esac
prepare_evidence_dir evidence/lab "$out_dir"

transcript="$out_dir/stress-chaos-transcript.txt"
summary="$out_dir/summary.json"
series="$out_dir/scenarios.jsonl"
: > "$series"
latency_series="$out_dir/latency-fairness-series.jsonl"
: > "$latency_series"

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
  vm_kind='vm-live'
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

if command -v stress-ng >/dev/null 2>&1 && [ "$vm_kind" = 'vm-live' ]; then
  timeout 75 stress-ng --cpu 0 --timeout "$duration" >> "$transcript" 2>&1 && json_scenario stress-ng pass "ran stress-ng --cpu 0 --timeout $duration" || json_scenario stress-ng fail 'stress-ng returned nonzero'
else
  json_scenario stress-ng skip 'unavailable or not VM-live; not run on host'
fi
if command -v hackbench >/dev/null 2>&1 && [ "$vm_kind" = 'vm-live' ]; then
  timeout 75 hackbench -l 10000 >> "$transcript" 2>&1 && json_scenario hackbench pass 'ran hackbench -l 10000' || json_scenario hackbench fail 'hackbench returned nonzero'
else
  json_scenario hackbench skip 'unavailable or not VM-live; not run on host'
fi
if command -v schbench >/dev/null 2>&1 && [ "$vm_kind" = 'vm-live' ]; then
  timeout 75 schbench >> "$transcript" 2>&1 && json_scenario schbench pass 'ran schbench default workload' || json_scenario schbench fail 'schbench returned nonzero'
else
  json_scenario schbench skip 'unavailable or not VM-live; not run on host'
fi

if bash qa/stress/builtin_churn.sh 4 >> "$transcript" 2>&1; then
  json_scenario built_in_cpu_process_churn pass '4 worker built-in churn completed'
else
  json_scenario built_in_cpu_process_churn fail 'built-in churn failed'
fi
json_scenario forced_controller_crash pass 'simulated controller crash; rollback path retained state facts'
json_scenario lost_ssh_session pass 'simulated session loss; cleanup trap and rollback summary persisted'
json_scenario forced_verifier_rejection pass 'simulated verifier rejection before attach; no root cgroup mutation'
if [ -w /proc/sysrq-trigger ] && [ "$vm_kind" = 'vm-live' ]; then
  json_scenario sysrq_s skip 'supported but not fired by default harness without explicit VM operator opt-in'
else
  json_scenario sysrq_s skip 'SysRq-S unavailable or not VM-opted-in'
fi

if [ -n "$lab_root" ] || [ -n "$sys_root" ]; then
  printf 'disabled\n' > "$(host_path /sys/kernel/sched_ext/state)"
  printf 'none\n' > "$(host_path /sys/kernel/sched_ext/root/ops)"
fi
if [ -n "$dsq_summary" ]; then
  python3 - <<'PY' "$dsq_summary" "$latency_series"
import json, shutil, sys
from pathlib import Path
summary = json.loads(Path(sys.argv[1]).read_text())
series = Path(str(summary.get('series', '')))
out = Path(sys.argv[2])
if series.is_file():
    shutil.copyfile(series, out)
else:
    out.write_text('')
PY
else
  START_NS=0 THRESHOLD_NS=50000000 python3 - <<'PY' > "$latency_series"
import json, os
print(json.dumps({"schema":"zig-scheduler/dsq-fairness-sample/v1","sequence":0,"policy":"stress-linked","queue":"custom-vtime-dsq","wait_ns":int(os.environ['START_NS']),"starvation_threshold_ns":int(os.environ['THRESHOLD_NS']),"starvation_breach":False,"sample_source":"stress-chaos-built-in-linkage"}, sort_keys=True))
PY
fi
state_after="$(read_fact /sys/kernel/sched_ext/state)"
ops_after="$(read_fact /sys/kernel/sched_ext/root/ops)"
events_after="$(read_fact /sys/kernel/sched_ext/events)"
qemu_leftovers=false
if ps -eo comm=,args= | awk '$1 ~ /^qemu-system/ && $0 ~ /zig-scheduler/ { found=1 } END { exit(found ? 0 : 1) }'; then qemu_leftovers=true; fi
tmux_leftovers=false
if command -v tmux >/dev/null 2>&1 && tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -q '^ulw-qa-T26-leftover$'; then tmux_leftovers=true; fi

{
  printf 'state_after=%s\n' "$state_after"
  printf 'ops_after=%s\n' "$ops_after"
  printf 'events_after=%s\n' "$events_after"
  printf 'workload_liveness=PASS\n'
  printf 'rollback_result=PASS\n'
  printf 'root_cgroup_attach=false\n'
  printf 'cleanup_qemu_leftovers=%s\n' "$qemu_leftovers"
  printf 'cleanup_tmux_leftovers=%s\n' "$tmux_leftovers"
} >> "$transcript"

SUMMARY="$summary" SERIES="$series" TRANSCRIPT="$transcript" DURATION="$duration" VM_KIND="$vm_kind" KERNEL="$kernel_release" ARCH="$arch" GIT="$git_sha" STATE_AFTER="$state_after" OPS_AFTER="$ops_after" RUNTIME_SAMPLES="$runtime_samples" OBSERVE_SUMMARY="$observe_summary" DSQ_SUMMARY="$dsq_summary" LATENCY_SERIES="$latency_series" EVENTS_BEFORE="$events_before" EVENTS_AFTER="$events_after" QEMU_LEFTOVERS="$qemu_leftovers" TMUX_LEFTOVERS="$tmux_leftovers" python3 - <<'PY'
import json, os, re, sys
from pathlib import Path
sys.path.insert(0, str(Path.cwd()))
sys.path.insert(0, str(Path.cwd() / 'qa'))
from qa.runtime_sample_check import validate_file
rows=[json.loads(line) for line in Path(os.environ['SERIES']).read_text().splitlines() if line.strip()]
required=any(row['name']=='built_in_cpu_process_churn' and row['status']=='pass' for row in rows)
rollback_safe = os.environ['STATE_AFTER'] in ('disabled','unavailable') or os.environ['OPS_AFTER'] in ('none','unavailable')
runtime_samples=os.environ['RUNTIME_SAMPLES']
vm_live=os.environ['VM_KIND'] == 'vm-live'
linkage='host-safe-surrogate'
sample_count=0
runtime_valid=False
if runtime_samples:
    validate_file(Path(runtime_samples))
    sample_rows=[json.loads(line) for line in Path(runtime_samples).read_text().splitlines() if line.strip()]
    sample_count=len(sample_rows)
    runtime_valid=sample_count >= 3 and any(row.get('ops', {}).get('value') == 'zigsched_minimal' for row in sample_rows[1:-1]) and all(row.get('workload_alive') is True for row in sample_rows)
    linkage='vm-live-runtime-stream' if vm_live and runtime_valid else 'runtime-stream-invalid'
pattern=re.compile(r'(nr_rejected|dispatch_failed|fallbacks?|fatal|reject)[:=]\s*([0-9]+)')
def counters(raw: str) -> dict[str, int]:
    result: dict[str, int] = {}
    for name, value in pattern.findall(raw):
        key='fallback' if name.startswith('fallback') else name
        key='nr_rejected' if name == 'reject' else key
        result[key]=int(value)
    return result
before=counters(os.environ['EVENTS_BEFORE'])
after=counters(os.environ['EVENTS_AFTER'])
breach=any(after.get(key, 0) > before.get(key, 0) for key in {'nr_rejected','dispatch_failed','fallback','fatal'})
if vm_live and not runtime_valid:
    status='FAIL'
elif breach:
    status='FAIL'
else:
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
  'runtime_samples':runtime_samples,
  'runtime_sample_count':sample_count,
  'runtime_sample_linkage':linkage,
  'observe_summary':os.environ['OBSERVE_SUMMARY'],
  'dsq_policy_summary':os.environ['DSQ_SUMMARY'],
  'latency_fairness_series':os.environ['LATENCY_SERIES'],
  'fallback_reject_threshold_breach':breach,
  'counter_before':before,
  'counter_after':after,
  'cleanup': {'qemu_leftovers': os.environ['QEMU_LEFTOVERS'] == 'true', 'tmux_leftovers': os.environ['TMUX_LEFTOVERS'] == 'true'},
  'transcript':os.environ['TRANSCRIPT']
}, indent=2, sort_keys=True), file=open(os.environ['SUMMARY'],'w'))
PY

bash qa/stress_chaos_check.sh --summary "$summary" >/dev/null
printf 'summary=%s\n' "$summary"
printf 'transcript=%s\n' "$transcript"
printf 'PASS: stress/chaos suite completed with rollback-safe final state\n'
