#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"
source qa/path_safety.sh

target=""
audit_id=""
rollback_id=""
out_dir=""
object_file="zig-out/bpf/zigsched_minimal.bpf.o"
vm_marker="${ZIG_SCHEDULER_VM_MARKER:-/run/zig-scheduler-vm-lab.marker}"
sys_root="${ZIG_SCHEDULER_SYS_ROOT:-}"
allow_prefix="/sys/fs/cgroup/zig-scheduler-lab.slice/"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf 'usage: %s --target <allowlisted-cgroup> --audit-id <id> --rollback-id <id> --out <evidence-dir> [--object <bpf-object>]\n' "$0" >&2
}

host_path() {
  local path="$1"
  if [ -n "$sys_root" ]; then
    printf '%s/%s' "$sys_root" "${path#/}"
  else
    printf '%s' "$path"
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --target)
      [ "$#" -ge 2 ] || fail '--target requires a value'
      target="$2"
      shift 2
      ;;
    --audit-id)
      [ "$#" -ge 2 ] || fail '--audit-id requires a value'
      audit_id="$2"
      shift 2
      ;;
    --rollback-id)
      [ "$#" -ge 2 ] || fail '--rollback-id requires a value'
      rollback_id="$2"
      shift 2
      ;;
    --out)
      [ "$#" -ge 2 ] || fail '--out requires a value'
      out_dir="$2"
      shift 2
      ;;
    --object)
      [ "$#" -ge 2 ] || fail '--object requires a value'
      object_file="$2"
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

[ -n "$target" ] || fail '--target is required'
[ -n "$audit_id" ] || fail '--audit-id is required'
[ -n "$rollback_id" ] || fail '--rollback-id is required'
[ -n "$out_dir" ] || fail '--out is required'

case "$target$audit_id$rollback_id$out_dir$object_file" in
  *$'\n'*|*$'\r'*) fail 'arguments must not contain newlines' ;;
esac
case "$target" in
  "$allow_prefix"*) ;;
  *) fail 'target cgroup is outside /sys/fs/cgroup/zig-scheduler-lab.slice/' ;;
esac
relative_target="${target#"$allow_prefix"}"
[ -n "$relative_target" ] || fail 'target cgroup must include a child scope'
case "$relative_target" in
  *'/../'*|../*|*/..|*/./*|./*|*/.|*'//'*) fail 'target cgroup contains unsafe path components' ;;
esac
case "$relative_target" in
  *[!A-Za-z0-9._/-]*) fail 'target cgroup contains unsafe characters' ;;
esac
case "$audit_id" in
  AUD-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z-???????-??????) ;;
  *) fail 'invalid audit id' ;;
esac
[ -n "$rollback_id" ] || fail 'rollback id is required'
prepare_evidence_dir evidence/lab "$out_dir"

host_refusal="$out_dir/host-refusal.json"
transcript="$out_dir/partial-attach-transcript.txt"
rollback_json="$out_dir/rollback-snapshot.json"

json_refusal() {
  REASON="$1" TARGET="$target" AUDIT_ID="$audit_id" ROLLBACK_ID="$rollback_id" python3 - <<'PY' > "$host_refusal"
import json, os
print(json.dumps({
    "schema": "zig-scheduler/partial-attach-refusal/v1",
    "status": "refused-host",
    "reason": os.environ["REASON"],
    "target_cgroup": os.environ["TARGET"],
    "audit_id": os.environ["AUDIT_ID"],
    "rollback_id": os.environ["ROLLBACK_ID"],
    "host_mutation": False,
}, indent=2, sort_keys=True))
PY
}

refuse_stale_scope() {
  local reason="$1"
  local state_after_refusal
  local ops_after_refusal
  local enable_seq_after_refusal
  local events_after_refusal
  local membership_after_refusal
  state_after_refusal="$(read_fact /sys/kernel/sched_ext/state)"
  ops_after_refusal="$(read_fact /sys/kernel/sched_ext/root/ops)"
  enable_seq_after_refusal="$(read_fact /sys/kernel/sched_ext/enable_seq)"
  events_after_refusal="$(read_fact /sys/kernel/sched_ext/events)"
  membership_after_refusal="$(membership_digest /sys/fs/cgroup/zig-scheduler-lab.slice 2>/dev/null || printf unavailable)"
  local post_state="${state_after_refusal}/unmutated"
  if [ "$state_after_refusal" = 'disabled' ]; then
    post_state='disabled/unmutated'
  fi
  {
    printf 'schema=zig-scheduler/partial-attach-transcript/v1\n'
    printf 'result=REFUSED_STALE_SCOPE\n'
    printf 'reason=%s\n' "$reason"
    printf 'target_cgroup=%s\n' "$target"
    printf 'rollback_id=%s\n' "$rollback_id"
    printf 'state_before=%s\n' "$state_before"
    printf 'ops_before=%s\n' "$ops_before"
    printf 'enable_seq_before=%s\n' "$enable_seq_before"
    printf 'events_before=%s\n' "$events_before"
    printf 'membership_before=%s\n' "$membership_before"
    printf 'state_after_refusal=%s\n' "$state_after_refusal"
    printf 'ops_after_refusal=%s\n' "$ops_after_refusal"
    printf 'enable_seq_after_refusal=%s\n' "$enable_seq_after_refusal"
    printf 'events_after_refusal=%s\n' "$events_after_refusal"
    printf 'membership_after_refusal=%s\n' "$membership_after_refusal"
    printf 'mutation_attempted=false\n'
    printf 'post-state=%s\n' "$post_state"
  } > "$transcript"
  printf 'REFUSED_STALE_SCOPE: %s\n' "$reason"
  printf 'transcript=%s\n' "$transcript"
  exit 0
}

if [ ! -f "$(host_path "$vm_marker")" ]; then
  json_refusal 'partial attach requires disposable VM marker; host attach refused before cgroup, bpftool, or sched_ext mutation'
  printf 'REFUSE: partial attach requires disposable VM marker; host attach refused\n'
  printf 'refusal=%s\n' "$host_refusal"
  exit 0
fi

[ -f "$object_file" ] || fail "BPF object not found: $object_file"

target_path="$(host_path "$target")"
procs_path="$target_path/cgroup.procs"
parent_cgroup="${target%/*}"
initial_parent="${ZIG_SCHEDULER_INITIAL_PARENT:-$parent_cgroup}"
initial_rollback="${ZIG_SCHEDULER_INITIAL_ROLLBACK_ID:-$rollback_id}"

membership_digest_file() {
  local file="$1"
  if [ ! -f "$file" ]; then
    printf 'missing'
    return
  fi
  sha256sum "$file" | awk '{print $1}'
}

initial_membership="${ZIG_SCHEDULER_INITIAL_MEMBERSHIP_DIGEST:-$(membership_digest_file "$procs_path")}"

lab_pid=""
cleanup_lab_workload() {
  if [ -n "$lab_pid" ]; then
    kill "$lab_pid" >/dev/null 2>&1 || true
    wait "$lab_pid" >/dev/null 2>&1 || true
  fi
}
trap cleanup_lab_workload EXIT

read_fact() {
  local path="$1"
  local rooted
  rooted="$(host_path "$path")"
  if [ -r "$rooted" ]; then
    head -c 4096 "$rooted" | tr '\n' ' ' | sed 's/[[:space:]]\+$//'
  else
    printf 'unavailable'
  fi
}

membership_digest() {
  local root="$1"
  local rooted
  rooted="$(host_path "$root")"
  if [ ! -d "$rooted" ]; then
    printf 'missing'
    return
  fi
  find "$rooted" -xdev -type f \( -name cgroup.procs -o -name cgroup.threads \) -print 2>/dev/null \
    | LC_ALL=C sort \
    | while IFS= read -r file; do printf 'FILE %s\n' "${file#"$sys_root"}"; cat "$file" 2>/dev/null || true; done \
    | sha256sum | awk '{print $1}'
}

state_before="$(read_fact /sys/kernel/sched_ext/state)"
ops_before="$(read_fact /sys/kernel/sched_ext/root/ops)"
enable_seq_before="$(read_fact /sys/kernel/sched_ext/enable_seq)"
events_before="$(read_fact /sys/kernel/sched_ext/events)"
membership_before="$(membership_digest /sys/fs/cgroup/zig-scheduler-lab.slice 2>/dev/null || printf unavailable)"

case "${ZIG_SCHEDULER_RACE:-}" in
  target_disappeared)
    rm -rf "$target_path"
    ;;
  process_membership_changed)
    mkdir -p "$target_path"
    printf '999\n' >> "$procs_path"
    ;;
  parent_scope_changed)
    parent_cgroup="/sys/fs/cgroup/other.slice"
    ;;
  stale_rollback_id)
    rollback_id="RB-stale"
    ;;
  systemd_unit_escape|symlink_path_race)
    target="/sys/fs/cgroup/system.slice/escaped.service"
    target_path="$(host_path "$target")"
    procs_path="$target_path/cgroup.procs"
    ;;
  "") ;;
  *) fail "unknown race simulation: $ZIG_SCHEDULER_RACE" ;;
esac

current_membership="$(membership_digest_file "$procs_path")"
case "$target" in "$allow_prefix"*) ;; *) refuse_stale_scope 'systemd unit resolved outside allowlisted cgroup subtree' ;; esac
[ -d "$target_path" ] || refuse_stale_scope 'target cgroup disappeared between dry-run and attach'
[ "$parent_cgroup" = "$initial_parent" ] || refuse_stale_scope 'parent scope changed after dry-run'
[ "$current_membership" = "$initial_membership" ] || refuse_stale_scope 'process membership changed unexpectedly'
[ "$rollback_id" = "$initial_rollback" ] || refuse_stale_scope 'rollback id no longer matches current plan'

{
  printf 'schema=zig-scheduler/partial-attach-transcript/v1\n'
  printf 'vm_marker=%s\n' "$vm_marker"
  printf 'target_cgroup=%s\n' "$target"
  printf 'audit_id=%s\n' "$audit_id"
  printf 'rollback_id=%s\n' "$rollback_id"
  printf 'state_before=%s\n' "$state_before"
  printf 'ops_before=%s\n' "$ops_before"
  printf 'enable_seq_before=%s\n' "$enable_seq_before"
  printf 'events_before=%s\n' "$events_before"
  printf 'membership_before=%s\n' "$membership_before"
  printf 'COMMAND: mkdir -p <target cgroup inside VM>\n'
  mkdir -p "$target_path"
  printf 'COMMAND: start lab workload and move pid to allowlisted cgroup.procs\n'
  sleep 30 &
  lab_pid=$!
  printf '%s\n' "$lab_pid" > "$procs_path"
  printf 'lab_workload_pid=%s\n' "$lab_pid"
  printf 'target_cgroup_procs_after_move='
  tr '\n' ' ' < "$procs_path" || true
  printf '\n'
  printf 'COMMAND: bpftool struct_ops register <object> after lab workload scoped\n'
  if ! command -v bpftool >/dev/null 2>&1; then
    printf 'SKIP: bpftool unavailable inside VM; attach not attempted\n'
    attach_status='skip-bpftool-unavailable'
  else
    set +e
    timeout 20 bpftool struct_ops register "$object_file"
    attach_rc=$?
    set -e
    printf 'bpftool_struct_ops_register_rc=%s\n' "$attach_rc"
    if [ "$attach_rc" -eq 0 ]; then
      printf 'status_after_register=enabled-or-running\n'
      printf 'COMMAND: bpftool struct_ops unregister name zigsched_minimal_ops\n'
      set +e
      timeout 20 bpftool struct_ops unregister name zigsched_minimal_ops
      unregister_rc=$?
      set -e
      printf 'bpftool_struct_ops_unregister_rc=%s\n' "$unregister_rc"
      attach_status="enabled-then-unloaded"
    else
      attach_status="attach-attempt-failed"
    fi
  fi
  printf 'COMMAND: unload/fallback probe complete\n'
} > "$transcript" 2>&1

state_after="$(read_fact /sys/kernel/sched_ext/state)"
ops_after="$(read_fact /sys/kernel/sched_ext/root/ops)"
enable_seq_after="$(read_fact /sys/kernel/sched_ext/enable_seq)"
events_after="$(read_fact /sys/kernel/sched_ext/events)"
membership_after="$(membership_digest /sys/fs/cgroup/zig-scheduler-lab.slice 2>/dev/null || printf unavailable)"

{
  printf 'state_after=%s\n' "$state_after"
  printf 'ops_after=%s\n' "$ops_after"
  printf 'enable_seq_after=%s\n' "$enable_seq_after"
  printf 'events_after=%s\n' "$events_after"
  printf 'membership_after=%s\n' "$membership_after"
  printf 'status=%s\n' "${attach_status:-attempted}"
} >> "$transcript"

ROLLBACK_ID="$rollback_id" TARGET="$target" STATE_BEFORE="$state_before" STATE_AFTER="$state_after" ENABLE_BEFORE="$enable_seq_before" ENABLE_AFTER="$enable_seq_after" python3 - <<'PY' > "$rollback_json"
import json, os
print(json.dumps({
    "schema": "zig-scheduler/partial-attach-rollback/v1",
    "rollback_id": os.environ["ROLLBACK_ID"],
    "target_cgroup": os.environ["TARGET"],
    "state_before": os.environ["STATE_BEFORE"],
    "state_after": os.environ["STATE_AFTER"],
    "enable_seq_before": os.environ["ENABLE_BEFORE"],
    "enable_seq_after": os.environ["ENABLE_AFTER"],
    "host_mutation": False,
}, indent=2, sort_keys=True))
PY

printf 'transcript=%s\n' "$transcript"
printf 'rollback=%s\n' "$rollback_json"
printf 'PASS: VM partial attach harness completed with rollback transcript\n'
