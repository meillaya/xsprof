#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"
source qa/path_safety.sh

object_file=""
out_dir=""

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf 'usage: %s --object <bpf-object> --out <evidence-dir>\n' "$0" >&2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --object)
      [ "$#" -ge 2 ] || fail '--object requires a value'
      object_file="$2"
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

[ -n "$object_file" ] || fail '--object is required'
[ -n "$out_dir" ] || fail '--out is required'

case "$object_file$out_dir" in
  *$'\n'*|*$'\r'*) fail 'paths must not contain newlines' ;;
esac
prepare_evidence_dir evidence/lab "$out_dir"

refusal_json="$out_dir/host-refusal.json"
verifier_log="$out_dir/bpf-verifier.log"
evidence_json="$out_dir/verifier-evidence.json"

json_write_refusal() {
  local reason="$1"
  REASON="$reason" OBJECT_FILE="$object_file" OUT_DIR="$out_dir" python3 - <<'PY' > "$refusal_json"
import json, os
print(json.dumps({
    "schema": "zig-scheduler/verifier-only-refusal/v1",
    "status": "refused-host",
    "reason": os.environ["REASON"],
    "object": os.environ["OBJECT_FILE"],
    "out": os.environ["OUT_DIR"],
    "host_mutation": False,
}, indent=2, sort_keys=True))
PY
}

if [ ! -f /run/zig-scheduler-vm-lab.marker ]; then
  json_write_refusal 'verifier-only flow requires /run/zig-scheduler-vm-lab.marker inside a disposable VM'
  printf 'REFUSE: verifier-only flow requires disposable VM marker; no BPF verifier load attempted\n'
  printf 'refusal=%s\n' "$refusal_json"
  exit 0
fi

[ -f "$object_file" ] || fail "BPF object not found: $object_file"

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    fail 'sha256sum or shasum is required'
  fi
}

read_fact() {
  local path="$1"
  if [ -r "$path" ]; then
    head -c 4096 "$path" | tr '\n' ' ' | sed 's/[[:space:]]\+$//'
  else
    printf 'unavailable'
  fi
}

cgroup_membership_digest() {
  if [ ! -d /sys/fs/cgroup ]; then
    printf 'unavailable'
    return
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    find /sys/fs/cgroup -xdev -type f \( -name cgroup.procs -o -name cgroup.threads \) -print 2>/dev/null \
      | LC_ALL=C sort \
      | while IFS= read -r file; do printf 'FILE %s\n' "$file"; cat "$file" 2>/dev/null || true; done \
      | sha256sum | awk '{print $1}'
  else
    printf 'unavailable'
  fi
}

state_before="$(read_fact /sys/kernel/sched_ext/state)"
enable_seq_before="$(read_fact /sys/kernel/sched_ext/enable_seq)"
cgroup_before="$(cgroup_membership_digest)"
object_sha="$(sha256_file "$object_file")"
status="skip"
load_rc=0
pin_path="/sys/fs/bpf/zigsched_verifier_probe_$$"

{
  printf 'schema=zig-scheduler/bpf-verifier-log/v1\n'
  printf 'vm_marker=/run/zig-scheduler-vm-lab.marker\n'
  printf 'object=%s\n' "$object_file"
  printf 'object_sha256=%s\n' "$object_sha"
  printf 'sched_ext_state_before=%s\n' "$state_before"
  printf 'sched_ext_enable_seq_before=%s\n' "$enable_seq_before"
  if ! command -v bpftool >/dev/null 2>&1; then
    printf 'SKIP: bpftool unavailable inside VM; verifier load not attempted\n'
  elif [ ! -d /sys/fs/bpf ]; then
    printf 'SKIP: /sys/fs/bpf unavailable inside VM; verifier load not attempted\n'
  else
    printf 'COMMAND: timeout 15 bpftool -d prog load <object> <vm-pin> type sched_cls\n'
    set +e
    timeout 15 bpftool -d prog load "$object_file" "$pin_path" type sched_cls
    load_rc=$?
    set -e
    rm -f "$pin_path" 2>/dev/null || true
    status="verifier-attempted"
    printf 'bpftool_rc=%s\n' "$load_rc"
  fi
} > "$verifier_log" 2>&1

state_after="$(read_fact /sys/kernel/sched_ext/state)"
enable_seq_after="$(read_fact /sys/kernel/sched_ext/enable_seq)"
cgroup_after="$(cgroup_membership_digest)"

{
  printf 'sched_ext_state_after=%s\n' "$state_after"
  printf 'sched_ext_enable_seq_after=%s\n' "$enable_seq_after"
  printf 'cgroup_membership_before=%s\n' "$cgroup_before"
  printf 'cgroup_membership_after=%s\n' "$cgroup_after"
} >> "$verifier_log"

if [ "$state_before" != "$state_after" ] || [ "$enable_seq_before" != "$enable_seq_after" ]; then
  fail 'sched_ext state changed during verifier-only flow'
fi
if [ "$cgroup_before" != "$cgroup_after" ]; then
  fail 'cgroup membership changed during verifier-only flow'
fi

STATUS="$status" OBJECT_FILE="$object_file" OBJECT_SHA="$object_sha" VERIFIER_LOG="$verifier_log" \
STATE_BEFORE="$state_before" STATE_AFTER="$state_after" ENABLE_BEFORE="$enable_seq_before" ENABLE_AFTER="$enable_seq_after" \
CGROUP_BEFORE="$cgroup_before" CGROUP_AFTER="$cgroup_after" python3 - <<'PY' > "$evidence_json"
import json, os
print(json.dumps({
    "schema": "zig-scheduler/verifier-only-evidence/v1",
    "status": os.environ["STATUS"],
    "vm_marker": "/run/zig-scheduler-vm-lab.marker",
    "object": os.environ["OBJECT_FILE"],
    "object_sha256": os.environ["OBJECT_SHA"],
    "verifier_log_path": os.environ["VERIFIER_LOG"],
    "sched_ext_state_before": os.environ["STATE_BEFORE"],
    "sched_ext_state_after": os.environ["STATE_AFTER"],
    "enable_seq_before": os.environ["ENABLE_BEFORE"],
    "enable_seq_after": os.environ["ENABLE_AFTER"],
    "cgroup_membership_before": os.environ["CGROUP_BEFORE"],
    "cgroup_membership_after": os.environ["CGROUP_AFTER"],
    "host_mutation": False,
}, indent=2, sort_keys=True))
PY

printf 'verifier_log=%s\n' "$verifier_log"
printf 'evidence=%s\n' "$evidence_json"
printf 'PASS: verifier-only VM flow preserved sched_ext state and cgroup membership\n'
