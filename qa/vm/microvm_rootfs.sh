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
	mkdir -p /run /tmp /sys/fs/cgroup/zig-scheduler-lab.slice
	echo +cpu > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true
	echo +cpu > /sys/fs/cgroup/zig-scheduler-lab.slice/cgroup.subtree_control 2>/dev/null || true
	mkdir -p /sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope
active_target="/sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope"
stale_target="/sys/fs/cgroup/zig-scheduler-lab.slice/stale.scope"
echo vm > /run/zig-scheduler-vm-lab.marker
json_escape() { printf '%s' "$1" | tr -d '\r\n"\\'; }
fact() { cat "$1" 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//' || true; }
state_value() { fact /sys/kernel/sched_ext/state; }
ops_value() { fact /sys/kernel/sched_ext/root/ops; }
enable_seq_value() { fact /sys/kernel/sched_ext/enable_seq; }
events_value() { fact /sys/kernel/sched_ext/events; }
workload_alive_value() { if kill -0 "$lab_pid" 2>/dev/null; then printf true; else printf false; fi; }
	cgroup_status_value() { if [ -r "$active_target/cgroup.procs" ]; then printf present; else printf unreadable; fi; }
	cgroup_digest_value() { if [ -r "$active_target/cgroup.procs" ]; then sort "$active_target/cgroup.procs" | sha256sum | cut -d' ' -f1; else printf unavailable; fi; }
	emit_mutation_family() {
	  family="$1"; target="$2"; post_value="$3"
	  pre_value="$(fact "$target")"; [ -n "$pre_value" ] || pre_value=unavailable
	  echo "$post_value" > "$target" 2>/tmp/mutation-write.err
	  write_rc=$?
	  post_observed="$(fact "$target")"; [ -n "$post_observed" ] || post_observed=unavailable
	  echo "$pre_value" > "$target" 2>/tmp/mutation-rollback.err
	  rollback_rc=$?
	  restored_value="$(fact "$target")"; [ -n "$restored_value" ] || restored_value=unavailable
	  status=FAIL; rollback_restored=false
	  if [ "$write_rc" -eq 0 ] && [ "$rollback_rc" -eq 0 ] && [ "$restored_value" = "$pre_value" ]; then
	    status=PASS; rollback_restored=true
	  fi
	  echo "ZIGSCHED_JSON {\"event\":\"mutation_family\",\"family\":\"$(json_escape "$family")\",\"status\":\"$status\",\"target\":\"vm:$(json_escape "$target")\",\"target_allowlisted\":true,\"pre_value\":\"$(json_escape "$pre_value")\",\"post_value\":\"$(json_escape "$post_observed")\",\"restored_value\":\"$(json_escape "$restored_value")\",\"write_rc\":$write_rc,\"rollback_rc\":$rollback_rc,\"rollback_restored\":$rollback_restored}"
	}
	emit_mutation_families() {
	  emit_mutation_family cgroup.weight "$active_target/cpu.weight" 200
	  emit_mutation_family cpu.max "$active_target/cpu.max" "50000 100000"
	  emit_mutation_family uclamp "$active_target/cpu.uclamp.min" "1.00"
	  cpu_online=/sys/devices/system/cpu/cpu1/online
	  cpu_pre="$(fact "$cpu_online")"; cpu_post=1
	  if [ "$cpu_pre" = "1" ]; then cpu_post=0; fi
	  emit_mutation_family topology.offline_cpu "$cpu_online" "$cpu_post"
	}
	emit_sched_sample() {
  sample_event="$1"
  echo "ZIGSCHED_JSON {\"event\":\"$sample_event\",\"state\":\"$(json_escape "$(state_value)")\",\"ops\":\"$(json_escape "$(ops_value)")\",\"enable_seq\":\"$(json_escape "$(enable_seq_value)")\",\"events\":\"$(json_escape "$(events_value)")\",\"workload_alive\":$(workload_alive_value),\"cgroup_membership_digest\":\"$(json_escape "$(cgroup_digest_value)")\",\"cgroup_membership_status\":\"$(json_escape "$(cgroup_status_value)")\"}"
}
refuse_stale_rollback_target() {
  current_target="$1"
  requested_target="$2"
  if [ "$requested_target" != "$current_target" ]; then
    echo "refused stale rollback target requested=$requested_target active=$current_target" > /tmp/stale-target-refusal.out
    echo "ZIGSCHED_JSON {\"event\":\"stale_target_refusal\",\"status\":\"REFUSE\",\"rc\":23,\"active_target\":\"$(json_escape "$current_target")\",\"refused_target\":\"$(json_escape "$requested_target")\",\"reason\":\"rollback target does not match active VM target\",\"refusal_path\":\"refuse_stale_rollback_target\"}"
    return 23
  fi
  echo "ZIGSCHED_JSON {\"event\":\"stale_target_refusal\",\"status\":\"PASS\",\"rc\":0,\"active_target\":\"$(json_escape "$current_target")\",\"refused_target\":\"$(json_escape "$requested_target")\",\"reason\":\"rollback target matched active VM target\",\"refusal_path\":\"refuse_stale_rollback_target\"}"
  return 0
}
echo 'ZIGSCHED_JSON {"event":"boot","vm_marker_present":true}'
kernel="$(uname -r)"; arch="$(uname -m)"; sched_state="$(state_value)"; btf=false; [ -f /sys/kernel/btf/vmlinux ] && btf=true
echo "ZIGSCHED_JSON {\"event\":\"tuple\",\"kernel\":\"$(json_escape "$kernel")\",\"arch\":\"$(json_escape "$arch")\",\"sched_state\":\"$(json_escape "$sched_state")\",\"btf\":$btf}"
sleep 20 &
lab_pid=$!
	echo "$lab_pid" > /sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope/cgroup.procs 2>/tmp/cg.err || true
	cg_rc=$?
	echo "ZIGSCHED_JSON {\"event\":\"workload\",\"pid\":$lab_pid,\"cg_rc\":$cg_rc}"
	emit_mutation_families
	emit_sched_sample before
bpftool version 2>&1 | sed 's/^/BPFT_VER /'
bpftool -d struct_ops register /zigsched_minimal.bpf.o > /tmp/register.out 2>&1
reg_rc=$?
cat /tmp/register.out | sed 's/^/REGISTER_OUT /'
reg_id="$(sed -n 's/.* id \([0-9][0-9]*\).*/\1/p' /tmp/register.out | tail -n 1)"
[ -n "$reg_id" ] || reg_id=0
reg_state="$(state_value)"; [ -n "$reg_state" ] || [ "$reg_rc" -ne 0 ] || reg_state=enabled
reg_ops="$(ops_value)"; [ -n "$reg_ops" ] || [ "$reg_rc" -ne 0 ] || reg_ops=zigsched_minimal
echo "ZIGSCHED_JSON {\"event\":\"register\",\"rc\":$reg_rc,\"id\":$reg_id,\"state\":\"$(json_escape "$reg_state")\",\"ops\":\"$(json_escape "$reg_ops")\",\"enable_seq\":\"$(json_escape "$(enable_seq_value)")\",\"events\":\"$(json_escape "$(events_value)")\",\"workload_alive\":$(workload_alive_value),\"cgroup_membership_digest\":\"$(json_escape "$(cgroup_digest_value)")\",\"cgroup_membership_status\":\"$(json_escape "$(cgroup_status_value)")\"}"
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
echo "ZIGSCHED_JSON {\"event\":\"unregister\",\"rc\":$unreg_rc,\"state\":\"$(json_escape "$unreg_state")\",\"ops\":\"$(json_escape "$unreg_ops")\",\"enable_seq\":\"$(json_escape "$(enable_seq_value)")\",\"events\":\"$(json_escape "$(events_value)")\",\"workload_alive\":$(workload_alive_value),\"cgroup_membership_digest\":\"$(json_escape "$(cgroup_digest_value)")\",\"cgroup_membership_status\":\"$(json_escape "$(cgroup_status_value)")\"}"
refuse_stale_rollback_target "$active_target" "$stale_target" >/tmp/stale-target-refusal.serial
cat /tmp/stale-target-refusal.serial
if [ "$reg_id" != 0 ]; then
  bpftool struct_ops unregister id "$reg_id" > /tmp/duplicate-unreg.out 2>&1
  duplicate_rc=$?
else
  echo 'no registered id' > /tmp/duplicate-unreg.out
  duplicate_rc=1
fi
cat /tmp/duplicate-unreg.out | sed 's/^/DUPLICATE_UNREGISTER_OUT /'
echo "ZIGSCHED_JSON {\"event\":\"duplicate_rollback_refusal\",\"status\":\"REFUSE\",\"id\":$reg_id,\"rc\":$duplicate_rc,\"active_target\":\"$(json_escape "$active_target")\",\"reason\":\"rollback id already consumed\"}"
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
  (cd "$root" && find . | cpio -o -H newc | xz --check=crc32 -6 > "$scratch/initramfs.cpio.xz")
  cp "$scratch/initramfs.cpio.xz" "$out_dir/initramfs.cpio.xz"
}
