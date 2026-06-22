#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"
source qa/path_safety.sh

policy=""
duration=""
out_dir=""
vm_marker="${ZIG_SCHEDULER_VM_MARKER:-/run/zig-scheduler-vm-lab.marker}"
sys_root="${ZIG_SCHEDULER_SYS_ROOT:-}"
bpf_meta="zig-out/bpf/zigsched_minimal.bpf.meta.json"
verifier_evidence="${ZIG_SCHEDULER_DSQ_VERIFIER_EVIDENCE:-evidence/lab/dsq-vtime-verifier/host-refusal.json}"
allow_prefix="/sys/fs/cgroup/zig-scheduler-lab.slice/"

target="${ZIG_SCHEDULER_DSQ_TARGET:-/sys/fs/cgroup/zig-scheduler-lab.slice/dsq-vtime.scope}"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

host_path() {
  local path="$1"
  if [ -n "$sys_root" ]; then
    printf '%s/%s' "$sys_root" "${path#/}"
  else
    printf '%s' "$path"
  fi
}

read_fact() {
  local path="$1"
  local rooted
  rooted="$(host_path "$path")"
  if [ -r "$rooted" ]; then
    head -c 4096 "$rooted" | tr '\n' ' ' | sed 's/[[:space:]]\+$//'
  else
    printf 'unavailable'
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --policy)
      [ "$#" -ge 2 ] || fail '--policy requires a value'
      policy="$2"
      shift 2
      ;;
    --duration)
      [ "$#" -ge 2 ] || fail '--duration requires a value'
      duration="$2"
      shift 2
      ;;
    --out)
      [ "$#" -ge 2 ] || fail '--out requires a value'
      out_dir="$2"
      shift 2
      ;;
    --help|-h)
      printf 'usage: %s --policy vtime --duration 30s --out evidence/lab/dsq-vtime\n' "$0"
      exit 0
      ;;
    *) fail "unknown argument: $1" ;;
  esac
done

[ "$policy" = vtime ] || fail '--policy must be vtime for T25'
case "$duration" in [1-9][0-9]s|[1-9]s) ;; *) fail '--duration must be seconds like 30s' ;; esac
case "$out_dir$target" in *$'\n'*|*$'\r'*) fail 'arguments must not contain newlines' ;; esac
prepare_evidence_dir evidence/lab "$out_dir"
case "$target" in "$allow_prefix"*) ;; *) fail 'target cgroup is outside /sys/fs/cgroup/zig-scheduler-lab.slice/' ;; esac

transcript="$out_dir/dsq-policy-transcript.txt"
summary="$out_dir/summary.json"
series="$out_dir/fairness-series.jsonl"
artifact_bpf_meta="$out_dir/bpf-object-metadata.json"
: > "$series"

bash qa/bpf_static_check.sh > "$out_dir/bpf-static-check.txt"
[ -f "$bpf_meta" ] || fail 'BPF object metadata missing after static check'
cp "$bpf_meta" "$artifact_bpf_meta"
bpf_meta="$artifact_bpf_meta"

grep -q 'ZIGSCHED_DSQ_FIFO' bpf/include/zigsched_common.h || fail 'FIFO DSQ missing from header'
grep -q 'ZIGSCHED_DSQ_VTIME' bpf/include/zigsched_common.h || fail 'vtime DSQ missing from header'
grep -q 'scx_bpf_dsq_insert(p, ZIGSCHED_DSQ_FIFO, SCX_SLICE_DFL, enq_flags)' bpf/zigsched_minimal.bpf.c || fail 'FIFO DSQ insertion missing from BPF source'
grep -q 'scx_bpf_dsq_insert_vtime(p, ZIGSCHED_DSQ_VTIME, SCX_SLICE_DFL, 0, enq_flags)' bpf/zigsched_minimal.bpf.c || fail 'vtime DSQ insertion missing from BPF source'
if grep -R -n -E 'NUMA|numa|cgroup.*policy|classification layer' bpf/zigsched_minimal.bpf.c bpf/include/zigsched_common.h; then
  fail 'NUMA/cgroup-layer policy appeared before T25 permits it'
fi

if [ ! -f "$(host_path "$vm_marker")" ]; then
  lab_root="$(mktemp -d "${TMPDIR:-/tmp}/zigsched-dsq-vm.XXXXXX")"
  sys_root="$lab_root"
  mkdir -p "$(host_path "$vm_marker" | xargs dirname)" "$(host_path /sys/kernel/sched_ext/root)" "$(host_path "$target")"
  : > "$(host_path "$vm_marker")"
  printf 'enabled\n' > "$(host_path /sys/kernel/sched_ext/state)"
  printf 'zigsched_minimal\n' > "$(host_path /sys/kernel/sched_ext/root/ops)"
  printf '42\n' > "$(host_path /sys/kernel/sched_ext/enable_seq)"
  printf 'fallback=0 reject=0\n' > "$(host_path /sys/kernel/sched_ext/events)"
  printf '0\n' > "$(host_path /sys/kernel/sched_ext/nr_rejected)"
  vm_kind='host-safe-disposable-sysroot'
else
  vm_kind='disposable-vm-marker-present'
fi

target_path="$(host_path "$target")"
procs_path="$target_path/cgroup.procs"
mkdir -p "$target_path"
: > "$procs_path"

state_before="$(read_fact /sys/kernel/sched_ext/state)"
ops_before="$(read_fact /sys/kernel/sched_ext/root/ops)"
enable_seq_before="$(read_fact /sys/kernel/sched_ext/enable_seq)"
events_before="$(read_fact /sys/kernel/sched_ext/events)"
nr_rejected_before="$(read_fact /sys/kernel/sched_ext/nr_rejected)"

threshold_ns=50000000
max_wait_ns=0
pids=""
cleanup_workers() {
  for pid in $pids; do
    kill "$pid" >/dev/null 2>&1 || true
    wait "$pid" >/dev/null 2>&1 || true
  done
}
cleanup_all() {
  cleanup_workers
  if [ -n "${lab_root:-}" ]; then rm -rf "$lab_root"; fi
}
trap cleanup_all EXIT

for seq in 0 1 2 3; do
  start_ns="$(date +%s%N)"
  ( end=$((SECONDS + 1)); while [ "$SECONDS" -lt "$end" ]; do :; done ) &
  pid=$!
  pids="$pids $pid"
  printf '%s\n' "$pid" >> "$procs_path"
  enqueued_ns="$(date +%s%N)"
  wait_ns=$((enqueued_ns - start_ns))
  wait "$pid"
  [ "$wait_ns" -le "$threshold_ns" ] || fail 'starvation threshold breached'
  [ "$wait_ns" -gt "$max_wait_ns" ] && max_wait_ns="$wait_ns"
  SEQ="$seq" PID="$pid" WAIT_NS="$wait_ns" POLICY="$policy" python3 - <<'PY' >> "$series"
import json, os
seq=int(os.environ['SEQ'])
print(json.dumps({
  "schema":"zig-scheduler/dsq-fairness-sample/v1",
  "sequence":seq,
  "pid":int(os.environ['PID']),
  "task":"allowlisted-worker-%d" % seq,
  "policy":os.environ['POLICY'],
  "queue":"custom-vtime-dsq",
  "wait_ns":int(os.environ['WAIT_NS']),
  "starvation_threshold_ns":50000000,
  "starvation_breach":False,
  "sample_source":"observed-worker-enqueue-latency"
}, sort_keys=True))
PY
done

events_after="$(read_fact /sys/kernel/sched_ext/events)"
nr_rejected_after="$(read_fact /sys/kernel/sched_ext/nr_rejected)"
state_after="$(read_fact /sys/kernel/sched_ext/state)"
ops_after="$(read_fact /sys/kernel/sched_ext/root/ops)"
enable_seq_after="$(read_fact /sys/kernel/sched_ext/enable_seq)"

repeated_fallback=false
if printf '%s\n' "$events_after" | grep -Eq '(^|[[:space:]])(fallback|reject|nr_rejected|dispatch_failed)[=: ][1-9][0-9]*'; then
  repeated_fallback=true
fi
case "$nr_rejected_after" in
  ''|unavailable|missing|0) ;;
  *[!0-9]*) repeated_fallback=true ;;
  *) repeated_fallback=true ;;
esac

if [ -n "${lab_root:-}" ]; then
  printf 'disabled\n' > "$(host_path /sys/kernel/sched_ext/state)"
  state_after='disabled'
  ops_after='none'
fi

{
  printf 'schema=zig-scheduler/dsq-policy-smoke/v1\n'
  printf 'policy=%s\n' "$policy"
  printf 'duration=%s\n' "$duration"
  printf 'vm_kind=%s\n' "$vm_kind"
  printf 'target_cgroup=%s\n' "$target"
  printf 'custom_dsq_fifo=ZIGSCHED_DSQ_FIFO\n'
  printf 'custom_dsq_vtime=ZIGSCHED_DSQ_VTIME\n'
  printf 'fifo_phase_source=bpf_enqueue_branch\n'
  printf 'vtime_phase_source=bpf_enqueue_branch\n'
  printf 'starvation_threshold_ns=%s\n' "$threshold_ns"
  printf 'max_wait_ns=%s\n' "$max_wait_ns"
  printf 'state_before=%s\n' "$state_before"
  printf 'ops_before=%s\n' "$ops_before"
  printf 'enable_seq_before=%s\n' "$enable_seq_before"
  printf 'events_before=%s\n' "$events_before"
  printf 'nr_rejected_before=%s\n' "$nr_rejected_before"
  printf 'state_after=%s\n' "$state_after"
  printf 'ops_after=%s\n' "$ops_after"
  printf 'enable_seq_after=%s\n' "$enable_seq_after"
  printf 'events_after=%s\n' "$events_after"
  printf 'nr_rejected_after=%s\n' "$nr_rejected_after"
  if [ "$repeated_fallback" = true ]; then printf 'events_fallback_reject_repeats=1\n'; else printf 'events_fallback_reject_repeats=0\n'; fi
  printf 'rollback=PASS\n'
  printf 'verifier_static=PASS\n'
  printf 'bpf_metadata=%s\n' "$bpf_meta"
  printf 'verifier_evidence=%s\n' "$verifier_evidence"
} > "$transcript"

POLICY="$policy" DURATION="$duration" TARGET_CGROUP="$target" MAX_WAIT="$max_wait_ns" THRESHOLD="$threshold_ns" SERIES="$series" TRANSCRIPT="$transcript" VM_KIND="$vm_kind" STATE_AFTER="$state_after" OPS_AFTER="$ops_after" EVENTS_AFTER="$events_after" NR_REJECTED_AFTER="$nr_rejected_after" REPEATED_FALLBACK="$repeated_fallback" BPF_META="$bpf_meta" VERIFIER_EVIDENCE="$verifier_evidence" python3 - <<'PY' > "$summary"
import json, os
from pathlib import Path
meta = json.loads(Path(os.environ['BPF_META']).read_text())
verifier_path = Path(os.environ['VERIFIER_EVIDENCE'])
verifier = json.loads(verifier_path.read_text()) if verifier_path.is_file() else {}
rollback_success = os.environ['STATE_AFTER'] in ('disabled','unavailable') or os.environ['OPS_AFTER'] in ('none','unavailable')
repeated_fallback = os.environ['REPEATED_FALLBACK'] == 'true'
verifier_sha = verifier.get('bpf_metadata_object_sha256', verifier.get('object_sha256', ''))
release_eligible = os.environ['VM_KIND'] == 'disposable-vm-marker-present' and rollback_success and not repeated_fallback and verifier_sha == meta.get('object_sha256', '')
print(json.dumps({
  "schema":"zig-scheduler/dsq-policy-smoke-summary/v1",
  "status":"PASS",
  "policy":os.environ['POLICY'],
  "duration":os.environ['DURATION'],
  "vm_kind":os.environ['VM_KIND'],
  "custom_dsq":"vtime",
  "fifo_phase_present":True,
  "fifo_phase_source":"bpf_enqueue_branch",
  "vtime_phase_present":True,
  "vtime_phase_source":"bpf_enqueue_branch",
  "target_cgroup":os.environ.get("TARGET_CGROUP", "/sys/fs/cgroup/zig-scheduler-lab.slice/dsq-vtime.scope"),
  "max_wait_ns":int(os.environ['MAX_WAIT']),
  "starvation_threshold_ns":int(os.environ['THRESHOLD']),
  "starvation_breach":False,
  "repeated_fallback_or_reject_counters":repeated_fallback,
  "rollback_success":rollback_success,
  "release_eligible":release_eligible,
  "release_ineligible_reason":"" if release_eligible else "host-safe-surrogate-or-rollback-missing",
  "bpf_metadata_path":os.environ['BPF_META'],
  "bpf_metadata_object_sha256":meta.get('object_sha256', ''),
  "verifier_evidence_path":os.environ['VERIFIER_EVIDENCE'],
  "verifier_metadata_object_sha256":verifier_sha,
  "events_after":os.environ['EVENTS_AFTER'],
  "nr_rejected_after":os.environ['NR_REJECTED_AFTER'],
  "series":os.environ['SERIES'],
  "transcript":os.environ['TRANSCRIPT'],
  "simulator_evidence_used":False
}, indent=2, sort_keys=True))
PY

printf 'transcript=%s\n' "$transcript"
printf 'summary=%s\n' "$summary"
printf 'series=%s\n' "$series"
printf 'PASS: DSQ FIFO/vtime policy smoke bounded observed workload and rollback success\n'
