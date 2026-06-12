#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"
source qa/path_safety.sh

out_dir=""
vm_marker="${ZIG_SCHEDULER_VM_MARKER:-/run/zig-scheduler-vm-lab.marker}"
sys_root="${ZIG_SCHEDULER_SYS_ROOT:-}"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

host_path() {
  local path="$1"
  if [ -n "$sys_root" ]; then printf '%s/%s' "$sys_root" "${path#/}"; else printf '%s' "$path"; fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --out) [ "$#" -ge 2 ] || fail '--out requires a value'; out_dir="$2"; shift 2 ;;
    --help|-h) printf 'usage: %s --out evidence/lab/incident-drill\n' "$0"; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

[ -n "$out_dir" ] || fail '--out is required'
case "$out_dir" in *$'\n'*|*$'\r'*) fail 'arguments must not contain newlines' ;; esac
prepare_evidence_dir evidence/lab "$out_dir"

if [ ! -f "$(host_path "$vm_marker")" ]; then
  vm_kind='host-safe-controlled-fixture'
else
  vm_kind='vm-live'
fi

event_journal="$out_dir/incident-events.jsonl"
transcript="$out_dir/incident-transcript.txt"
summary="$out_dir/summary.json"
rollback_dir="$out_dir/rollback-drill"
aud="AUD-$(date -u +%Y%m%dT%H%M%SZ)-$(git rev-parse --short=7 HEAD 2>/dev/null || printf deadbee)-$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"

{
  printf 'schema=zig-scheduler/incident-drill/v1\n'
  printf 'vm_kind=%s\n' "$vm_kind"
  printf 'audit_id=%s\n' "$aud"
  printf 'incident=verifier_rejection\n'
  printf 'incident=scheduler_process_exit\n'
  printf 'incident=lost_runtime_stream\n'
  printf 'fallback=sysrq_s_not_fired_without_explicit_vm_opt_in\n'
  printf 'COMMAND: controlled fixture incident drill; no host scheduler mutation\n'
} > "$transcript"

emit_event() {
  EVENT="$1" STATUS="$2" REASON="$3" ARTIFACT="$4" python3 - <<'PY' >> "$event_journal"
import json, os
print(json.dumps({
  "schema": "zig-scheduler/daemon-event/v1",
  "event": os.environ["EVENT"],
  "action": "incident_drill",
  "status": os.environ["STATUS"],
  "state": "incident" if os.environ["EVENT"] == "incident" else "rolled_back",
  "reason": os.environ["REASON"],
  "artifact": os.environ["ARTIFACT"],
  "host_mutation": False,
}, sort_keys=True))
PY
}
: > "$event_journal"
emit_event incident INCIDENT verifier_rejection "$transcript"
emit_event incident INCIDENT scheduler_process_exit "$transcript"
emit_event incident INCIDENT lost_runtime_stream "$transcript"

ZIG_SCHEDULER_AUDIT_ID="$aud" bash qa/vm/rollback_drill.sh --out "$rollback_dir" >> "$transcript" 2>&1
rollback_summary="$rollback_dir/summary.json"
python3 qa/audit_ledger_check.py --ledger "$rollback_dir/audit-ledger.jsonl" >/dev/null
emit_event rollback_completed PASS rollback_drill_completed "$rollback_summary"
emit_event fallback_completed PASS fallback_completed "$rollback_summary"

SUMMARY="$summary" EVENTS="$event_journal" TRANSCRIPT="$transcript" ROLLBACK_SUMMARY="$rollback_summary" VM_KIND="$vm_kind" python3 - <<'PY'
import json, os
from pathlib import Path
rollback = json.loads(Path(os.environ["ROLLBACK_SUMMARY"]).read_text())
print(json.dumps({
  "schema": "zig-scheduler/incident-drill-summary/v1",
  "status": "PASS",
  "incident_status": "INCIDENT fallback_completed rollback_completed",
  "current_stage": "incident_drill",
  "vm_kind": os.environ["VM_KIND"],
  "evidence_mode": os.environ["VM_KIND"],
  "audit_id": rollback["audit_id"],
  "rollback_id": rollback["rollback_id"],
  "rollback_result": "PASS",
  "post_rollback_health": rollback["post_rollback_health"],
  "state_restored": rollback["state_restored"],
  "workload_alive": rollback["workload_alive"],
  "audit_ledger": rollback["audit_ledger"],
  "rollback_snapshot": rollback["rollback_snapshot"],
  "transcript": os.environ["TRANSCRIPT"],
  "event_journal": os.environ["EVENTS"],
  "incidents": ["verifier_rejection", "scheduler_process_exit", "lost_runtime_stream"],
  "fallback": "sysrq_s_not_fired_without_explicit_vm_opt_in",
  "host_mutation": False,
}, indent=2, sort_keys=True), file=open(os.environ["SUMMARY"], "w"))
PY

printf 'event_journal=%s\n' "$event_journal"
printf 'summary=%s\n' "$summary"
printf 'transcript=%s\n' "$transcript"
printf 'PASS: incident drill captured INCIDENT events and rollback/fallback evidence\n'
