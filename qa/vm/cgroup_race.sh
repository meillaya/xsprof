#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"
source qa/path_safety.sh

out_dir=""

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
    --help|-h)
      printf 'usage: %s --out evidence/lab/cgroup-race\n' "$0"
      exit 0
      ;;
    *) fail "unknown argument: $1" ;;
  esac
done

[ -n "$out_dir" ] || fail '--out is required'
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
initial_digest="$(sha256sum "$target_dir/cgroup.procs" | awk '{print $1}')"

: > "$transcript"
printf 'schema=zig-scheduler/cgroup-race/v1\n' >> "$transcript"
printf 'mode=partial-attach-revalidation-path\n' >> "$transcript"
printf 'vm_marker=%s\n' "$marker" >> "$transcript"
printf 'before_membership_digest=%s\n' "$initial_digest" >> "$transcript"

run_case() {
  local case_name="$1"
  local race_name="$2"
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
      --target "$target" \
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
  grep -q 'REFUSED_STALE_SCOPE' "$case_out/partial-attach-transcript.txt" || fail "$case_name did not refuse stale scope"
  grep -q 'post-state=disabled/unmutated' "$case_out/partial-attach-transcript.txt" || fail "$case_name missing post-state"
  printf 'case=%s result=REFUSED_STALE_SCOPE post-state=disabled/unmutated\n' "$case_name" >> "$transcript"
}

run_case target_disappeared target_disappeared
run_case process_membership_changed process_membership_changed
run_case symlink_path_race symlink_path_race
run_case parent_scope_changed parent_scope_changed
run_case stale_rollback_id stale_rollback_id
run_case systemd_unit_escape systemd_unit_escape

cat > "$summary_json" <<JSON
{
  "schema": "zig-scheduler/cgroup-race/v1",
  "status": "REFUSED_STALE_SCOPE",
  "post_state": "disabled/unmutated",
  "host_mutation": false,
  "cases": [
    "target_disappeared",
    "process_membership_changed",
    "symlink_path_race",
    "parent_scope_changed",
    "stale_rollback_id",
    "systemd_unit_escape"
  ]
}
JSON

cat "$transcript"
printf 'summary=%s\n' "$summary_json"
printf 'PASS: cgroup race harness refused stale scopes through partial_attach path\n'
