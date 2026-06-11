#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"
source qa/path_safety.sh

mode=""
out_dir=""

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf 'usage: %s --mode read-only-smoke --out <evidence-dir>\n' "$0" >&2
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
case "$out_dir" in *$'\n'*|*$'\r'*) fail 'arguments must not contain newlines' ;; esac
prepare_evidence_dir evidence/lab "$out_dir"

manifest="$out_dir/manifest.json"
qemu_bin="$(command -v qemu-system-x86_64 || true)"
git_sha="$(git rev-parse HEAD 2>/dev/null || printf unknown)"
zig_version="$(zig version 2>/dev/null || printf unknown)"

write_skip_manifest() {
  local reason="$1"
  cat > "$manifest" <<JSON
{
  "schema": "zig-scheduler/lab-smoke/v1",
  "status": "skip",
  "reason": "$reason",
  "vm_marker": "not-started",
  "mode": "read-only-smoke",
  "git_sha": "$git_sha",
  "zig_version": "$zig_version",
  "kernel_release": "unavailable",
  "arch": "unavailable",
  "btf_status": "unavailable",
  "mutation_evidence_kind": "none",
  "host_mutation": false
}
JSON
}

if [ -z "$qemu_bin" ]; then
  write_skip_manifest 'qemu unavailable'
  printf 'SKIP: qemu unavailable\n'
  printf 'manifest=%s\n' "$manifest"
  exit 0
fi

if [ ! -e /dev/kvm ]; then
  write_skip_manifest 'kvm unavailable'
  printf 'SKIP: kvm unavailable\n'
  printf 'manifest=%s\n' "$manifest"
  exit 0
fi

cat > "$manifest" <<JSON
{
  "schema": "zig-scheduler/lab-smoke/v1",
  "status": "skip",
  "reason": "qemu present but boot image is not configured in this skeleton",
  "vm_marker": "qemu-vm-required",
  "mode": "read-only-smoke",
  "qemu_bin": "$qemu_bin",
  "git_sha": "$git_sha",
  "zig_version": "$zig_version",
  "kernel_release": "unavailable-until-vm-boot",
  "arch": "unavailable-until-vm-boot",
  "btf_status": "unavailable-until-vm-boot",
  "mutation_evidence_kind": "none",
  "host_mutation": false
}
JSON
printf 'SKIP: qemu boot image unavailable\n'
printf 'manifest=%s\n' "$manifest"
