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
accel="${ZIG_SCHEDULER_MICROVM_ACCEL:-kvm}"
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
case "$out_dir$kernel_arg$qemu_arg$nix_arg$mem$smp$accel$timeout_seconds" in *$'\n'*|*$'\r'*) fail 'arguments must not contain newlines' ;; esac
case "$timeout_seconds" in ''|*[!0-9]*) fail 'timeout must be a positive integer' ;; esac
[ "$timeout_seconds" -gt 0 ] || fail 'timeout must be positive'
case "$accel" in kvm|tcg) ;; *) fail 'ZIG_SCHEDULER_MICROVM_ACCEL must be kvm or tcg' ;; esac
[ ! -e "$out_dir" ] || fail '--out must name a new output directory'
prepare_evidence_dir evidence/lab "$out_dir"
mkdir -p "$out_dir"
case "$out_dir" in
  evidence/lab/run-all/unsafe-matrix-*) ;;
  *)
    cat > "$out_dir/.gitignore" <<'EOF'
*
!.gitignore
EOF
    ;;
esac

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
dirty_snapshot_sha=""
if [ "$git_dirty" = true ]; then
  dirty_snapshot_sha="$(python3 - <<'PY'
import hashlib
import subprocess
from pathlib import Path

h = hashlib.sha256()
for cmd in (("git", "status", "--porcelain=v1", "-z"), ("git", "diff", "--binary", "HEAD", "--")):
    result = subprocess.run(cmd, check=False, capture_output=True)
    if result.returncode != 0:
        raise SystemExit(f"snapshot command failed: {' '.join(cmd)}")
    h.update(b"\0CMD\0" + " ".join(cmd).encode() + b"\0")
    h.update(result.stdout)
other = subprocess.run(("git", "ls-files", "--others", "--exclude-standard", "-z"), check=False, capture_output=True)
if other.returncode != 0:
    raise SystemExit("git ls-files --others failed")
for raw in sorted(item for item in other.stdout.split(b"\0") if item):
    path = Path(raw.decode())
    if not path.is_file():
        continue
    h.update(b"\0UNTRACKED\0" + raw + b"\0")
    h.update(hashlib.sha256(path.read_bytes()).hexdigest().encode())
print(h.hexdigest())
PY
)"
fi
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
retry_evidence="$out_dir/qemu-retry-evidence.json"
if [ "$accel" = kvm ]; then
  accel_args=(-enable-kvm -cpu host)
else
  accel_args=(-cpu max)
fi
run_qemu_attempt() {
  local attempt_serial="$1"
  set +e
  timeout "$timeout_seconds" "$qemu_bin" "${accel_args[@]}" -m "$mem" -smp "$smp" \
    -run-with async-teardown=off \
    -name zig-scheduler-microvm-live-lab,debug-threads=on \
    -kernel "$kernel_image" -initrd "$scratch/initramfs.cpio.xz" \
    -append 'console=ttyS0 panic=-1 quiet' -nographic -no-reboot > "$attempt_serial" 2>&1
  qemu_rc=$?
  set -e
}
write_retry_evidence() {
  local status="$1" first_rc="$2" final_rc="$3" first_serial="$4" final_serial="$5"
  RETRY_STATUS="$status" FIRST_RC="$first_rc" FINAL_RC="$final_rc" FIRST_SERIAL="$first_serial" FINAL_SERIAL="$final_serial" RETRY_EVIDENCE="$retry_evidence" python3 - <<'PY'
import json
import os
from pathlib import Path

payload = {
    "schema": "zig-scheduler/qemu-retry-evidence/v1",
    "status": os.environ["RETRY_STATUS"],
    "reason": "qemu io_uring ENOMEM before boot; retry allowed only before VM marker/boot event",
    "first_rc": int(os.environ["FIRST_RC"]),
    "final_rc": int(os.environ["FINAL_RC"]),
    "first_serial": os.environ["FIRST_SERIAL"],
    "final_serial": os.environ["FINAL_SERIAL"],
    "host_mutation": False,
}
Path(os.environ["RETRY_EVIDENCE"]).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
PY
}
first_rc=""
first_serial=""
max_qemu_attempts=5
attempt=1
while :; do
  run_qemu_attempt "$serial"
  if [ "$qemu_rc" -eq 0 ]; then
    if [ -n "$first_rc" ]; then write_retry_evidence PASS "$first_rc" "$qemu_rc" "$first_serial" "$serial"; fi
    break
  fi
  if ! grep -q 'Failed to initialize io_uring: Cannot allocate memory' "$serial" || grep -q 'ZIGSCHED_JSON {"event":"boot"' "$serial" || [ "$attempt" -ge "$max_qemu_attempts" ]; then
    if [ -n "$first_rc" ]; then write_retry_evidence REFUSE "$first_rc" "$qemu_rc" "$first_serial" "$serial"; fi
    break
  fi
  if [ -z "$first_rc" ]; then
    first_rc="$qemu_rc"
    first_serial="$out_dir/serial.attempt-1.txt"
    mv "$serial" "$first_serial"
  else
    mv "$serial" "$out_dir/serial.attempt-$attempt.txt"
  fi
  attempt=$((attempt + 1))
  sleep "$attempt"
done
qemu_scan_processes "$qemu_scan_after"
if [ "$qemu_rc" -eq 124 ]; then
  microvm_emit_timeout_report "$out_dir" "$git_sha" "$git_dirty" "$started_at" "$kernel_image" "$qemu_bin" "$qemu_scan_before" "$qemu_scan_after" "$qemu_rc"
  exit 124
fi
if qemu_owned_leftovers "$qemu_scan_after"; then
  fail 'microVM qemu process still present after run'
fi
if [ "$qemu_rc" -ne 0 ] && [ "$qemu_rc" -ne 124 ]; then
  printf 'WARN: qemu exited rc=%s; continuing to parse serial\n' "$qemu_rc" >> "$out_dir/build-bpf.txt"
fi

ZIG_SCHEDULER_DIRTY_SNAPSHOT_SHA="$dirty_snapshot_sha" microvm_parse_and_emit_report "$serial" "$out_dir" "$object_sha" "$object_file" "$meta_file" "$git_sha" "$git_dirty" "$started_at" "$kernel_image" "$qemu_bin" "$qemu_scan_before" "$qemu_scan_after" "$qemu_rc"
printf 'PASS: microVM live sched_ext lab bundle summary=%s\n' "$out_dir/summary.json"
