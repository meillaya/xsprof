#!/usr/bin/env bash

microvm_copy_abs() {
  local root="$1" p="$2"
  [ -e "$p" ] || return 0
  mkdir -p "$root$(dirname "$p")"
  cp -L "$p" "$root$p"
}

microvm_copy_tool_with_deps() {
  local root="$1" tool="$2" tool_path dep guest_tool_path
  tool_path="$(command -v "$tool" 2>/dev/null || true)"
  [ -n "$tool_path" ] || return 0
  microvm_copy_abs "$root" "$tool_path"
  guest_tool_path="/usr/bin/$tool"
  mkdir -p "$root$(dirname "$guest_tool_path")"
  cp -L "$tool_path" "$root$guest_tool_path"
  { ldd "$tool_path" 2>/dev/null || true; } | awk '{for(i=1;i<=NF;i++) if($i ~ /^\//) print $i}' | while read -r dep; do microvm_copy_abs "$root" "$dep"; done
}


_microvm_rootfs_source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=qa/vm/microvm_rootfs_guest_init.sh
source "$_microvm_rootfs_source_dir/microvm_rootfs_guest_init.sh"
unset _microvm_rootfs_source_dir

microvm_rootfs_self_test() {
  local selftest_dir selftest_script
  selftest_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
  selftest_script="$selftest_dir/microvm_rootfs_selftest.sh"
  bash "$selftest_script"
}
microvm_build_rootfs() {
  local scratch="$1" root="$2" busybox_bin="$3" object_file="$4" meta_file="$5" out_dir="$6" scenario="${7:-live-backend}" app dep
  mkdir -p "$root/bin" "$root/usr/bin" "$root/usr/lib" "$root/usr/lib64" "$root/lib64" "$root/proc" "$root/sys" "$root/dev" "$root/run" "$root/tmp" "$root/sys/fs/bpf" "$root/sys/fs/cgroup"
  cp "$busybox_bin" "$root/bin/busybox"
  for app in sh mount cat echo mkdir sleep poweroff ps kill chmod ln grep sed head tail tr cut sort uniq wc sha256sum find rm true false uname date timeout test; do
    ln -s busybox "$root/bin/$app" 2>/dev/null || true
  done
  microvm_copy_abs "$root" /usr/bin/bpftool
  ldd /usr/bin/bpftool | awk '{for(i=1;i<=NF;i++) if($i ~ /^\//) print $i}' | while read -r dep; do microvm_copy_abs "$root" "$dep"; done
  case "$scenario" in
    workload-cpu-saturation|workload-cgroup-weight-quota) microvm_copy_tool_with_deps "$root" stress-ng ;;
    workload-interactive-latency) microvm_copy_tool_with_deps "$root" cyclictest; microvm_copy_tool_with_deps "$root" perf ;;
    workload-scheduler-affinity-churn) microvm_copy_tool_with_deps "$root" stress-ng; microvm_copy_tool_with_deps "$root" taskset; microvm_copy_tool_with_deps "$root" chrt ;;
  esac
  microvm_copy_abs "$root" /lib64/ld-linux-x86-64.so.2 || true
  cp "$object_file" "$root/zigsched_minimal.bpf.o"
  cp "$meta_file" "$root/zigsched_minimal.bpf.meta.json"
  microvm_write_guest_init "$root" "$scenario"
  (cd "$root" && find . | cpio -o -H newc | xz --check=crc32 -6 > "$scratch/initramfs.cpio.xz")
  cp "$scratch/initramfs.cpio.xz" "$out_dir/initramfs.cpio.xz"
}

microvm_rootfs_main() {
  case "${1:-}" in
    --self-test)
      microvm_rootfs_self_test
      ;;
    ""|-h|--help)
      echo "usage: $0 --self-test"
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      echo "usage: $0 --self-test" >&2
      return 64
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  microvm_rootfs_main "$@"
fi
