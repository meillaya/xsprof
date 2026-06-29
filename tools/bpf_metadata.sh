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

clang_version() { first_line_or_unavailable "$cc" --version; }
bpftool_version() { first_line_or_unavailable bpftool version; }
llvm_objdump_version() { first_line_or_unavailable llvm-objdump --version; }
file_version() { first_line_or_unavailable file --version; }

command_path_or_unavailable() { command -v "$1" 2>/dev/null || printf 'unavailable'; }

canonical_command_path_or_unavailable() {
  local path
  path="$(command_path_or_unavailable "$1")"
  if [ "$path" = 'unavailable' ]; then
    printf 'unavailable'
    return
  fi
  command -v realpath >/dev/null 2>&1 && realpath "$path" 2>/dev/null || printf '%s' "$path"
}

metadata_common_env() {
  SOURCE_SHA="$(sha256_file "$source_file")" \
  HEADER_SHA="$(sha256_file "$repo_root/bpf/include/zigsched_common.h")" \
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
  HEADER_FILE="bpf/include/zigsched_common.h" \
  POLICY_NAME="zigsched_minimal" \
  POLICY_SYMBOL="zigsched_minimal_ops" \
  STRUCT_OPS_SWITCH_MODE="SCX_OPS_SWITCH_PARTIAL" \
  TARGET_DEFINE="__TARGET_ARCH_x86" \
  "$@"
}

write_skip_json() {
  local reason="$1"
  REASON="$reason" SKIP_FILE="zig-out/bpf/zigsched_minimal.bpf.skip.txt" \
    metadata_common_env python3 tools/bpf_metadata_emit.py --mode skip --reason "$reason" --output "$skip_json"
}

write_meta_json() {
  local object_input="${1:-$object_file}"
  local meta_output="${2:-$meta_file}"
  OBJECT_SHA="$(sha256_file "$object_input")" OBJECT_FILE="zig-out/bpf/zigsched_minimal.bpf.o" \
    metadata_common_env python3 tools/bpf_metadata_emit.py --mode object --output "$meta_output"
}
