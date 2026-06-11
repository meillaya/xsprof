#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"
source qa/path_safety.sh

out_dir=""
include_real_symlink=false
self_test_symlink=false

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --out)
      [ "$#" -ge 2 ] || fail '--out requires a value'
      out_dir="$2"
      shift 2
      ;;
    --include-real-symlink)
      include_real_symlink=true
      shift
      ;;
    --self-test-symlink)
      self_test_symlink=true
      include_real_symlink=true
      shift
      ;;
    --help|-h)
      printf 'usage: %s --out evidence/lab/cgroup-race [--include-real-symlink] [--self-test-symlink]\n' "$0"
      exit 0
      ;;
    *) fail "unknown argument: $1" ;;
  esac
done

if [ -z "$out_dir" ]; then
  if [ "$self_test_symlink" = true ]; then
    out_dir="evidence/lab/cgroup-race-self-test-symlink"
  else
    fail '--out is required'
  fi
fi
case "$out_dir" in *$'\n'*|*$'\r'*) fail 'arguments must not contain newlines' ;; esac
prepare_evidence_dir evidence/lab "$out_dir"

transcript="$out_dir/cgroup-race-transcript.txt"
summary_json="$out_dir/cgroup-race-summary.json"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/zigsched-cgroup-race.XXXXXX")"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

marker="/run/zig-scheduler-vm-lab.marker"
marker_file="$tmp/run/zig-scheduler-vm-lab.marker"
target="/sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope"
target_dir="$tmp/sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope"
mkdir -p "$(dirname "$marker_file")" "$target_dir" "$tmp/sys/kernel/sched_ext/root"
printf 'vm\n' > "$marker_file"
printf 'disabled\n' > "$tmp/sys/kernel/sched_ext/state"
printf 'none\n' > "$tmp/sys/kernel/sched_ext/root/ops"
printf '42\n' > "$tmp/sys/kernel/sched_ext/enable_seq"
printf 'none\n' > "$tmp/sys/kernel/sched_ext/events"
printf '100\n101\n' > "$target_dir/cgroup.procs"
symlink_target="/sys/fs/cgroup/zig-scheduler-lab.slice/symlink.scope"
symlink_path="$tmp/sys/fs/cgroup/zig-scheduler-lab.slice/symlink.scope"
ln -s demo.scope "$symlink_path"
initial_digest="$(sha256sum "$target_dir/cgroup.procs" | awk '{print $1}')"

: > "$transcript"
printf 'schema=zig-scheduler/cgroup-race/v1\n' >> "$transcript"
printf 'mode=partial-attach-revalidation-path\n' >> "$transcript"
printf 'vm_marker=%s\n' "$marker" >> "$transcript"
printf 'before_membership_digest=%s\n' "$initial_digest" >> "$transcript"

run_case() {
  local case_name="$1"
  local race_name="$2"
  local expected_result="${3:-REFUSED_STALE_SCOPE}"
  local case_target="${4:-$target}"
  local case_out="$out_dir/$case_name"
  rm -rf "$case_out"
  mkdir -p "$target_dir"
  printf '100\n101\n' > "$target_dir/cgroup.procs"
  set +e
  ZIG_SCHEDULER_VM_MARKER="$marker" \
  ZIG_SCHEDULER_SYS_ROOT="$tmp" \
  ZIG_SCHEDULER_INITIAL_MEMBERSHIP_DIGEST="$initial_digest" \
  ZIG_SCHEDULER_RACE="$race_name" \
    bash qa/vm/partial_attach.sh \
      --target "$case_target" \
      --audit-id AUD-20990101T000000Z-deadbee-abc123 \
      --rollback-id RB-demo \
      --out "$case_out" \
      --object zig-out/bpf/zigsched_minimal.bpf.o > "$case_out.out" 2>&1
  local rc=$?
  set -e
  cat "$case_out.out" >> "$transcript"
  if [ "$rc" -ne 0 ]; then
    printf 'case=%s result=ERROR rc=%s\n' "$case_name" "$rc" >> "$transcript"
    return 1
  fi
  grep -q "result=$expected_result" "$case_out/partial-attach-transcript.txt" || fail "$case_name did not report $expected_result"
  grep -q 'post-state=disabled/unmutated' "$case_out/partial-attach-transcript.txt" || fail "$case_name missing post-state"
  printf 'case=%s result=%s post-state=disabled/unmutated\n' "$case_name" "$expected_result" >> "$transcript"
}

run_case target_disappeared target_disappeared REFUSED_STALE_SCOPE
run_case process_membership_changed process_membership_changed REFUSED_STALE_SCOPE
run_case symlink_path_race symlink_path_race REFUSED_STALE_SCOPE
if [ "$include_real_symlink" = true ]; then
  run_case real_symlink_target "" TARGET_SYMLINK_REJECTED "$symlink_target"
fi
run_case parent_scope_changed parent_scope_changed REFUSED_STALE_SCOPE
run_case stale_rollback_id stale_rollback_id REFUSED_STALE_SCOPE
run_case systemd_unit_escape systemd_unit_escape REFUSED_STALE_SCOPE

final_digest="$(sha256sum "$target_dir/cgroup.procs" | awk '{print $1}')"
SUMMARY_JSON="$summary_json" INITIAL_DIGEST="$initial_digest" FINAL_DIGEST="$final_digest" INCLUDE_REAL_SYMLINK="$include_real_symlink" python3 - <<'PY'
import json
import os
from pathlib import Path

cases = [
    "target_disappeared",
    "process_membership_changed",
    "symlink_path_race",
    "parent_scope_changed",
    "stale_rollback_id",
    "systemd_unit_escape",
]
symlink_status = "not-run"
if os.environ["INCLUDE_REAL_SYMLINK"] == "true":
    cases.insert(3, "real_symlink_target")
    symlink_status = "TARGET_SYMLINK_REJECTED"
Path(os.environ["SUMMARY_JSON"]).write_text(json.dumps({
    "schema": "zig-scheduler/cgroup-race/v1",
    "status": "REFUSED_STALE_SCOPE",
    "symlink_status": symlink_status,
    "post_state": "disabled/unmutated",
    "host_mutation": False,
    "membership_before": os.environ["INITIAL_DIGEST"],
    "membership_after": os.environ["FINAL_DIGEST"],
    "cgroup_membership_changed": os.environ["INITIAL_DIGEST"] != os.environ["FINAL_DIGEST"],
    "cases": cases,
}, indent=2, sort_keys=True) + "\n")
PY

cat "$transcript"
printf 'summary=%s\n' "$summary_json"
printf 'PASS: cgroup race harness refused stale scopes through partial_attach path\n'
