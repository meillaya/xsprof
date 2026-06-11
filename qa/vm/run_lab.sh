#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"
source qa/path_safety.sh

mode=""
out_dir=""
image_arg=""
kernel_arg=""
env_file=""

env_image=""
env_kernel=""

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf 'usage: %s --mode read-only-smoke --out <evidence-dir> [--image <qcow2|raw>] [--kernel <kernel>] [--env-file <file>]\n' "$0" >&2
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

[ "$mode" = "read-only-smoke" ] || fail 'only --mode read-only-smoke is supported'
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
