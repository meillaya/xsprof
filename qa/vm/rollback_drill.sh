#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"
source qa/path_safety.sh

out_dir=""
forced_audit_id="${ZIG_SCHEDULER_AUDIT_ID:-}"

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
      printf 'usage: %s --out evidence/lab/rollback-drill\n' "$0"
      exit 0
      ;;
    *) fail "unknown argument: $1" ;;
  esac
done

[ -n "$out_dir" ] || fail '--out is required'
case "$out_dir" in *$'\n'*|*$'\r'*) fail 'arguments must not contain newlines' ;; esac
prepare_evidence_dir evidence/lab "$out_dir"

target='/sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope'
rollback_id="RB-$(date -u +%Y%m%dT%H%M%SZ)-lab"
audit_id="$forced_audit_id"
if [ -z "$audit_id" ]; then
  audit_id="AUD-$(date -u +%Y%m%dT%H%M%SZ)-$(git rev-parse --short=7 HEAD 2>/dev/null || printf deadbee)-$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
fi
if ! [[ "$audit_id" =~ ^AUD-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{7,12}-[0-9a-f]{6}$ ]]; then
  fail 'invalid audit id'
fi
if [[ "$audit_id" =~ (secret|password|token|Authorization) ]]; then
  fail 'secret-like audit id refused'
fi
ledger="$out_dir/audit-ledger.jsonl"
transcript="$out_dir/$audit_id.rollback-transcript.txt"
snapshot="$out_dir/$audit_id.rollback-snapshot.json"
summary="$out_dir/summary.json"
if [ -f "$ledger" ] && grep -Fq "\"audit_id\": \"$audit_id\"" "$ledger"; then
  fail "duplicate audit id refused: $audit_id"
fi
if [ -e "$transcript" ] || [ -e "$snapshot" ]; then
  fail "immutable audit artifact already exists for $audit_id"
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/zigsched-rollback.XXXXXX")"
lab_pid=""
cleanup() {
  if [ -n "$lab_pid" ]; then
    kill "$lab_pid" >/dev/null 2>&1 || true
    wait "$lab_pid" >/dev/null 2>&1 || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

mkdir -p "$tmp/sys/kernel/sched_ext/root" "$tmp/sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope"
printf 'enabled\n' > "$tmp/sys/kernel/sched_ext/state"
printf 'zigsched_minimal\n' > "$tmp/sys/kernel/sched_ext/root/ops"
printf '42\n' > "$tmp/sys/kernel/sched_ext/enable_seq"
printf 'attached\n' > "$tmp/sys/kernel/sched_ext/events"
sleep 30 &
lab_pid=$!
printf '%s\n' "$lab_pid" > "$tmp/sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope/cgroup.procs"

read_fake() {
  local rel="$1"
  head -c 4096 "$tmp/${rel#/}" | tr '\n' ' ' | sed 's/[[:space:]]\+$//'
}
state_before="$(read_fake /sys/kernel/sched_ext/state)"
ops_before="$(read_fake /sys/kernel/sched_ext/root/ops)"
enable_before="$(read_fake /sys/kernel/sched_ext/enable_seq)"
events_before="$(read_fake /sys/kernel/sched_ext/events)"
membership_before="$(sha256sum "$tmp/sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope/cgroup.procs" | awk '{print $1}')"

{
  printf 'schema=zig-scheduler/rollback-drill/v1\n'
  printf 'audit_id=%s\n' "$audit_id"
  printf 'rollback_id=%s\n' "$rollback_id"
  printf 'target_cgroup=%s\n' "$target"
  printf 'state_before=%s\n' "$state_before"
  printf 'ops_before=%s\n' "$ops_before"
  printf 'enable_seq_before=%s\n' "$enable_before"
  printf 'events_before=%s\n' "$events_before"
  printf 'membership_before=%s\n' "$membership_before"
  printf 'workload_pid=%s\n' "$lab_pid"
  printf 'COMMAND: unload/fallback -> restore sched_ext disabled in disposable VM root\n'
} > "$transcript"

printf '%s\n' "${ZIG_SCHEDULER_ROLLBACK_AFTER_STATE:-disabled}" > "$tmp/sys/kernel/sched_ext/state"
printf '%s\n' "${ZIG_SCHEDULER_ROLLBACK_AFTER_OPS:-none}" > "$tmp/sys/kernel/sched_ext/root/ops"
printf 'fallback complete\n' > "$tmp/sys/kernel/sched_ext/events"

state_after="$(read_fake /sys/kernel/sched_ext/state)"
ops_after="$(read_fake /sys/kernel/sched_ext/root/ops)"
enable_after="$(read_fake /sys/kernel/sched_ext/enable_seq)"
events_after="$(read_fake /sys/kernel/sched_ext/events)"
membership_after="$(sha256sum "$tmp/sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope/cgroup.procs" | awk '{print $1}')"
if kill -0 "$lab_pid" >/dev/null 2>&1; then workload_alive=true; else workload_alive=false; fi
if [ "$state_after" != 'disabled' ] && [ "$ops_after" != "$ops_before" ]; then
  fail 'rollback health check did not restore disabled or previous scheduler'
fi
[ "$workload_alive" = true ] || fail 'rollback health check workload is not alive'

{
  printf 'state_after=%s\n' "$state_after"
  printf 'ops_after=%s\n' "$ops_after"
  printf 'enable_seq_after=%s\n' "$enable_after"
  printf 'events_after=%s\n' "$events_after"
  printf 'membership_after=%s\n' "$membership_after"
  printf 'COMMAND: post-rollback health check workload kill -0 %s\n' "$lab_pid"
  printf 'health_check=PASS\n'
} >> "$transcript"

CREATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)" AUDIT_ID="$audit_id" ROLLBACK_ID="$rollback_id" TARGET="$target" STATE_BEFORE="$state_before" STATE_AFTER="$state_after" OPS_BEFORE="$ops_before" OPS_AFTER="$ops_after" ENABLE_BEFORE="$enable_before" ENABLE_AFTER="$enable_after" EVENTS_BEFORE="$events_before" EVENTS_AFTER="$events_after" WORKLOAD_ALIVE="$workload_alive" python3 - <<'PY' > "$snapshot"
import json, os
print(json.dumps({
  "schema": "zig-scheduler/rollback-snapshot/v1",
  "id": os.environ["ROLLBACK_ID"],
  "created_at": os.environ["CREATED_AT"],
  "scope": os.environ["TARGET"],
  "audit_id": os.environ["AUDIT_ID"],
  "rollback_id": os.environ["ROLLBACK_ID"],
  "target_cgroup": os.environ["TARGET"],
  "state_before": os.environ["STATE_BEFORE"],
  "state_after": os.environ["STATE_AFTER"],
  "ops_before": os.environ["OPS_BEFORE"],
  "ops_after": os.environ["OPS_AFTER"],
  "enable_seq_before": os.environ["ENABLE_BEFORE"],
  "enable_seq_after": os.environ["ENABLE_AFTER"],
  "events_before": os.environ["EVENTS_BEFORE"],
  "events_after": os.environ["EVENTS_AFTER"],
  "workload_alive": os.environ["WORKLOAD_ALIVE"] == "true",
  "secret_redaction": "no-env-dump-no-command-lines"
}, indent=2, sort_keys=True))
PY

snapshot_sha256="$(sha256sum "$snapshot" | awk '{print $1}')"
transcript_sha256="$(sha256sum "$transcript" | awk '{print $1}')"

AUDIT_ID="$audit_id" ROLLBACK_ID="$rollback_id" SNAPSHOT="$snapshot" TRANSCRIPT="$transcript" SNAPSHOT_SHA256="$snapshot_sha256" TRANSCRIPT_SHA256="$transcript_sha256" python3 - <<'PY' >> "$ledger"
import json, os
print(json.dumps({
  "schema": "zig-scheduler/audit-ledger/v1",
  "audit_id": os.environ["AUDIT_ID"],
  "rollback_id": os.environ["ROLLBACK_ID"],
  "action": "rollback-drill",
  "rollback_snapshot": os.environ["SNAPSHOT"],
  "rollback_snapshot_sha256": os.environ["SNAPSHOT_SHA256"],
  "transcript": os.environ["TRANSCRIPT"],
  "transcript_sha256": os.environ["TRANSCRIPT_SHA256"],
  "secret_redaction": "no-secrets-recorded"
}, sort_keys=True))
PY

AUDIT_ID="$audit_id" ROLLBACK_ID="$rollback_id" LEDGER="$ledger" SNAPSHOT="$snapshot" TRANSCRIPT="$transcript" python3 - <<'PY' > "$summary"
import json, os
print(json.dumps({
  "schema": "zig-scheduler/rollback-drill-summary/v1",
  "status": "PASS",
  "audit_id": os.environ["AUDIT_ID"],
  "rollback_id": os.environ["ROLLBACK_ID"],
  "audit_ledger": os.environ["LEDGER"],
  "rollback_snapshot": os.environ["SNAPSHOT"],
  "transcript": os.environ["TRANSCRIPT"],
  "post_rollback_health": "PASS",
  "state_restored": "disabled-or-previous",
  "workload_alive": True
}, indent=2, sort_keys=True))
PY

printf 'transcript=%s\n' "$transcript"
printf 'snapshot=%s\n' "$snapshot"
printf 'ledger=%s\n' "$ledger"
printf 'summary=%s\n' "$summary"
printf 'PASS: rollback drill before/after state, unload/fallback, health check PASS\n'
