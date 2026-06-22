#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"
source qa/path_safety.sh
source qa/vm/qemu_discovery.sh
source qa/vm/qemu_cleanup.sh
source qa/vm/vm_kernel_validation.sh
source qa/vm/microvm_fixture.sh
source qa/vm/microvm_prereqs.sh
source qa/vm/microvm_rootfs.sh
source qa/vm/microvm_report.sh

out_dir=""
kernel_arg="${ZIG_SCHEDULER_VM_KERNEL:-}"
qemu_arg="${ZIG_SCHEDULER_QEMU_BIN:-}"
nix_arg="${ZIG_SCHEDULER_NIX_BIN:-}"
mem="${ZIG_SCHEDULER_MICROVM_MEM:-2048M}"
smp="${ZIG_SCHEDULER_MICROVM_SMP:-2}"
timeout_seconds="${ZIG_SCHEDULER_MICROVM_TIMEOUT:-120}"
object_file="zig-out/bpf/zigsched_minimal.bpf.o"
meta_file="zig-out/bpf/zigsched_minimal.bpf.meta.json"
scratch=""

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
usage() { printf 'usage: %s --out evidence/lab/run-all/<name> [--kernel /boot/vmlinuz-...] [--qemu /path/to/qemu-system-x86_64]\n' "$0" >&2; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --out) [ "$#" -ge 2 ] || fail '--out requires value'; out_dir="$2"; shift 2 ;;
    --kernel) [ "$#" -ge 2 ] || fail '--kernel requires value'; kernel_arg="$2"; shift 2 ;;
    --qemu) [ "$#" -ge 2 ] || fail '--qemu requires value'; qemu_arg="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

[ -n "$out_dir" ] || fail '--out is required'
case "$out_dir$kernel_arg$qemu_arg$nix_arg$mem$smp$timeout_seconds" in *$'\n'*|*$'\r'*) fail 'arguments must not contain newlines' ;; esac
case "$timeout_seconds" in ''|*[!0-9]*) fail 'timeout must be a positive integer' ;; esac
[ "$timeout_seconds" -gt 0 ] || fail 'timeout must be positive'
[ ! -e "$out_dir" ] || fail '--out must name a new output directory'
prepare_evidence_dir evidence/lab "$out_dir"
mkdir -p "$out_dir"

if microvm_fixture_enabled; then
  microvm_write_lifecycle_fixture "$out_dir"
  exit 0
fi

qemu_scan_before="$out_dir/qemu-process-scan-before.txt"
qemu_scan_after="$out_dir/qemu-process-scan-after.txt"
qemu_scan_processes "$qemu_scan_before"

qemu_bin="$(microvm_find_qemu "$qemu_arg")"
nix_bin="$(microvm_find_nix_bin "$nix_arg")"
kernel_image="$(microvm_find_kernel "$kernel_arg")"
[ -x "$qemu_bin" ] || fail "qemu is not executable: $qemu_bin"
[ -x "$nix_bin" ] || fail "nix is not executable: $nix_bin"
[ -r "$kernel_image" ] || fail "kernel image is not readable: $kernel_image"
[ -e /dev/kvm ] || fail '/dev/kvm is required for the microVM live lab'

object_sha="$(microvm_build_bpf_metadata "$out_dir" "$object_file")"
git_sha="$(git rev-parse HEAD 2>/dev/null || printf unknown)"
git_dirty=false
if [ -n "$(git status --porcelain 2>/dev/null || true)" ]; then git_dirty=true; fi
started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
busybox_bin="$(microvm_fetch_busybox "$nix_bin")"

cleanup() {
  if [ -n "$scratch" ] && [ -d "$scratch" ] && [ -f "$scratch/zig-scheduler-owner-out-dir" ] && [ -f "$scratch/zig-scheduler-owner-pid" ]; then
    if [ "$(cat "$scratch/zig-scheduler-owner-out-dir")" = "$out_dir" ] && [ "$(cat "$scratch/zig-scheduler-owner-pid")" = "$$" ]; then
      rm -rf "$scratch"
    fi
  fi
}
trap cleanup EXIT INT TERM HUP
scratch="$(mktemp -d "${TMPDIR:-/tmp}/zigsched-microvm-live.XXXXXX")"
printf '%s\n' "$out_dir" > "$scratch/zig-scheduler-owner-out-dir"
printf '%s\n' "$$" > "$scratch/zig-scheduler-owner-pid"
root="$scratch/root"
microvm_build_rootfs "$scratch" "$root" "$busybox_bin" "$object_file" "$meta_file" "$out_dir"

serial="$out_dir/serial.txt"
set +e
timeout "$timeout_seconds" "$qemu_bin" -enable-kvm -cpu host -m "$mem" -smp "$smp" \
  -name zig-scheduler-microvm-live-lab,debug-threads=on \
  -kernel "$kernel_image" -initrd "$scratch/initramfs.cpio.gz" \
  -append 'console=ttyS0 panic=-1 quiet' -nographic -no-reboot > "$serial" 2>&1
qemu_rc=$?
set -e
qemu_scan_processes "$qemu_scan_after"
if qemu_owned_leftovers "$qemu_scan_after"; then
  fail 'microVM qemu process still present after run'
fi
if [ "$qemu_rc" -ne 0 ] && [ "$qemu_rc" -ne 124 ]; then
  printf 'WARN: qemu exited rc=%s; continuing to parse serial\n' "$qemu_rc" >> "$out_dir/build-bpf.txt"
fi

microvm_parse_and_emit_report "$serial" "$out_dir" "$object_sha" "$object_file" "$meta_file" "$git_sha" "$git_dirty" "$started_at" "$kernel_image" "$qemu_bin" "$qemu_scan_before" "$qemu_scan_after" "$qemu_rc"
printf 'PASS: microVM live sched_ext lab bundle summary=%s\n' "$out_dir/summary.json"
