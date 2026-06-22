#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"
source qa/path_safety.sh

object_file=""
out_dir=""
default_vm_marker="/run/zig-scheduler-vm-lab.marker"
vm_marker="${ZIG_SCHEDULER_VM_MARKER:-$default_vm_marker}"

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
parsed_json="$out_dir/verifier-parsed.json"
metadata_file="${object_file%.o}.meta.json"
skip_json="${object_file%.o}.skip.json"
source qa/vm/verifier_only_helpers.sh

object_sha_for_refusal=""
metadata_sha_for_refusal=""
if [ -f "$object_file" ]; then
  object_sha_for_refusal="$(sha256_file "$object_file")"
  metadata_sha_for_refusal="$(validate_bpf_metadata)"
fi

if [ "${ZIG_SCHEDULER_HOST_SAFE:-}" = "1" ]; then
  json_write_refusal 'host-safe run_all mode disables verifier-only BPF load before marker or bpftool handling'
  printf 'REFUSE: host-safe run_all mode disables verifier-only BPF load before mutation-capable logic\n'
  printf 'refusal=%s\n' "$refusal_json"
  exit 0
fi

if [ "$vm_marker" != "$default_vm_marker" ]; then
  json_write_refusal 'verifier-only flow ignores VM marker overrides outside explicit host-safe refusal mode'
  printf 'REFUSE: verifier-only VM marker override is not allowed outside host-safe refusal mode; no BPF verifier load attempted\n'
  printf 'refusal=%s\n' "$refusal_json"
  exit 0
fi

if [ ! -f "$vm_marker" ]; then
  json_write_refusal "verifier-only flow requires $vm_marker inside a disposable VM"
  printf 'REFUSE: verifier-only flow requires disposable VM marker; no BPF verifier load attempted\n'
  printf 'refusal=%s\n' "$refusal_json"
  exit 0
fi

if [ ! -f "$object_file" ]; then
  if [ -f "$skip_json" ]; then
    fail "BPF object build was skipped; verifier-only flow cannot claim verification: $skip_json"
  fi
  fail "BPF object not found: $object_file"
fi
[ -f "$metadata_file" ] || fail "BPF object metadata not found: $metadata_file"

state_before="$(read_fact /sys/kernel/sched_ext/state)"
enable_seq_before="$(read_fact /sys/kernel/sched_ext/enable_seq)"
cgroup_before="$(cgroup_membership_digest)"
object_sha="$(sha256_file "$object_file")"
metadata_sha="$(validate_bpf_metadata)"
[ -n "$metadata_sha" ] || fail "BPF metadata missing object_sha256: $metadata_file"
[ "$metadata_sha" = "$object_sha" ] || fail "BPF object sha does not match metadata"
status="skip"
load_rc=0
pin_path="/sys/fs/bpf/zigsched_verifier_probe_$$"

{
  printf 'schema=zig-scheduler/bpf-verifier-log/v1\n'
  printf 'vm_marker=%s\n' "$vm_marker"
  printf 'object=%s\n' "$object_file"
  printf 'object_sha256=%s\n' "$object_sha"
  printf 'bpf_metadata_path=%s\n' "$metadata_file"
  printf 'bpf_metadata_object_sha256=%s\n' "$metadata_sha"
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

set +e
python3 qa/verifier_log_check.py --input "$verifier_log" --out "$parsed_json"
parser_rc=$?
set -e
if [ "$parser_rc" -ne 0 ]; then
  printf 'verifier_parse=%s
' "$parsed_json"
  printf 'FAIL: verifier parser classified BPF verifier log as failure
' >&2
  exit "$parser_rc"
fi
parsed_status="$(python3 - "$parsed_json" <<'PY'
import json, sys
from pathlib import Path
print(json.loads(Path(sys.argv[1]).read_text()).get("status", ""))
PY
)"
parsed_reason="$(python3 - "$parsed_json" <<'PY'
import json, sys
from pathlib import Path
print(json.loads(Path(sys.argv[1]).read_text()).get("reason", ""))
PY
)"

STATUS="$status" VM_MARKER="$vm_marker" OBJECT_FILE="$object_file" OBJECT_SHA="$object_sha" METADATA_FILE="$metadata_file" METADATA_SHA="$metadata_sha" PARSED_STATUS="$parsed_status" PARSED_REASON="$parsed_reason" VERIFIER_LOG="$verifier_log" PARSED_JSON="$parsed_json" \
STATE_BEFORE="$state_before" STATE_AFTER="$state_after" ENABLE_BEFORE="$enable_seq_before" ENABLE_AFTER="$enable_seq_after" \
CGROUP_BEFORE="$cgroup_before" CGROUP_AFTER="$cgroup_after" python3 - <<'PY' > "$evidence_json"
import json, os
print(json.dumps({
    "schema": "zig-scheduler/verifier-only-evidence/v1",
    "status": os.environ["STATUS"],
    "vm_marker": os.environ["VM_MARKER"],
    "object": os.environ["OBJECT_FILE"],
    "object_sha256": os.environ["OBJECT_SHA"],
    "bpf_metadata_path": os.environ["METADATA_FILE"],
    "bpf_metadata_object_sha256": os.environ["METADATA_SHA"],
    "parsed_verifier_status": os.environ["PARSED_STATUS"],
    "parsed_verifier_reason": os.environ["PARSED_REASON"],
    "verifier_log_path": os.environ["VERIFIER_LOG"],
    "verifier_parse_path": os.environ["PARSED_JSON"],
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
printf 'verifier_parse=%s\n' "$parsed_json"
printf 'evidence=%s\n' "$evidence_json"
printf 'PASS: verifier-only VM flow preserved sched_ext state and cgroup membership\n'
