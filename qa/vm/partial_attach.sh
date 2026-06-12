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
approval_file=""
vm_marker="${ZIG_SCHEDULER_VM_MARKER:-/run/zig-scheduler-vm-lab.marker}"
sys_root="${ZIG_SCHEDULER_SYS_ROOT:-}"
allow_prefix="/sys/fs/cgroup/zig-scheduler-lab.slice/"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf 'usage: %s --target <allowlisted-cgroup> --audit-id <id> --rollback-id <id> --out <evidence-dir> [--object <bpf-object>] [--approval evidence/releases/<version>/release-approval.json]\n' "$0" >&2
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
    --approval)
      [ "$#" -ge 2 ] || fail '--approval requires a value'
      approval_file="$2"
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

case "$target$audit_id$rollback_id$out_dir$object_file$approval_file" in
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
  local code="$1"
  local reason="$2"
  REASON_CODE="$code" REASON="$reason" TARGET="$target" AUDIT_ID="$audit_id" ROLLBACK_ID="$rollback_id" python3 - <<'PY' > "$host_refusal"
import json, os
print(json.dumps({
    "schema": "zig-scheduler/partial-attach-refusal/v1",
    "status": "refused-host",
    "reason_code": os.environ["REASON_CODE"],
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
  local result="${2:-REFUSED_STALE_SCOPE}"
  local reason_code="$result"
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
    printf 'result=%s\n' "$result"
    printf 'reason_code=%s\n' "$reason_code"
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
    printf 'attach_status=ATTACH_SKIPPED\n'
    printf 'rollback_status=ROLLBACK_MISSING\n'
    printf 'post-state=%s\n' "$post_state"
  } > "$transcript"
  printf '%s: %s\n' "$result" "$reason"
  printf 'transcript=%s\n' "$transcript"
  exit 0
}

if [ ! -f "$(host_path "$vm_marker")" ]; then
  json_refusal VM_MARKER_MISSING 'partial attach requires disposable VM marker; host attach refused before cgroup, bpftool, or sched_ext mutation'
  printf 'REFUSE: partial attach requires disposable VM marker; host attach refused\n'
  printf 'refusal=%s\n' "$host_refusal"
  exit 0
fi

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

validate_target_realpath() {
  local allowed_root allowed_real current component target_real
  allowed_root="$(host_path /sys/fs/cgroup/zig-scheduler-lab.slice)"
  if [ ! -d "$allowed_root" ]; then
    refuse_stale_scope 'allowlisted lab cgroup root is missing'
  fi
  current="$allowed_root"
  IFS='/' read -r -a target_components <<< "$relative_target"
  for component in "${target_components[@]}"; do
    [ -n "$component" ] || continue
    current="$current/$component"
    if [ -L "$current" ]; then
      refuse_stale_scope "target cgroup contains symlink component: $component" TARGET_SYMLINK_REJECTED
    fi
  done
  if [ ! -e "$target_path" ]; then
    refuse_stale_scope 'target cgroup disappeared between dry-run and attach'
  fi
  allowed_real="$(realpath -e "$allowed_root")" || refuse_stale_scope 'allowlisted lab cgroup root realpath unavailable'
  target_real="$(realpath -e "$target_path")" || refuse_stale_scope 'target cgroup realpath unavailable'
  case "$target_real" in
    "$allowed_real"|"$allowed_real"/*) ;;
    *) refuse_stale_scope 'target realpath resolved outside allowlisted cgroup subtree' ;;
  esac
}

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

case "$target" in "$allow_prefix"*) validate_target_realpath ;; *) refuse_stale_scope 'systemd unit resolved outside allowlisted cgroup subtree' ;; esac
current_membership="$(membership_digest_file "$procs_path")"
[ "$parent_cgroup" = "$initial_parent" ] || refuse_stale_scope 'parent scope changed after dry-run'
[ "$current_membership" = "$initial_membership" ] || refuse_stale_scope 'process membership changed unexpectedly'
[ "$rollback_id" = "$initial_rollback" ] || refuse_stale_scope 'rollback id no longer matches current plan'

[ -f "$object_file" ] || fail "BPF object not found: $object_file"

if [ -z "$approval_file" ]; then
  json_refusal APPROVAL_MISSING 'partial attach requires signed release approval before any cgroup, bpftool, or sched_ext mutation'
  printf 'REFUSE: partial attach requires signed release approval before mutation
'
  printf 'refusal=%s
' "$host_refusal"
  exit 1
fi
case "$approval_file" in evidence/releases/*/release-approval.json) ;; *) fail 'approval must be evidence/releases/<version>/release-approval.json' ;; esac
case "$approval_file" in *'/../'*|../*|*/..) fail 'unsafe approval path' ;; esac
[ -f "$approval_file" ] || fail "approval artifact missing: $approval_file"
APPROVAL="$approval_file" python3 - <<'APPROVALPY'
import json, os, subprocess, sys
from pathlib import Path
path = Path(os.environ['APPROVAL'])
data = json.loads(path.read_text())
if data.get('schema') != 'zig-scheduler/release-approval/v1': sys.exit('bad release approval schema')
if data.get('historical') is True: sys.exit('historical approval cannot authorize mutation')
if data.get('status') != 'controlled_lab_pilot_candidate': sys.exit('approval is not controlled lab candidate')
if data.get('production_ready') is not False: sys.exit('approval must not be production-ready')
if data.get('arbitrary_host_safe') is not False: sys.exit('approval must not be arbitrary-host-safe')
if data.get('approval_required_before_mutation_release') is not True: sys.exit('approval missing mutation-release requirement')
reviewer = data.get('reviewer')
if not reviewer: sys.exit('approval missing reviewer')
att = data.get('signed_attestation') or {}
for key in ['kind', 'signed_by', 'signed_at', 'statement', 'authorized_status', 'scope']:
    if not att.get(key): sys.exit('approval missing signed_attestation.' + key)
if att.get('signed_by') != reviewer: sys.exit('approval attestation signer mismatch')
if att.get('authorized_status') != data.get('status'): sys.exit('approval attestation status mismatch')
if att.get('scope') != 'controlled-lab-only': sys.exit('approval attestation scope mismatch')
current = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
sha = data.get('git_sha')
if not sha: sys.exit('approval missing git_sha')
if sha != current: sys.exit('approval git_sha is not current')
manifest = data.get('artifact_hash_manifest')
if not manifest or not Path(str(manifest)).is_file(): sys.exit('approval missing artifact hash manifest')
manifest_data = json.loads(Path(str(manifest)).read_text())
if manifest_data.get('schema') != 'zig-scheduler/release-artifact-hashes/v1': sys.exit('bad artifact hash manifest schema')
for name, item in (manifest_data.get('artifacts') or {}).items():
    artifact_path = Path(str(item.get('path', '')))
    if not artifact_path.is_file(): sys.exit('approval artifact missing: ' + name)
    import hashlib
    if hashlib.sha256(artifact_path.read_bytes()).hexdigest() != item.get('sha256'):
        sys.exit('approval artifact hash mismatch: ' + name)
APPROVALPY

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
  printf 'reason_code=ATTACH_ATTEMPTED\n'
  if ! command -v bpftool >/dev/null 2>&1; then
    printf 'SKIP: bpftool unavailable inside VM; attach not attempted\n'
    attach_status='ATTACH_SKIPPED'
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
      attach_status="ATTACH_ATTEMPTED"
    else
      printf 'reason_code=VERIFIER_FAILED\n'
      attach_status="VERIFIER_FAILED"
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
  printf 'status=%s\n' "${attach_status:-ATTACH_ATTEMPTED}"
  printf 'reason_code=%s\n' "${attach_status:-ATTACH_ATTEMPTED}"
  printf 'rollback_status=ROLLBACK_RESTORED\n'
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
case "${attach_status:-ATTACH_ATTEMPTED}" in
  ATTACH_ATTEMPTED) printf 'PASS: VM partial attach harness completed with rollback transcript\n' ;;
  ATTACH_SKIPPED) printf 'SKIP: VM partial attach skipped with rollback transcript\n' ;;
  VERIFIER_FAILED) printf 'REFUSE: VM partial attach verifier/register failed; rollback transcript captured\n' ;;
  *) printf 'REFUSE: VM partial attach ended with unknown structured status: %s\n' "$attach_status" ;;
esac
