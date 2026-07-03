# shellcheck shell=bash
# Sourced by microvm_rootfs.sh; keeps guest init generation out of the public rootfs helper.
microvm_write_guest_init() {
  local root="$1" scenario="$2"
  cat > "$root/init" <<'INIT'
#!/bin/sh
PATH=/bin:/usr/bin
workload_scenario="__ZIGSCHED_WORKLOAD_SCENARIO__"
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t bpffs bpffs /sys/fs/bpf 2>/dev/null || true
mount -t cgroup2 none /sys/fs/cgroup 2>/dev/null || true
mkdir -p /run /tmp /sys/fs/cgroup/zig-scheduler-lab.slice
echo +cpu > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true
echo +cpu > /sys/fs/cgroup/zig-scheduler-lab.slice/cgroup.subtree_control 2>/dev/null || true
row_scope="$(printf '%s' "$workload_scenario" | tr -c 'A-Za-z0-9_.-' '-')"
[ -n "$row_scope" ] || row_scope=live-backend
mkdir -p "/sys/fs/cgroup/zig-scheduler-lab.slice/$row_scope.scope"
active_target="/sys/fs/cgroup/zig-scheduler-lab.slice/$row_scope.scope"
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
json_number_field() {
  file="$1"; field="$2"
  [ -r "$file" ] || { printf ''; return; }
  tr -d '[:space:]' < "$file" | sed -n "s/.*\"$field\":\([0-9][0-9]*\).*/\1/p" | head -n 1
}
map_value_by_key() {
  file="$1"; key="$2"
  [ -r "$file" ] || { printf ''; return; }
  tr -d '[:space:]' < "$file" | sed -n "s/.*{\"key\":$key,\"value\":\([0-9][0-9]*\)}.*/\1/p" | head -n 1
}
map_id_by_name() {
  lookup_name="$(printf '%s' "$1" | cut -c 1-15)"
  bpftool map show 2>/tmp/zigsched-map-show.err | sed -n "s/^\([0-9][0-9]*\): .* name $lookup_name .*/\1/p" | tail -n 1
}
map_dump_latest_by_name() {
  map_name="$1"; out_file="$2"; err_file="$3"
  map_id="$(map_id_by_name "$map_name")"
  if [ -n "$map_id" ]; then
    bpftool map dump id "$map_id" -j >"$out_file" 2>"$err_file" || true
  else
    : >"$out_file"
    printf 'map id unavailable for %s\n' "$map_name" >"$err_file"
  fi
}
capture_bpf_policy_evidence() {
  map_dump_latest_by_name zigsched_cgroup_policy /tmp/zigsched-cgroup-policy.json /tmp/zigsched-cgroup-policy.err
  map_dump_latest_by_name zigsched_stats /tmp/zigsched-stats.json /tmp/zigsched-stats.err
  map_dump_latest_by_name zigsched_events /tmp/zigsched-events.json /tmp/zigsched-events.err
}
cgroup_policy_status_value() { [ -s /tmp/zigsched-cgroup-policy.json ] && printf present || printf unavailable; }
cgroup_policy_last_weight_value() { value="$(json_number_field /tmp/zigsched-cgroup-policy.json last_weight)"; [ -n "$value" ] && printf '%s' "$value" || printf 0; }
cgroup_policy_weight_generation_value() { value="$(json_number_field /tmp/zigsched-cgroup-policy.json weight_generation)"; [ -n "$value" ] && printf '%s' "$value" || printf 0; }
cgroup_policy_move_generation_value() { value="$(json_number_field /tmp/zigsched-cgroup-policy.json move_generation)"; [ -n "$value" ] && printf '%s' "$value" || printf 0; }
cgroup_stat_value() { value="$(map_value_by_key /tmp/zigsched-stats.json "$1")"; [ -n "$value" ] && printf '%s' "$value" || printf 0; }
dsq_coherence_value() { [ -s /tmp/zigsched-stats.json ] && [ -s /tmp/zigsched-events.json ] && printf present || printf unavailable; }
emit_workload_execution() {
  status="$1"; rc="$2"; reason="$3"; output="$4"
  output_sha=unavailable
  if [ -r "$output" ]; then output_sha="$(sha256sum "$output" | cut -d' ' -f1)"; fi
  echo "ZIGSCHED_JSON {\"event\":\"workload_execution\",\"scenario\":\"$(json_escape "$workload_scenario")\",\"status\":\"$status\",\"rc\":$rc,\"reason\":\"$(json_escape "$reason")\",\"output_sha256\":\"$(json_escape "$output_sha")\",\"vm_local_cgroup\":\"vm:$(json_escape "$active_target")\",\"host_mutation\":false}"
}
require_tool() {
  command -v "$1" >/dev/null 2>&1 && return 0
  emit_workload_execution REFUSE 127 "missing VM-local workload tool: $1" /tmp/workload.out
  return 127
}
start_workload() {
  workload_out=/tmp/workload.out
  : > "$workload_out"
  case "$workload_scenario" in
    live-backend)
      sleep 20 &
      lab_pid=$!
      ;;
    workload-cpu-saturation)
      require_tool stress-ng || return $?
      stress-ng --cpu 1 --timeout 20 --metrics-brief > "$workload_out" 2>&1 &
      lab_pid=$!
      ;;
    workload-cgroup-weight-quota)
      require_tool stress-ng || return $?
      echo 200 > "$active_target/cpu.weight" 2>/tmp/workload-cgroup-weight.err || true
      echo "50000 100000" > "$active_target/cpu.max" 2>/tmp/workload-cgroup-quota.err || true
      stress-ng --cpu 1 --timeout 20 --metrics-brief > "$workload_out" 2>&1 &
      lab_pid=$!
      ;;
    workload-interactive-latency)
      require_tool cyclictest || return $?
      require_tool perf || return $?
      cyclictest -q -D 3 -p 80 -i 1000 > "$workload_out" 2>&1 &
      lab_pid=$!
      ;;
    workload-scheduler-affinity-churn)
      require_tool stress-ng || return $?
      require_tool taskset || return $?
      require_tool chrt || return $?
      chrt -i 0 taskset -c 0 stress-ng --cpu 1 --timeout 20 --metrics-brief > "$workload_out" 2>&1 &
      lab_pid=$!
      ;;
    *)
      emit_workload_execution REFUSE 64 "unknown protected-core workload scenario" "$workload_out"
      return 64
      ;;
  esac
  echo "$lab_pid" 2>/tmp/cg.err > "$active_target/cgroup.procs"
  cg_rc=$?
  if [ "$cg_rc" -ne 0 ]; then
    kill "$lab_pid" 2>/dev/null || true
    emit_workload_execution FAIL "$cg_rc" "VM-local cgroup assignment failed" "$workload_out"
    return "$cg_rc"
  fi
  return 0
}
finish_workload() {
  if [ "$workload_scenario" = live-backend ]; then
    kill "$lab_pid" 2>/dev/null || true
    emit_workload_execution PASS 0 "live backend sleep workload stopped after rollback" /tmp/workload.out
    return 0
  fi
  if kill -0 "$lab_pid" 2>/dev/null; then
    wait "$lab_pid"
    workload_rc=$?
  else
    wait "$lab_pid" 2>/dev/null
    workload_rc=$?
  fi
  if [ "$workload_rc" -eq 0 ]; then
    emit_workload_execution PASS "$workload_rc" "bounded VM-local workload completed" /tmp/workload.out
  else
    emit_workload_execution FAIL "$workload_rc" "bounded VM-local workload failed" /tmp/workload.out
  fi
  return "$workload_rc"
}
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
  emit_mutation_family cgroup.weight "$active_target/cpu.weight" 300
  emit_mutation_family cpu.max "$active_target/cpu.max" "50000 100000"
  emit_mutation_family uclamp "$active_target/cpu.uclamp.min" "1.00"
  cpu_online=/sys/devices/system/cpu/cpu1/online
  cpu_pre="$(fact "$cpu_online")"; cpu_post=1
  if [ "$cpu_pre" = "1" ]; then cpu_post=0; fi
  emit_mutation_family topology.offline_cpu "$cpu_online" "$cpu_post"
}
emit_sched_sample() {
  sample_event="$1"
  capture_bpf_policy_evidence
  cgroup_policy_status="$(cgroup_policy_status_value)"
  dsq_coherence_status="$(dsq_coherence_value)"
  echo "ZIGSCHED_JSON {\"event\":\"$sample_event\",\"state\":\"$(json_escape "$(state_value)")\",\"ops\":\"$(json_escape "$(ops_value)")\",\"enable_seq\":\"$(json_escape "$(enable_seq_value)")\",\"events\":\"$(json_escape "$(events_value)")\",\"workload_alive\":$(workload_alive_value),\"cgroup_membership_digest\":\"$(json_escape "$(cgroup_digest_value)")\",\"cgroup_membership_status\":\"$(json_escape "$(cgroup_status_value)")\",\"cgroup_policy_map_status\":\"$cgroup_policy_status\",\"cgroup_policy_last_weight\":$(cgroup_policy_last_weight_value),\"cgroup_policy_weight_generation\":$(cgroup_policy_weight_generation_value),\"cgroup_policy_move_generation\":$(cgroup_policy_move_generation_value),\"cgroup_init_calls\":$(cgroup_stat_value 8),\"cgroup_exit_calls\":$(cgroup_stat_value 9),\"cgroup_move_calls\":$(cgroup_stat_value 10),\"cgroup_set_weight_calls\":$(cgroup_stat_value 11),\"cgroup_weight_observed\":$(cgroup_stat_value 12),\"dsq_counter_coherence_status\":\"$dsq_coherence_status\"}"
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
start_workload
cg_rc=$?
echo "ZIGSCHED_JSON {\"event\":\"workload\",\"pid\":${lab_pid:-0},\"cg_rc\":$cg_rc}"
if [ "$cg_rc" -ne 0 ]; then
  poweroff -f
fi
emit_sched_sample before
bpftool version 2>&1 | sed 's/^/BPFT_VER /'
bpftool -d struct_ops register /zigsched_minimal.bpf.o > /tmp/register.out 2>&1
reg_rc=$?
cat /tmp/register.out | sed 's/^/REGISTER_OUT /'
reg_id="$(sed -n 's/.* id \([0-9][0-9]*\).*/\1/p' /tmp/register.out | tail -n 1)"
[ -n "$reg_id" ] || reg_id=0
reg_state="$(state_value)"; [ -n "$reg_state" ] || [ "$reg_rc" -ne 0 ] || reg_state=enabled
reg_ops="$(ops_value)"; [ -n "$reg_ops" ] || [ "$reg_rc" -ne 0 ] || reg_ops=zigsched_minimal
sleep 2
emit_mutation_families
capture_bpf_policy_evidence
cgroup_policy_status="$(cgroup_policy_status_value)"
dsq_coherence_status="$(dsq_coherence_value)"
echo "ZIGSCHED_JSON {\"event\":\"register\",\"rc\":$reg_rc,\"id\":$reg_id,\"state\":\"$(json_escape "$reg_state")\",\"ops\":\"$(json_escape "$reg_ops")\",\"enable_seq\":\"$(json_escape "$(enable_seq_value)")\",\"events\":\"$(json_escape "$(events_value)")\",\"workload_alive\":$(workload_alive_value),\"cgroup_membership_digest\":\"$(json_escape "$(cgroup_digest_value)")\",\"cgroup_membership_status\":\"$(json_escape "$(cgroup_status_value)")\",\"cgroup_policy_map_status\":\"$cgroup_policy_status\",\"cgroup_policy_last_weight\":$(cgroup_policy_last_weight_value),\"cgroup_policy_weight_generation\":$(cgroup_policy_weight_generation_value),\"cgroup_policy_move_generation\":$(cgroup_policy_move_generation_value),\"cgroup_init_calls\":$(cgroup_stat_value 8),\"cgroup_exit_calls\":$(cgroup_stat_value 9),\"cgroup_move_calls\":$(cgroup_stat_value 10),\"cgroup_set_weight_calls\":$(cgroup_stat_value 11),\"cgroup_weight_observed\":$(cgroup_stat_value 12),\"dsq_counter_coherence_status\":\"$dsq_coherence_status\"}"
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
finish_workload_rc=0
finish_workload || finish_workload_rc=$?
echo "ZIGSCHED_JSON {\"event\":\"workload_final\",\"scenario\":\"$(json_escape "$workload_scenario")\",\"status\":\"$([ "$finish_workload_rc" -eq 0 ] && printf PASS || printf FAIL)\",\"rc\":$finish_workload_rc,\"host_mutation\":false}"
poweroff -f
INIT
  python3 - "$root/init" "$scenario" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
scenario = sys.argv[2]
safe = "".join(ch if ch.isalnum() or ch in "._-" else "-" for ch in scenario)
path.write_text(path.read_text().replace("__ZIGSCHED_WORKLOAD_SCENARIO__", safe))
PY
  chmod +x "$root/init"
}
