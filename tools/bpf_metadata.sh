# shellcheck shell=bash

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    printf 'unavailable'
  fi
}

first_line_or_unavailable() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'unavailable'
    return
  fi
  local output
  output="$({ "$@"; } 2>&1 || true)"
  printf '%s\n' "$output" | sed -n '1p'
}

clang_version() {
  first_line_or_unavailable "$cc" --version
}

command_path_or_unavailable() {
  command -v "$1" 2>/dev/null || printf 'unavailable'
}

canonical_command_path_or_unavailable() {
  local path
  path="$(command_path_or_unavailable "$1")"
  if [ "$path" = 'unavailable' ]; then
    printf 'unavailable'
    return
  fi
  if command -v realpath >/dev/null 2>&1; then
    realpath "$path" 2>/dev/null || printf '%s' "$path"
  else
    printf '%s' "$path"
  fi
}

bpftool_version() {
  first_line_or_unavailable bpftool version
}

llvm_objdump_version() {
  first_line_or_unavailable llvm-objdump --version
}

file_version() {
  first_line_or_unavailable file --version
}

metadata_common_env() {
  SOURCE_SHA="$(sha256_file "$source_file")" \
  CLANG_VERSION="$(clang_version)" \
  CLANG_PATH="$(canonical_command_path_or_unavailable "$cc")" \
  LLVM_OBJDUMP_VERSION="$(llvm_objdump_version)" \
  BPFT_VERSION="$(bpftool_version)" \
  FILE_VERSION="$(file_version)" \
  HOST_ARCH="$(uname -m 2>/dev/null || printf unavailable)" \
  HOST_KERNEL_RELEASE="$(uname -r 2>/dev/null || printf unavailable)" \
  ZIG_VERSION="$(zig version 2>/dev/null || printf unavailable)" \
  VM_CONTRACT="qa/vm/execution_contract.json" \
  VM_MARKER="/run/zig-scheduler-vm-lab.marker" \
  SOURCE_FILE="bpf/zigsched_minimal.bpf.c" \
  POLICY_NAME="zigsched_minimal" \
  POLICY_SYMBOL="zigsched_minimal_ops" \
  STRUCT_OPS_SWITCH_MODE="SCX_OPS_SWITCH_PARTIAL" \
  TARGET_DEFINE="__TARGET_ARCH_x86" \
  "$@"
}

write_skip_json() {
  local reason="$1"
  REASON="$reason" SKIP_FILE="zig-out/bpf/zigsched_minimal.bpf.skip.txt" \
  metadata_common_env python3 - <<'PY' > "$skip_json"
import json
import os

policy_name = os.environ["POLICY_NAME"]
policy_symbol = os.environ["POLICY_SYMBOL"]
print(json.dumps({
    "schema": "zig-scheduler/bpf-build-skip/v1",
    "status": "SKIP",
    "artifact_kind": "sched_ext_struct_ops_policy_skip",
    "policy_name": policy_name,
    "policy_symbol": policy_symbol,
    "reason": os.environ["REASON"],
    "object": None,
    "object_hash": None,
    "object_sha256": None,
    "source": os.environ["SOURCE_FILE"],
    "source_hash": "sha256:" + os.environ["SOURCE_SHA"],
    "source_sha256": os.environ["SOURCE_SHA"],
    "tuple": {
        "target_arch": "bpf",
        "target_define": os.environ["TARGET_DEFINE"],
        "host_arch": os.environ["HOST_ARCH"],
        "host_kernel_release": os.environ["HOST_KERNEL_RELEASE"],
        "vm_required_for_attach": True,
        "vm_contract": os.environ["VM_CONTRACT"],
    },
    "tool_versions": {
        "clang": os.environ["CLANG_VERSION"],
        "clang_path": os.environ["CLANG_PATH"],
        "llvm_objdump": os.environ["LLVM_OBJDUMP_VERSION"],
        "bpftool": os.environ["BPFT_VERSION"],
        "file": os.environ["FILE_VERSION"],
        "zig": os.environ["ZIG_VERSION"],
    },
    "target_arch": "bpf",
    "btf": "unavailable-build-skipped",
    "policy_mode": "minimal-partial-switch",
    "struct_ops": {
        "policy_name": policy_name,
        "object_name": policy_symbol,
        "scheduler_name": policy_name,
        "object_section": ".struct_ops",
        "program_sections": [
            "struct_ops.s/zigsched_minimal_init",
            "struct_ops/zigsched_minimal_enqueue",
            "struct_ops/zigsched_minimal_dispatch",
        ],
        "expected_callbacks": ["init", "enqueue", "dispatch"],
        "expected_switch_mode": os.environ["STRUCT_OPS_SWITCH_MODE"],
        "prohibited_switch_modes": ["SCX_OPS_SWITCH_ALL"],
    },
    "sched_ext_switch_mode": os.environ["STRUCT_OPS_SWITCH_MODE"],
    "expected_verifier_object": None,
    "vm_only": True,
    "vm_marker_required": os.environ["VM_MARKER"],
    "vm_contract": os.environ["VM_CONTRACT"],
    "host_mutation": False,
    "host_attach_allowed": False,
    "skip_text_path": os.environ["SKIP_FILE"],
    "release_eligible": False,
    "skip_is_release_eligible": False,
    "verification_claimed": False,
}, indent=2, sort_keys=True))
PY
}

write_meta_json() {
  local object_input="${1:-$object_file}"
  local meta_output="${2:-$meta_file}"
  OBJECT_SHA="$(sha256_file "$object_input")" OBJECT_FILE="zig-out/bpf/zigsched_minimal.bpf.o" \
  metadata_common_env python3 - <<'PY' > "$meta_output"
import json
import os

object_sha = os.environ["OBJECT_SHA"]
policy_name = os.environ["POLICY_NAME"]
policy_symbol = os.environ["POLICY_SYMBOL"]
print(json.dumps({
    "schema": "zig-scheduler/bpf-object-metadata/v1",
    "status": "built",
    "artifact_kind": "sched_ext_struct_ops_policy_object",
    "policy_name": policy_name,
    "policy_symbol": policy_symbol,
    "object": os.environ["OBJECT_FILE"],
    "object_hash": "sha256:" + object_sha,
    "object_sha256": object_sha,
    "source": os.environ["SOURCE_FILE"],
    "source_hash": "sha256:" + os.environ["SOURCE_SHA"],
    "source_sha256": os.environ["SOURCE_SHA"],
    "tuple": {
        "target_arch": "bpf",
        "target_define": os.environ["TARGET_DEFINE"],
        "host_arch": os.environ["HOST_ARCH"],
        "host_kernel_release": os.environ["HOST_KERNEL_RELEASE"],
        "vm_required_for_attach": True,
        "vm_contract": os.environ["VM_CONTRACT"],
    },
    "tool_versions": {
        "clang": os.environ["CLANG_VERSION"],
        "clang_path": os.environ["CLANG_PATH"],
        "llvm_objdump": os.environ["LLVM_OBJDUMP_VERSION"],
        "bpftool": os.environ["BPFT_VERSION"],
        "file": os.environ["FILE_VERSION"],
        "zig": os.environ["ZIG_VERSION"],
    },
    "clang_version": os.environ["CLANG_VERSION"],
    "target_arch": "bpf",
    "btf": "enabled",
    "policy_mode": "minimal-partial-switch",
    "struct_ops": {
        "policy_name": policy_name,
        "object_name": policy_symbol,
        "scheduler_name": policy_name,
        "object_section": ".struct_ops",
        "program_sections": [
            "struct_ops.s/zigsched_minimal_init",
            "struct_ops/zigsched_minimal_enqueue",
            "struct_ops/zigsched_minimal_dispatch",
        ],
        "expected_callbacks": ["init", "enqueue", "dispatch"],
        "expected_switch_mode": os.environ["STRUCT_OPS_SWITCH_MODE"],
        "prohibited_switch_modes": ["SCX_OPS_SWITCH_ALL"],
    },
    "sched_ext_switch_mode": os.environ["STRUCT_OPS_SWITCH_MODE"],
    "expected_verifier_object": os.environ["OBJECT_FILE"],
    "vm_only": True,
    "vm_marker_required": os.environ["VM_MARKER"],
    "vm_contract": os.environ["VM_CONTRACT"],
    "host_mutation": False,
    "host_attach_allowed": False,
    "verification_claimed": False,
}, indent=2, sort_keys=True))
PY
}
