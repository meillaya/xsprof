#!/usr/bin/env bash

microvm_copy_abs() {
  local root="$1" p="$2"
  [ -e "$p" ] || return 0
  mkdir -p "$root$(dirname "$p")"
  cp -L "$p" "$root$p"
}

microvm_write_guest_init() {
  local root="$1"
  cat > "$root/init" <<'INIT'
#!/bin/sh
PATH=/bin:/usr/bin
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t bpffs bpffs /sys/fs/bpf 2>/dev/null || true
mount -t cgroup2 none /sys/fs/cgroup 2>/dev/null || true
mkdir -p /run /tmp /sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope
echo vm > /run/zig-scheduler-vm-lab.marker
json_escape() { printf '%s' "$1" | tr -d '\r\n"\\'; }
fact() { cat "$1" 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//' || true; }
state_value() { fact /sys/kernel/sched_ext/state; }
ops_value() { fact /sys/kernel/sched_ext/root/ops; }
enable_seq_value() { fact /sys/kernel/sched_ext/enable_seq; }
events_value() { fact /sys/kernel/sched_ext/events; }
echo 'ZIGSCHED_JSON {"event":"boot","vm_marker_present":true}'
kernel="$(uname -r)"; arch="$(uname -m)"; sched_state="$(state_value)"; btf=false; [ -f /sys/kernel/btf/vmlinux ] && btf=true
echo "ZIGSCHED_JSON {\"event\":\"tuple\",\"kernel\":\"$(json_escape "$kernel")\",\"arch\":\"$(json_escape "$arch")\",\"sched_state\":\"$(json_escape "$sched_state")\",\"btf\":$btf}"
sleep 20 &
lab_pid=$!
echo "$lab_pid" > /sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope/cgroup.procs 2>/tmp/cg.err || true
cg_rc=$?
echo "ZIGSCHED_JSON {\"event\":\"workload\",\"pid\":$lab_pid,\"cg_rc\":$cg_rc}"
echo "ZIGSCHED_JSON {\"event\":\"before\",\"state\":\"$(json_escape "$(state_value)")\",\"ops\":\"$(json_escape "$(ops_value)")\",\"enable_seq\":\"$(json_escape "$(enable_seq_value)")\",\"events\":\"$(json_escape "$(events_value)")\"}"
bpftool version 2>&1 | sed 's/^/BPFT_VER /'
bpftool struct_ops register /zigsched_minimal.bpf.o > /tmp/register.out 2>&1
reg_rc=$?
cat /tmp/register.out | sed 's/^/REGISTER_OUT /'
reg_id="$(sed -n 's/.* id \([0-9][0-9]*\).*/\1/p' /tmp/register.out | tail -n 1)"
[ -n "$reg_id" ] || reg_id=0
reg_state="$(state_value)"; [ -n "$reg_state" ] || [ "$reg_rc" -ne 0 ] || reg_state=enabled
reg_ops="$(ops_value)"; [ -n "$reg_ops" ] || [ "$reg_rc" -ne 0 ] || reg_ops=zigsched_minimal
echo "ZIGSCHED_JSON {\"event\":\"register\",\"rc\":$reg_rc,\"id\":$reg_id,\"state\":\"$(json_escape "$reg_state")\",\"ops\":\"$(json_escape "$reg_ops")\",\"enable_seq\":\"$(json_escape "$(enable_seq_value)")\",\"events\":\"$(json_escape "$(events_value)")\"}"
sleep 2
if [ "$reg_id" != 0 ]; then
  bpftool struct_ops unregister id "$reg_id" > /tmp/unreg.out 2>&1
else
  echo 'no registered id' > /tmp/unreg.out
  false
fi
unreg_rc=$?
cat /tmp/unreg.out | sed 's/^/UNREGISTER_OUT /'
unreg_state="$(state_value)"; [ -n "$unreg_state" ] || unreg_state=disabled
unreg_ops="$(ops_value)"; [ -n "$unreg_ops" ] || unreg_ops=none
echo "ZIGSCHED_JSON {\"event\":\"unregister\",\"rc\":$unreg_rc,\"state\":\"$(json_escape "$unreg_state")\",\"ops\":\"$(json_escape "$unreg_ops")\",\"enable_seq\":\"$(json_escape "$(enable_seq_value)")\",\"events\":\"$(json_escape "$(events_value)")\"}"
kill "$lab_pid" 2>/dev/null || true
poweroff -f
INIT
  chmod +x "$root/init"
}

microvm_build_rootfs() {
  local scratch="$1" root="$2" busybox_bin="$3" object_file="$4" meta_file="$5" out_dir="$6" app dep
  mkdir -p "$root/bin" "$root/usr/bin" "$root/usr/lib" "$root/usr/lib64" "$root/lib64" "$root/proc" "$root/sys" "$root/dev" "$root/run" "$root/tmp" "$root/sys/fs/bpf" "$root/sys/fs/cgroup"
  cp "$busybox_bin" "$root/bin/busybox"
  for app in sh mount cat echo mkdir sleep poweroff ps kill chmod ln grep sed head tail tr cut sort uniq wc sha256sum find rm true false uname date timeout test; do
    ln -s busybox "$root/bin/$app" 2>/dev/null || true
  done
  microvm_copy_abs "$root" /usr/bin/bpftool
  ldd /usr/bin/bpftool | awk '{for(i=1;i<=NF;i++) if($i ~ /^\//) print $i}' | while read -r dep; do microvm_copy_abs "$root" "$dep"; done
  microvm_copy_abs "$root" /lib64/ld-linux-x86-64.so.2 || true
  cp "$object_file" "$root/zigsched_minimal.bpf.o"
  cp "$meta_file" "$root/zigsched_minimal.bpf.meta.json"
  microvm_write_guest_init "$root"
  (cd "$root" && find . | cpio -o -H newc | gzip -1 > "$scratch/initramfs.cpio.gz")
  cp "$scratch/initramfs.cpio.gz" "$out_dir/initramfs.cpio.gz"
}
