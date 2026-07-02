#!/usr/bin/env bash
# Backend-only disposable VM lab runner. Host side stages artifacts and refuses
# missing VM prerequisites; sched_ext load/register/attach remains VM-only.
set -euo pipefail

trusted_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH="$trusted_path:$PATH"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"
source qa/path_safety.sh
source qa/vm/qemu_discovery.sh
source qa/vm/qemu_cleanup.sh
source qa/vm/vm_kernel_validation.sh
source qa/vm/vm_output_safety.sh
source qa/vm/vm_lab_backend_events.sh

mode="host-safe"
out_dir="evidence/lab/vm-backend-final"
qemu_arg="${ZIG_SCHEDULER_QEMU_BIN:-}"
kernel_arg="${ZIG_SCHEDULER_VM_KERNEL:-}"
timeout_seconds="${ZIG_SCHEDULER_VM_BACKEND_TIMEOUT:-600}"
microvm_accel="${ZIG_SCHEDULER_MICROVM_ACCEL:-kvm}"
microvm_mem="${ZIG_SCHEDULER_MICROVM_MEM:-2048M}"
scenario="live-backend"
guest_marker="/run/zig-scheduler-vm-lab.marker"
object_file="zig-out/bpf/zigsched_minimal.bpf.o"
meta_file="zig-out/bpf/zigsched_minimal.bpf.meta.json"
seq=1

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'USAGE'
usage: zig build vm-lab-backend -- [--mode host-safe|auto|vm-required] --out evidence/lab/<run-id> [--scenario live-backend|workload-*] [--kernel /boot/vmlinuz-...] [--qemu /trusted/qemu-system-x86_64] [--accel kvm|tcg] [--mem 1024M]

Backend-only disposable VM lab runner:
  - root host remains fail-closed; no host sched_ext/BPF/cgroup mutation is attempted
  - stages the C/clang-built sched_ext BPF object, metadata, and guest scripts
  - validates explicit kernel images before launching QEMU
  - emits daemon event JSONL for boot/marker/verifier/attach/runtime_sample/rollback/cleanup/validation/incident
  - --mode vm-required exits non-zero on missing QEMU/KVM/kernel/tuple prerequisites
  - --mode host-safe records a typed SKIP/refusal bundle instead of claiming VM success
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --mode) [ "$#" -ge 2 ] || fail '--mode requires value'; mode="$2"; shift 2 ;;
    --out) [ "$#" -ge 2 ] || fail '--out requires value'; out_dir="$2"; shift 2 ;;
    --kernel) [ "$#" -ge 2 ] || fail '--kernel requires value'; kernel_arg="$2"; shift 2 ;;
    --qemu) [ "$#" -ge 2 ] || fail '--qemu requires value'; qemu_arg="$2"; shift 2 ;;
    --accel) [ "$#" -ge 2 ] || fail '--accel requires value'; microvm_accel="$2"; shift 2 ;;
    --mem) [ "$#" -ge 2 ] || fail '--mem requires value'; microvm_mem="$2"; shift 2 ;;
    --scenario) [ "$#" -ge 2 ] || fail '--scenario requires value'; scenario="$2"; shift 2 ;;
    --timeout) [ "$#" -ge 2 ] || fail '--timeout requires value'; timeout_seconds="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

case "$mode" in host-safe|auto|vm-required) ;; *) fail '--mode must be host-safe, auto, or vm-required' ;; esac
case "$scenario" in live-backend|workload-cpu-saturation|workload-cgroup-weight-quota|workload-interactive-latency|workload-scheduler-affinity-churn) ;; *) fail '--scenario must be live-backend or a protected-core workload scenario' ;; esac
case "$out_dir$qemu_arg$kernel_arg$timeout_seconds$microvm_accel$microvm_mem$scenario" in *$'\n'*|*$'\r'*) fail 'arguments must not contain newlines' ;; esac
case "$timeout_seconds" in ''|*[!0-9]*) fail '--timeout must be a positive integer' ;; esac
[ "$timeout_seconds" -gt 0 ] || fail '--timeout must be positive'
case "$microvm_accel" in kvm|tcg) ;; *) fail 'ZIG_SCHEDULER_MICROVM_ACCEL must be kvm or tcg' ;; esac
case "$microvm_mem" in *[!A-Za-z0-9_.,:-]*) fail '--mem contains unsafe characters' ;; esac

command_available() { command -v "$1" >/dev/null 2>&1; }

validate_workload_tool_name() {
  case "$1" in
    stress-ng|cyclictest|perf|taskset|chrt) return 0 ;;
    *) fail 'unsafe forced missing workload tool' ;;
  esac
}

workload_tool_required_by_scenario() {
  local scenario_id="$1" tool="$2"
  case "$scenario_id:$tool" in
    workload-cpu-saturation:stress-ng) return 0 ;;
    workload-cgroup-weight-quota:stress-ng) return 0 ;;
    workload-interactive-latency:cyclictest|workload-interactive-latency:perf) return 0 ;;
    workload-scheduler-affinity-churn:stress-ng|workload-scheduler-affinity-churn:taskset|workload-scheduler-affinity-churn:chrt) return 0 ;;
    *) return 1 ;;
  esac
}

workload_missing_prereq() {
  local scenario_id="$1" forced="${ZIGSCHED_FORCE_MISSING_WORKLOAD_TOOL:-}"
  [ "$scenario_id" != live-backend ] || return 1
  if [ -n "$forced" ]; then
    validate_workload_tool_name "$forced"
    if workload_tool_required_by_scenario "$scenario_id" "$forced"; then
      printf '%s' "$forced"
      return 0
    fi
    return 1
  fi
  case "$scenario_id" in
    workload-cpu-saturation|workload-cgroup-weight-quota) command_available stress-ng || { printf 'stress-ng'; return 0; } ;;
    workload-interactive-latency) command_available cyclictest || { printf 'cyclictest'; return 0; }; command_available perf || { printf 'perf'; return 0; } ;;
    workload-scheduler-affinity-churn) command_available stress-ng || { printf 'stress-ng'; return 0; }; command_available taskset || { printf 'taskset'; return 0; }; command_available chrt || { printf 'chrt'; return 0; } ;;
    *) return 1 ;;
  esac
  return 1
}

prepare_owned_out_dir() {
  vm_output_safety_prepare_owned_dir evidence/lab "$out_dir" .zig-scheduler-vm-backend-owned
}

stage_guest_inputs() {
  bash tools/build_bpf.sh > "$out_dir/build-bpf.txt" 2>&1 || return 1
  python3 - "$object_file" "$meta_file" > "$out_dir/bpf-metadata-validation.txt" <<'PY'
import hashlib, json, sys
from pathlib import Path
obj = Path(sys.argv[1]); meta_path = Path(sys.argv[2])
if not obj.is_file(): raise SystemExit(f"missing BPF object: {obj}")
if not meta_path.is_file(): raise SystemExit(f"missing BPF metadata: {meta_path}")
meta = json.loads(meta_path.read_text()); obj_sha = hashlib.sha256(obj.read_bytes()).hexdigest()
if meta.get("schema") != "zig-scheduler/bpf-object-metadata/v1": raise SystemExit("metadata schema mismatch")
if meta.get("object_sha256") != obj_sha or meta.get("object_hash") != "sha256:" + obj_sha: raise SystemExit("metadata object hash does not match object")
if meta.get("host_mutation") is not False or meta.get("host_attach_allowed") is not False or meta.get("vm_only") is not True: raise SystemExit("metadata does not preserve VM-only host-safe boundary")
if meta.get("vm_marker_required") != "/run/zig-scheduler-vm-lab.marker": raise SystemExit("metadata VM marker mismatch")
for key in ("policy_name", "tuple", "tool_versions", "struct_ops"):
    if key not in meta: raise SystemExit(f"metadata missing {key}")
print(obj_sha)
PY
  object_sha="$(tail -n 1 "$out_dir/bpf-metadata-validation.txt")"
  stage_dir="$out_dir/staged/guest-input"
  mkdir -p "$stage_dir/zig-out/bpf" "$stage_dir/qa/vm"
  cp "$object_file" "$stage_dir/zig-out/bpf/"
  cp "$meta_file" "$stage_dir/zig-out/bpf/"
  cp qa/vm/verifier_only.sh qa/vm/partial_attach.sh qa/vm/observe_partial.sh qa/vm/rollback_drill.sh qa/vm/incident_drill.sh "$stage_dir/qa/vm/"
  STAGE_DIR="$stage_dir" STAGING_MANIFEST="$staging_manifest" OBJECT_SHA="$object_sha" GUEST_MARKER="$guest_marker" python3 - <<'PY'
import hashlib, json, os
from pathlib import Path
stage = Path(os.environ["STAGE_DIR"])
files = [{"path": p.relative_to(stage).as_posix(), "sha256": hashlib.sha256(p.read_bytes()).hexdigest()} for p in sorted(stage.rglob("*")) if p.is_file()]
manifest = {"schema":"zig-scheduler/vm-backend-staging/v1","status":"PASS","stage_dir":stage.as_posix(),"guest_marker_required":os.environ["GUEST_MARKER"],"object_sha256":os.environ["OBJECT_SHA"],"metadata_hash_matches_object":True,"copy_in":files,"host_mutation":False}
Path(os.environ["STAGING_MANIFEST"]).write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

record_refusal() {
  local status="$1" code="$2" detail="$3" hard_failure="$4"
  qemu_scan_processes "$qemu_after"
  write_cleanup PASS true
  write_incident "$code" "$detail" "$hard_failure"
  emit_refusal_lifecycle "$status" "$code" refused_host
  write_summary "$status" "$code" host-safe-refusal false
  cat "$event_file"
  printf '%s: %s\nsummary=%s\ndaemon_events=%s\nstaging_manifest=%s\n' "$status" "$detail" "$summary_file" "$event_file" "$staging_manifest"
}

prepare_owned_out_dir
cat > "$out_dir/.gitignore" <<'EOF'
*
!.gitignore
EOF
safe_base="$(basename -- "$out_dir" | tr -c 'A-Za-z0-9_.-' '-' | cut -c 1-40)"
[ -n "$safe_base" ] || safe_base="vm-backend"
run_id="$safe_base"; action_id="act-$safe_base"; rollback_id="RB-$safe_base"
event_file="$out_dir/daemon-events.jsonl"; summary_file="$out_dir/summary.json"; incident_file="$out_dir/incident.json"
cleanup_file="$out_dir/cleanup-receipt.json"; staging_manifest="$out_dir/staging-manifest.json"
qemu_before="$out_dir/qemu-process-scan-before.txt"; qemu_after="$out_dir/qemu-process-scan-after.txt"
mutation_refusal_dir="$out_dir/mutation-refusals"
: > "$event_file"
qemu_scan_processes "$qemu_before"

write_host_mutation_refusals() {
  MUTATION_REFUSAL_DIR="$mutation_refusal_dir" python3 - <<'PY'
import json
import os
from pathlib import Path

fields = {
    "schema": "zig-scheduler/lab-evidence/v1",
    "evidence_mode": "host-refusal",
    "status": "REFUSE",
    "reason": "host mutation refused; VM marker required",
    "host_mutation": False,
    "release_eligible": False,
    "vm_marker_present": False,
    "target_allowlisted": False,
    "no_bpf_load_attach": True,
    "no_cgroup_write": True,
    "no_cpuset_write": True,
    "no_affinity_write": True,
    "no_priority_write": True,
    "no_sys_write": True,
    "no_proc_write": True,
}
out = Path(os.environ["MUTATION_REFUSAL_DIR"])
out.mkdir(parents=True, exist_ok=True)
for mutation in ("cgroup.weight", "cpu.max", "uclamp", "topology.offline_cpu"):
    payload = dict(fields)
    payload["mutation"] = mutation
    (out / f"{mutation}.json").write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
PY
}
write_host_mutation_refusals

scratch=""
cleanup_trap() { [ -z "$scratch" ] || [ ! -d "$scratch" ] || rm -rf "$scratch"; qemu_scan_processes "$qemu_after"; }
trap cleanup_trap EXIT INT TERM HUP

if ! stage_guest_inputs; then
  record_refusal REFUSE bpf_build_unavailable "BPF build/metadata staging failed; see $out_dir/build-bpf.txt" true
  exit 1
fi

hard_failure=false; [ "$mode" = vm-required ] && hard_failure=true
prereq_code=""; prereq_detail=""; qemu_bin=""; kernel_image=""
if [ -n "$kernel_arg" ]; then
  kernel_image="$(vm_kernel_validate_image "$kernel_arg" 2> "$out_dir/kernel-validation.txt" || true)"
  if [ -z "$kernel_image" ]; then prereq_code="kernel_image_untrusted_or_invalid"; prereq_detail="$(cat "$out_dir/kernel-validation.txt")"; fi
fi
if [ -z "$prereq_code" ]; then
  if [ -n "$qemu_arg" ]; then
    qemu_bin="$(qemu_discovery_validate_override "$qemu_arg" 2>/dev/null || true)"
    [ -n "$qemu_bin" ] || { prereq_code="qemu_untrusted_or_unavailable"; prereq_detail="qemu override refused or unavailable"; }
  else
    qemu_bin="$(qemu_discovery_find 2>/dev/null || true)"
    [ -n "$qemu_bin" ] || { prereq_code="qemu_untrusted_or_unavailable"; prereq_detail="trusted qemu-system-x86_64 not found"; }
  fi
fi
if [ -z "$prereq_code" ] && [ "$microvm_accel" = kvm ] && [ ! -e /dev/kvm ]; then prereq_code="kvm_unavailable"; prereq_detail="/dev/kvm is required for VM-required sched_ext lab"; fi
if [ -z "$prereq_code" ] && [ "$(uname -m)" != x86_64 ]; then prereq_code="arch_unsupported"; prereq_detail="x86_64 host/guest tuple is required"; fi
if [ -z "$prereq_code" ] && [ -z "$kernel_image" ]; then
  kernel_image="$(vm_kernel_find_image "" 2> "$out_dir/kernel-validation.txt" || true)"
  [ -n "$kernel_image" ] || { prereq_code="kernel_image_unavailable"; prereq_detail="readable trusted VM kernel image not found; pass --kernel /boot/vmlinuz-* or another trusted bzImage"; }
fi
if [ -z "$prereq_code" ] && missing_tool="$(workload_missing_prereq "$scenario")"; then prereq_code="workload_tool_unavailable"; prereq_detail="protected-core workload $scenario requires VM-local tool $missing_tool"; fi
if [ -z "$prereq_code" ]; then
  nix_bin="$(command -v nix 2>/dev/null || true)"
  [ -n "$nix_bin" ] || { prereq_code="nix_busybox_unavailable"; prereq_detail="nix is required to stage static busybox initramfs for the microVM runner"; }
fi

if [ -n "$prereq_code" ]; then
  status="SKIP"; [ "$hard_failure" = true ] && status="REFUSE"
  record_refusal "$status" "$prereq_code" "$prereq_detail" "$hard_failure"
  [ "$hard_failure" = true ] && exit 1 || exit 0
fi

live_dir="$out_dir/live"; runner_stdout="$out_dir/runner.stdout.txt"; runner_stderr="$out_dir/runner.stderr.txt"
set +e
ZIG_SCHEDULER_QEMU_BIN="$qemu_bin" ZIG_SCHEDULER_VM_KERNEL="$kernel_image" ZIG_SCHEDULER_MICROVM_ACCEL="$microvm_accel" ZIG_SCHEDULER_MICROVM_MEM="$microvm_mem" ZIG_SCHEDULER_MICROVM_TIMEOUT="$timeout_seconds" ZIG_SCHEDULER_VM_WORKLOAD_SCENARIO="$scenario" timeout "$timeout_seconds" bash qa/vm/run_microvm_live_lab.sh --out "$live_dir" --kernel "$kernel_image" --qemu "$qemu_bin" --scenario "$scenario" > "$runner_stdout" 2> "$runner_stderr"
runner_rc=$?
set -e
qemu_scan_processes "$qemu_after"
write_cleanup PASS true
new_seq="$(normalize_runner_events "$runner_stdout")"; seq="$new_seq"

if [ "$runner_rc" -ne 0 ]; then
  write_incident runner_failed "microVM runner failed rc=$runner_rc; see runner stdout/stderr" true
  emit_refusal_lifecycle REFUSE runner_failed refused_guest
  live_summary=""; [ -f "$live_dir/summary.json" ] && live_summary="$live_dir/summary.json"
  write_summary REFUSE runner_failed qemu-vm false "$live_summary"
  cat "$event_file"
  printf 'REFUSE: microVM runner failed rc=%s\nsummary=%s\ndaemon_events=%s\n' "$runner_rc" "$summary_file" "$event_file"
  exit 1
fi

if ! grep -q '"event":"incident"' "$event_file"; then
  json_event_append incident PASS no_incident "no incident observed by VM runner" "$summary_file"
fi
json_event_append validation PASS vm_live_validated "VM backend event stream captured" "$live_dir/summary.json" "" "$live_dir/summary.json"
write_incident none "no incident observed" false
write_summary PASS vm_live_complete qemu-vm false "$live_dir/summary.json"
cat "$event_file"
printf 'PASS: disposable VM backend completed\nsummary=%s\ndaemon_events=%s\nstaging_manifest=%s\nlive_summary=%s\n' "$summary_file" "$event_file" "$staging_manifest" "$live_dir/summary.json"
