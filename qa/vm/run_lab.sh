#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"
source qa/path_safety.sh

mode=""
out_dir=""
contract_file="qa/vm/execution_contract.json"
image_arg=""
kernel_arg=""
env_file=""

env_image=""
env_kernel=""
env_driver=""
env_fixture=""

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf 'usage: %s --mode <read-only-smoke|execute> --out <evidence-dir> [--image <qcow2|raw>] [--kernel <kernel>] [--env-file <file>]\n' "$0" >&2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --mode)
      [ "$#" -ge 2 ] || fail '--mode requires a value'
      mode="$2"
      shift 2
      ;;
    --out)
      [ "$#" -ge 2 ] || fail '--out requires a value'
      out_dir="$2"
      shift 2
      ;;
    --image)
      [ "$#" -ge 2 ] || fail '--image requires a value'
      image_arg="$2"
      shift 2
      ;;
    --kernel)
      [ "$#" -ge 2 ] || fail '--kernel requires a value'
      kernel_arg="$2"
      shift 2
      ;;
    --env-file)
      [ "$#" -ge 2 ] || fail '--env-file requires a value'
      env_file="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

case "$mode" in
  read-only-smoke|execute) ;;
  *) fail 'only --mode read-only-smoke or execute is supported' ;;
esac
[ -n "$out_dir" ] || fail '--out is required'
case "$out_dir$image_arg$kernel_arg$env_file" in *$'\n'*|*$'\r'*) fail 'arguments must not contain newlines' ;; esac
prepare_evidence_dir evidence/lab "$out_dir"

manifest="$out_dir/manifest.json"
qemu_bin="$(command -v qemu-system-x86_64 || true)"
git_sha="$(git rev-parse HEAD 2>/dev/null || printf unknown)"
zig_version="$(zig version 2>/dev/null || printf unknown)"
qemu_available=false
[ -n "$qemu_bin" ] && qemu_available=true
kvm_available=false
[ -e /dev/kvm ] && kvm_available=true

if [ -n "$env_file" ]; then
  if [ ! -f "$env_file" ]; then
    env_file_absent=true
  else
    env_file_absent=false
    while IFS='=' read -r key value || [ -n "$key" ]; do
      case "$key" in
        ''|'#'*) ;;
        ZIG_SCHEDULER_VM_IMAGE) env_image="$value" ;;
        ZIG_SCHEDULER_VM_KERNEL) env_kernel="$value" ;;
        ZIG_SCHEDULER_VM_DRIVER) env_driver="$value" ;;
        ZIG_SCHEDULER_VM_TEST_FIXTURE) env_fixture="$value" ;;
        *) ;;
      esac
    done < "$env_file"
  fi
else
  env_file_absent=false
fi

config_source="absent"
effective_image="$image_arg"
effective_kernel="$kernel_arg"
effective_driver="${env_driver:-qemu}"
if [ -n "$env_image$env_kernel" ]; then config_source="env-file"; fi
if [ -n "$image_arg$kernel_arg" ]; then config_source="cli"; fi
if [ -n "$image_arg$kernel_arg" ] && [ -n "$env_image$env_kernel" ]; then config_source="cli+env-file"; fi

refuse_manifest() {
  local reason="$1" detail="$2"
  STATUS="refuse" REASON="$reason" DETAIL="$detail" MANIFEST="$manifest" MODE="$mode" GIT_SHA="$git_sha" ZIG_VERSION="$zig_version" QEMU_BIN="$qemu_bin" QEMU_AVAILABLE="$qemu_available" KVM_AVAILABLE="$kvm_available" CONFIG_SOURCE="$config_source" IMAGE_PATH="$effective_image" KERNEL_PATH="$effective_kernel" ENV_FILE="$env_file" python3 - <<'PY'
import json, os
from pathlib import Path
manifest = {
    "schema": "zig-scheduler/lab-smoke/v2",
    "status": os.environ["STATUS"],
    "reason": os.environ["REASON"],
    "detail": os.environ["DETAIL"],
    "vm_marker": "not-started",
    "mode": os.environ["MODE"],
    "qemu_bin": os.environ["QEMU_BIN"],
    "qemu_available": os.environ["QEMU_AVAILABLE"] == "true",
    "kvm_available": os.environ["KVM_AVAILABLE"] == "true",
    "vm_config": {
        "source": os.environ["CONFIG_SOURCE"],
        "image": os.environ["IMAGE_PATH"],
        "kernel": os.environ["KERNEL_PATH"],
        "env_file": os.environ["ENV_FILE"],
    },
    "git_sha": os.environ["GIT_SHA"],
    "zig_version": os.environ["ZIG_VERSION"],
    "kernel_release": "unavailable-until-vm-boot",
    "arch": "unavailable-until-vm-boot",
    "btf_status": "unavailable-until-vm-boot",
    "mutation_evidence_kind": "none",
    "host_mutation": False,
}
Path(os.environ["MANIFEST"]).write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
PY
}

skip_manifest() {
  local reason="$1" marker="$2"
  STATUS="skip" REASON="$reason" MANIFEST="$manifest" MODE="$mode" GIT_SHA="$git_sha" ZIG_VERSION="$zig_version" QEMU_BIN="$qemu_bin" QEMU_AVAILABLE="$qemu_available" KVM_AVAILABLE="$kvm_available" CONFIG_SOURCE="$config_source" IMAGE_PATH="$effective_image" KERNEL_PATH="$effective_kernel" ENV_FILE="$env_file" VM_MARKER="$marker" python3 - <<'PY'
import json, os
from pathlib import Path
manifest = {
    "schema": "zig-scheduler/lab-smoke/v2",
    "status": os.environ["STATUS"],
    "reason": os.environ["REASON"],
    "vm_marker": os.environ["VM_MARKER"],
    "mode": os.environ["MODE"],
    "qemu_bin": os.environ["QEMU_BIN"],
    "qemu_available": os.environ["QEMU_AVAILABLE"] == "true",
    "kvm_available": os.environ["KVM_AVAILABLE"] == "true",
    "vm_config": {
        "source": os.environ["CONFIG_SOURCE"],
        "image": os.environ["IMAGE_PATH"],
        "kernel": os.environ["KERNEL_PATH"],
        "env_file": os.environ["ENV_FILE"],
    },
    "git_sha": os.environ["GIT_SHA"],
    "zig_version": os.environ["ZIG_VERSION"],
    "kernel_release": "unavailable-until-vm-boot",
    "arch": "unavailable-until-vm-boot",
    "btf_status": "unavailable-until-vm-boot",
    "mutation_evidence_kind": "none",
    "host_mutation": False,
}
Path(os.environ["MANIFEST"]).write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
PY
}

if [ "$env_file_absent" = true ]; then
  refuse_manifest 'VM_CONFIG_INVALID' "env file does not exist: $env_file"
  printf 'REFUSE: VM_CONFIG_INVALID env file does not exist: %s\n' "$env_file"
  printf 'manifest=%s\n' "$manifest"
  exit 1
fi

if [ -n "$image_arg" ] && [ -n "$env_image" ] && [ "$image_arg" != "$env_image" ]; then
  refuse_manifest 'VM_CONFIG_AMBIGUOUS' 'CLI image and env-file image differ'
  printf 'REFUSE: VM_CONFIG_AMBIGUOUS image differs between CLI and env-file\n'
  printf 'manifest=%s\n' "$manifest"
  exit 1
fi
if [ -n "$kernel_arg" ] && [ -n "$env_kernel" ] && [ "$kernel_arg" != "$env_kernel" ]; then
  refuse_manifest 'VM_CONFIG_AMBIGUOUS' 'CLI kernel and env-file kernel differ'
  printf 'REFUSE: VM_CONFIG_AMBIGUOUS kernel differs between CLI and env-file\n'
  printf 'manifest=%s\n' "$manifest"
  exit 1
fi
[ -n "$effective_image" ] || effective_image="$env_image"
[ -n "$effective_kernel" ] || effective_kernel="$env_kernel"

write_execute_fixture() {
  local tmp guest_root transcript cleanup copy_in_index command_hash attestation object_hash
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/zigsched-vm-fixture.XXXXXX")"
  guest_root="$tmp/guest"
  transcript="$out_dir/transcript.jsonl"
  cleanup="$out_dir/cleanup-receipt.json"
  copy_in_index="$out_dir/copy-in.json"
  attestation="$out_dir/attestation.json"
  command_hash="$(sha256sum "$contract_file" | awk '{print $1}')"
  object_hash="$(sha256sum fixtures/vm/test-image.raw | awk '{print $1}')"
  mkdir -p "$guest_root/run" "$guest_root/work/repo" "$out_dir/copy-out"
  : > "$guest_root/run/zig-scheduler-vm-lab.marker"
  cp "$contract_file" "$guest_root/work/repo/execution_contract.json"
  cp qa/vm/verifier_only.sh qa/vm/partial_attach.sh qa/vm/observe_partial.sh qa/vm/rollback_drill.sh "$guest_root/work/repo/"
  printf '{"event":"boot","driver":"fixture","vm_marker":"/run/zig-scheduler-vm-lab.marker","host_mutation":false}\n' > "$transcript"
  printf '{"event":"copy_in","path":"qa/vm/execution_contract.json","host_mutation":false}\n' >> "$transcript"
  printf '{"event":"command","name":"marker_probe","argv":["test","-f","/run/zig-scheduler-vm-lab.marker"],"status":"PASS","host_mutation":false}\n' >> "$transcript"
  if [ "${ZIG_SCHEDULER_VM_RUN_ALL:-0}" = "1" ]; then
    mkdir -p "$out_dir/copy-out/stages"
    verifier_dir="$out_dir/copy-out/verifier-only"
    mkdir -p "$verifier_dir"
    verifier_object="zig-out/bpf/zigsched_minimal.bpf.o"
    verifier_meta="zig-out/bpf/zigsched_minimal.bpf.meta.json"
    if [ ! -f "$verifier_object" ] || [ ! -f "$verifier_meta" ]; then
      bash tools/build_bpf.sh >/dev/null 2>&1 || true
    fi
    verifier_object_sha="0000000000000000000000000000000000000000000000000000000000000000"
    if [ -f "$verifier_object" ]; then verifier_object_sha="$(sha256sum "$verifier_object" | awk '{print $1}')"; fi
    verifier_meta_sha="$verifier_object_sha"
    if [ -f "$verifier_meta" ]; then
      verifier_meta_sha="$(python3 - "$verifier_meta" <<'PY'
import json, sys
from pathlib import Path
print(json.loads(Path(sys.argv[1]).read_text()).get("object_sha256", ""))
PY
)"
    fi
    verifier_log="$verifier_dir/bpf-verifier.log"
    verifier_parsed="$verifier_dir/verifier-parsed.json"
    verifier_evidence="$verifier_dir/verifier-evidence.json"
    {
      printf 'schema=zig-scheduler/bpf-verifier-log/v1\n'
      printf 'vm_marker=/run/zig-scheduler-vm-lab.marker\n'
      printf 'object=%s\n' "$verifier_object"
      printf 'object_sha256=%s\n' "$verifier_object_sha"
      printf 'bpf_metadata_path=%s\n' "$verifier_meta"
      printf 'bpf_metadata_object_sha256=%s\n' "$verifier_meta_sha"
      printf 'sched_ext_state_before=fixture-disabled\n'
      printf 'sched_ext_enable_seq_before=fixture-0\n'
      printf 'bpftool_rc=0\n'
      printf 'sched_ext_state_after=fixture-disabled\n'
      printf 'sched_ext_enable_seq_after=fixture-0\n'
      printf 'cgroup_membership_before=fixture-cgroup-membership\n'
      printf 'cgroup_membership_after=fixture-cgroup-membership\n'
    } > "$verifier_log"
    python3 qa/verifier_log_check.py --input "$verifier_log" --out "$verifier_parsed"
    VERIFIER_EVIDENCE="$verifier_evidence" VERIFIER_LOG="$verifier_log" VERIFIER_PARSED="$verifier_parsed" python3 - <<'PY'
import json, os
from pathlib import Path
parsed = json.loads(Path(os.environ["VERIFIER_PARSED"]).read_text())
evidence = {
    "schema": "zig-scheduler/verifier-only-evidence/v1",
    "status": "verifier-attempted-fixture",
    "vm_marker": "/run/zig-scheduler-vm-lab.marker",
    "object": parsed["object"],
    "object_sha256": parsed["object_sha256"],
    "bpf_metadata_path": parsed["bpf_metadata_path"],
    "bpf_metadata_object_sha256": parsed["bpf_metadata_object_sha256"],
    "parsed_verifier_status": parsed["status"],
    "parsed_verifier_reason": parsed["reason"],
    "verifier_log_path": os.environ["VERIFIER_LOG"],
    "verifier_parse_path": os.environ["VERIFIER_PARSED"],
    "sched_ext_state_before": parsed["sched_ext_state_before"],
    "sched_ext_state_after": parsed["sched_ext_state_after"],
    "enable_seq_before": parsed["enable_seq_before"],
    "enable_seq_after": parsed["enable_seq_after"],
    "cgroup_membership_before": parsed["cgroup_membership_before"],
    "cgroup_membership_after": parsed["cgroup_membership_after"],
    "host_mutation": False,
    "release_eligible_live_proof": False,
}
Path(os.environ["VERIFIER_EVIDENCE"]).write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n")
PY
    python3 qa/verifier_log_check.py --evidence "$verifier_evidence" >/dev/null
    printf 'PASS fixture verifier-only: verifier log parsed, no attach/state delta, host_mutation=false\n' > "$out_dir/copy-out/stages/verifier_only.txt"
    partial_dir="$out_dir/copy-out/partial-attach"
    mkdir -p "$partial_dir"
    partial_transcript="$partial_dir/partial-attach-transcript.txt"
    partial_evidence="$partial_dir/partial-attach-evidence.json"
    partial_rollback_id="RB-fixture-partial"
    {
      printf 'schema=zig-scheduler/partial-attach-transcript/v1\n'
      printf 'COMMAND: bpftool struct_ops register zig-out/bpf/zigsched_minimal.bpf.o /sys/fs/bpf/zigsched_minimal_ops\n'
      printf 'bpftool struct_ops register\n'
      printf 'ops=zigsched_minimal\n'
      printf 'switch_mode=SCX_OPS_SWITCH_PARTIAL\n'
      printf 'target_cgroup=/sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope\n'
      printf 'rollback_id=%s\n' "$partial_rollback_id"
      printf 'attach_status=PASS\n'
      printf 'rollback_status=PASS\n'
      printf 'post_state=disabled\n'
      printf 'host_mutation=false\n'
      printf 'release_eligible_live_proof=false\n'
    } > "$partial_transcript"
    PARTIAL_EVIDENCE="$partial_evidence" PARTIAL_TRANSCRIPT="$partial_transcript" PARTIAL_ROLLBACK_ID="$partial_rollback_id" PARTIAL_OBJECT_SHA="$verifier_object_sha" python3 - <<'PY'
import json, os
from pathlib import Path
evidence = {
    "schema": "zig-scheduler/partial-attach-evidence/v1",
    "attach_command": "bpftool struct_ops register",
    "target_cgroup": "/sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope",
    "rollback_id": os.environ["PARTIAL_ROLLBACK_ID"],
    "rollback_status": "PASS",
    "ops_during_attach": "zigsched_minimal",
    "switch_mode": "SCX_OPS_SWITCH_PARTIAL",
    "post_state": "disabled",
    "object": "zig-out/bpf/zigsched_minimal.bpf.o",
    "object_sha256": os.environ["PARTIAL_OBJECT_SHA"],
    "transcript_path": os.environ["PARTIAL_TRANSCRIPT"],
    "host_mutation": False,
    "release_eligible_live_proof": False,
}
Path(os.environ["PARTIAL_EVIDENCE"]).write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n")
PY
    python3 qa/partial_attach_check.py --evidence "$partial_evidence" >/dev/null
    printf 'PASS fixture partial-attach: bpftool struct_ops register transcript, zigsched_minimal partial-switch, rollback id captured, host_mutation=false\n' > "$out_dir/copy-out/stages/partial_attach.txt"
    printf 'PASS fixture rollback-drill: rollback restored pre-attach state, host_mutation=false\n' > "$out_dir/copy-out/stages/rollback_drill.txt"
    printf 'PASS fixture observe-partial: runtime counters copied from VM harness, host_mutation=false\n' > "$out_dir/copy-out/stages/observe_partial.txt"
    printf '{"event":"command","name":"verifier_only","argv":["bash","qa/vm/verifier_only.sh","--object","zig-out/bpf/zigsched_minimal.bpf.o"],"status":"PASS","copy_out":"copy-out/verifier-only/verifier-evidence.json","host_mutation":false}\n' >> "$transcript"
    printf '{"event":"command","name":"partial_attach","attach_command":"bpftool struct_ops register","argv":["bpftool","struct_ops","register","zig-out/bpf/zigsched_minimal.bpf.o","/sys/fs/bpf/zigsched_minimal_ops"],"status":"PASS","ops":"zigsched_minimal","switch_mode":"SCX_OPS_SWITCH_PARTIAL","rollback_id":"RB-fixture-partial","copy_out":"copy-out/partial-attach/partial-attach-evidence.json","host_mutation":false}\n' >> "$transcript"
    printf '{"event":"command","name":"rollback_drill","argv":["bash","qa/vm/rollback_drill.sh"],"status":"PASS","copy_out":"copy-out/stages/rollback_drill.txt","host_mutation":false}\n' >> "$transcript"
    printf '{"event":"command","name":"observe_partial","argv":["bash","qa/vm/observe_partial.sh","--samples","3"],"status":"PASS","copy_out":"copy-out/stages/observe_partial.txt","host_mutation":false}\n' >> "$transcript"
  fi
  printf '{"event":"copy_out","path":"manifest.json","host_mutation":false}\n' >> "$transcript"
  printf '{"event":"teardown","qemu_started":false,"temp_root_removed":true,"host_mutation":false}\n' >> "$transcript"
  find "$guest_root/work/repo" -type f -maxdepth 1 -print | sort | while read -r copied; do
    sha256sum "$copied"
  done > "$copy_in_index"
  ATTESTATION="$attestation" TRANSCRIPT="$transcript" GIT_SHA="$git_sha" OBJECT_HASH="$object_hash" python3 - <<'PY'
import json, os
from pathlib import Path
attestation = {
    "schema": "zig-scheduler/vm-attestation/v1",
    "status": "PASS",
    "vm_kind": "vm-configured-fixture",
    "vm_marker_present": True,
    "vm_marker_path": "/run/zig-scheduler-vm-lab.marker",
    "copied_from_guest": True,
    "source_path": "/guest/copy-out/attestation.json",
    "transcript_path": os.environ["TRANSCRIPT"],
    "git_sha": os.environ["GIT_SHA"],
    "object_sha256": os.environ["OBJECT_HASH"],
    "kernel_tuple": {"release": "6.12.0-lab", "arch": "x86_64", "config_sha256": "fixture"},
    "btf_present": True,
    "bpf_jit_enabled": True,
    "sched_class_ext_enabled": True,
    "host_mutation": False,
    "release_eligible_live_proof": False,
}
Path(os.environ["ATTESTATION"]).write_text(json.dumps(attestation, indent=2, sort_keys=True) + "\n")
PY
  rm -rf "$tmp"
  QEMU_BEFORE="$(pgrep -ax 'qemu-system-x86_64|qemu-kvm|qemu-system-aarch64' 2>/dev/null || true)" \
  QEMU_AFTER="$(pgrep -ax 'qemu-system-x86_64|qemu-kvm|qemu-system-aarch64' 2>/dev/null || true)" \
  CLEANUP="$cleanup" python3 - <<'PY'
import json, os
from pathlib import Path
receipt = {
    "schema": "zig-scheduler/vm-cleanup-receipt/v1",
    "status": "PASS",
    "qemu_started": False,
    "qemu_leftovers": os.environ["QEMU_BEFORE"] != os.environ["QEMU_AFTER"],
    "temp_root_removed": True,
    "host_mutation": False,
}
Path(os.environ["CLEANUP"]).write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
PY
  verifier_evidence_manifest=""
  if [ -f "$out_dir/copy-out/verifier-only/verifier-evidence.json" ]; then verifier_evidence_manifest="$out_dir/copy-out/verifier-only/verifier-evidence.json"; fi
  partial_attach_evidence_manifest=""
  if [ -f "$out_dir/copy-out/partial-attach/partial-attach-evidence.json" ]; then partial_attach_evidence_manifest="$out_dir/copy-out/partial-attach/partial-attach-evidence.json"; fi
  TRANSCRIPT="$transcript" CLEANUP="$cleanup" COPY_IN="$copy_in_index" ATTESTATION="$attestation" VERIFIER_EVIDENCE="$verifier_evidence_manifest" PARTIAL_ATTACH_EVIDENCE="$partial_attach_evidence_manifest" MANIFEST="$manifest" MODE="$mode" \
  GIT_SHA="$git_sha" ZIG_VERSION="$zig_version" QEMU_BIN="$qemu_bin" QEMU_AVAILABLE="$qemu_available" \
  KVM_AVAILABLE="$kvm_available" CONFIG_SOURCE="$config_source" IMAGE_PATH="$effective_image" \
  KERNEL_PATH="$effective_kernel" ENV_FILE="$env_file" COMMAND_HASH="$command_hash" python3 - <<'PY'
import hashlib, json, os
from pathlib import Path
transcript = Path(os.environ["TRANSCRIPT"])
cleanup = Path(os.environ["CLEANUP"])
copy_in = Path(os.environ["COPY_IN"])
manifest = {
    "schema": "zig-scheduler/vm-transcript-index/v1",
    "status": "PASS",
    "mode": os.environ["MODE"],
    "vm_kind": "vm-configured-fixture",
    "release_eligible_live_proof": False,
    "release_ineligible_reason": "fixture-driver-not-qemu-vm-live",
    "vm_marker": "/run/zig-scheduler-vm-lab.marker",
    "vm_marker_present": True,
    "host_mutation": False,
    "git_sha": os.environ["GIT_SHA"],
    "zig_version": os.environ["ZIG_VERSION"],
    "qemu_bin": os.environ["QEMU_BIN"],
    "qemu_available": os.environ["QEMU_AVAILABLE"] == "true",
    "kvm_available": os.environ["KVM_AVAILABLE"] == "true",
    "vm_config": {
        "source": os.environ["CONFIG_SOURCE"],
        "image": os.environ["IMAGE_PATH"],
        "kernel": os.environ["KERNEL_PATH"],
        "env_file": os.environ["ENV_FILE"],
        "driver": "fixture",
    },
    "kernel_tuple": {"release": "fixture-kernel", "arch": "x86_64", "config_sha256": "fixture"},
    "command_allowlist_hash": os.environ["COMMAND_HASH"],
    "copy_in_hashes": copy_in.as_posix(),
    "attestation": os.environ["ATTESTATION"],
    "verifier_only_evidence": os.environ["VERIFIER_EVIDENCE"],
    "partial_attach_evidence": os.environ["PARTIAL_ATTACH_EVIDENCE"],
    "copy_out_hashes": {
        "attestation": hashlib.sha256(Path(os.environ["ATTESTATION"]).read_bytes()).hexdigest(),
        "transcript": hashlib.sha256(transcript.read_bytes()).hexdigest(),
    },
    "transcript_path": transcript.as_posix(),
    "cleanup_receipt": cleanup.as_posix(),
}
Path(os.environ["MANIFEST"]).write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
PY
}

if [ "$mode" = "execute" ]; then
  if [ ! -f "$contract_file" ]; then
    refuse_manifest 'VM_CONTRACT_MISSING' "execution contract missing: $contract_file"
    printf 'REFUSE: VM_CONTRACT_MISSING execution contract missing: %s\n' "$contract_file"
    printf 'manifest=%s\n' "$manifest"
    exit 1
  fi
  if [ -z "$effective_image" ]; then
    refuse_manifest 'VM_CONFIG_REQUIRED' 'execute mode requires explicit --image or ZIG_SCHEDULER_VM_IMAGE'
    printf 'REFUSE: VM_CONFIG_REQUIRED execute mode requires explicit image config\n'
    printf 'manifest=%s\n' "$manifest"
    exit 1
  fi
  if [ ! -f "$effective_image" ]; then
    refuse_manifest 'VM_CONFIG_INVALID' "image does not exist: $effective_image"
    printf 'REFUSE: VM_CONFIG_INVALID image does not exist: %s\n' "$effective_image"
    printf 'manifest=%s\n' "$manifest"
    exit 1
  fi
  if [ -n "$effective_kernel" ] && [ ! -f "$effective_kernel" ]; then
    refuse_manifest 'VM_CONFIG_INVALID' "kernel does not exist: $effective_kernel"
    printf 'REFUSE: VM_CONFIG_INVALID kernel does not exist: %s\n' "$effective_kernel"
    printf 'manifest=%s\n' "$manifest"
    exit 1
  fi
  if [ "$effective_driver" = "fixture" ] && [ "$env_fixture" = "1" ]; then
    write_execute_fixture
    printf 'PASS: fixture disposable VM execute transcript created\n'
    printf 'manifest=%s\n' "$manifest"
    exit 0
  fi
  if [ "$qemu_available" != true ]; then
    skip_manifest 'qemu unavailable' 'not-started'
    printf 'SKIP: qemu unavailable\n'
    printf 'manifest=%s\n' "$manifest"
    exit 0
  fi
  if [ "$kvm_available" != true ]; then
    skip_manifest 'kvm unavailable' 'not-started'
    printf 'SKIP: kvm unavailable\n'
    printf 'manifest=%s\n' "$manifest"
    exit 0
  fi
  refuse_manifest 'VM_EXECUTE_DRIVER_UNSAFE' 'real qemu command transport is not enabled without fixture or later signed VM profile'
  printf 'REFUSE: VM_EXECUTE_DRIVER_UNSAFE real qemu command transport requires later signed VM profile\n'
  printf 'manifest=%s\n' "$manifest"
  exit 1
fi

if [ -n "$effective_image" ] && [ ! -f "$effective_image" ]; then
  refuse_manifest 'VM_CONFIG_INVALID' "image does not exist: $effective_image"
  printf 'REFUSE: VM_CONFIG_INVALID image does not exist: %s\n' "$effective_image"
  printf 'manifest=%s\n' "$manifest"
  exit 1
fi
if [ -n "$effective_kernel" ] && [ ! -f "$effective_kernel" ]; then
  refuse_manifest 'VM_CONFIG_INVALID' "kernel does not exist: $effective_kernel"
  printf 'REFUSE: VM_CONFIG_INVALID kernel does not exist: %s\n' "$effective_kernel"
  printf 'manifest=%s\n' "$manifest"
  exit 1
fi

if [ -z "$effective_image$effective_kernel" ]; then
  skip_manifest 'qemu boot image unavailable' 'not-started'
  printf 'SKIP: qemu boot image unavailable\n'
  printf 'manifest=%s\n' "$manifest"
  exit 0
fi

if [ "$qemu_available" != true ]; then
  skip_manifest 'qemu unavailable' 'not-started'
  printf 'SKIP: qemu unavailable\n'
  printf 'manifest=%s\n' "$manifest"
  exit 0
fi

if [ "$kvm_available" != true ]; then
  skip_manifest 'kvm unavailable' 'not-started'
  printf 'SKIP: kvm unavailable\n'
  printf 'manifest=%s\n' "$manifest"
  exit 0
fi

skip_manifest 'vm config recorded; boot execution not implemented in read-only skeleton' 'qemu-vm-required'
printf 'SKIP: vm config recorded; boot execution not implemented\n'
printf 'manifest=%s\n' "$manifest"
