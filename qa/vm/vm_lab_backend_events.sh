#!/usr/bin/env bash

json_event_append() {
  local event="$1" status="$2" state="$3" reason="$4" artifact="$5" ops="${6:-}" live_bundle_path="${7:-}"
  EVENT_FILE="$event_file" SEQ="$seq" EVENT="$event" STATUS="$status" STATE="$state" REASON="$reason" ARTIFACT="$artifact" OPS="$ops" LIVE_BUNDLE_PATH="$live_bundle_path" RUN_ID="$run_id" ACTION_ID="$action_id" ROLLBACK_ID="$rollback_id" python3 - <<'PY'
import json, os
from pathlib import Path
row = {"schema":"zig-scheduler/daemon-event/v1","seq":int(os.environ["SEQ"]),"event":os.environ["EVENT"],"action":"vm_lab_backend","action_id":os.environ["ACTION_ID"],"run_id":os.environ["RUN_ID"],"target_id":"target-"+os.environ["RUN_ID"][:48],"rollback_id":os.environ["ROLLBACK_ID"],"state":os.environ["STATE"],"status":os.environ["STATUS"],"reason":os.environ["REASON"],"artifact":os.environ["ARTIFACT"],"host_mutation":False,"lifecycle_source":"vm_lab_backend"}
if os.environ["OPS"]: row["ops"] = os.environ["OPS"]
if os.environ["LIVE_BUNDLE_PATH"]: row["live_bundle_path"] = os.environ["LIVE_BUNDLE_PATH"]
with Path(os.environ["EVENT_FILE"]).open("a", encoding="utf-8") as fh:
    fh.write(json.dumps(row, sort_keys=True, separators=(",", ":")) + "\n")
PY
  seq=$((seq + 1))
}

write_summary() {
  local status="$1" reason="$2" vm_kind="$3" release_eligible="$4" live_summary_path="${5:-}"
  SUMMARY="$summary_file" STATUS="$status" REASON="$reason" MODE="$mode" OUT_DIR="$out_dir" RUN_ID="$run_id" EVENT_FILE="$event_file" INCIDENT_FILE="$incident_file" CLEANUP_FILE="$cleanup_file" STAGING_MANIFEST="$staging_manifest" LIVE_SUMMARY="$live_summary_path" VM_KIND="$vm_kind" RELEASE_ELIGIBLE="$release_eligible" MUTATION_REFUSAL_DIR="${mutation_refusal_dir:-}" python3 - <<'PY'
import json, os
from pathlib import Path
artifacts = [os.environ["EVENT_FILE"], os.environ["INCIDENT_FILE"], os.environ["CLEANUP_FILE"], os.environ["STAGING_MANIFEST"]]
if os.environ["LIVE_SUMMARY"]: artifacts.append(os.environ["LIVE_SUMMARY"])
refusal_dir = Path(os.environ["MUTATION_REFUSAL_DIR"]) if os.environ["MUTATION_REFUSAL_DIR"] else None
refusal_paths = []
if refusal_dir is not None and refusal_dir.is_dir():
    refusal_paths = [path.as_posix() for path in sorted(refusal_dir.glob("*.json"))]
    artifacts.extend(refusal_paths)
summary = {"schema":"zig-scheduler/vm-backend-run/v1","status":os.environ["STATUS"],"reason":os.environ["REASON"],"mode":os.environ["MODE"],"run_id":os.environ["RUN_ID"],"output_dir":os.environ["OUT_DIR"],"daemon_events":os.environ["EVENT_FILE"],"incident":os.environ["INCIDENT_FILE"],"cleanup_receipt":os.environ["CLEANUP_FILE"],"staging_manifest":os.environ["STAGING_MANIFEST"],"live_summary":os.environ["LIVE_SUMMARY"],"vm_kind":os.environ["VM_KIND"],"vm_marker_required":"/run/zig-scheduler-vm-lab.marker","host_mutation":False,"release_eligible_live_proof":os.environ["RELEASE_ELIGIBLE"] == "true","artifact_paths":artifacts}
summary["mutation_refusal_artifacts"] = refusal_paths
if os.environ["LIVE_SUMMARY"]:
    live = json.loads(Path(os.environ["LIVE_SUMMARY"]).read_text())
    for key in ("vm_marker_present", "vm_marker_path", "audit_id", "rollback_id", "mutation_evidence", "mutation_evidence_artifact"):
        if key in live:
            summary[key] = live[key]
Path(os.environ["SUMMARY"]).write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

write_cleanup() {
  local status="$1" temp_removed="$2"
  local leftovers=false
  qemu_owned_leftovers "$qemu_after" && leftovers=true
  CLEANUP_FILE="$cleanup_file" STATUS="$status" QEMU_BEFORE_FILE="$qemu_before" QEMU_AFTER_FILE="$qemu_after" TEMP_REMOVED="$temp_removed" QEMU_LEFTOVERS="$leftovers" python3 - <<'PY'
import json, os
from pathlib import Path
receipt = {"schema":"zig-scheduler/vm-cleanup-receipt/v1","status":os.environ["STATUS"],"qemu_process_scan_method":"ps -eo pid=,comm=,args= filtered to qemu-system-x86_64 argv0 basename","qemu_process_scan_before":os.environ["QEMU_BEFORE_FILE"],"qemu_process_scan_after":os.environ["QEMU_AFTER_FILE"],"qemu_leftovers":os.environ["QEMU_LEFTOVERS"] == "true","temp_dirs_removed":os.environ["TEMP_REMOVED"] == "true","process_group_reaped":True,"host_mutation":False}
Path(os.environ["CLEANUP_FILE"]).write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

write_incident() {
  local code="$1" detail="$2" hard_failure="$3"
  INCIDENT_FILE="$incident_file" CODE="$code" DETAIL="$detail" HARD_FAILURE="$hard_failure" MODE="$mode" OUT_DIR="$out_dir" python3 - <<'PY'
import json, os
from pathlib import Path
incident = {"schema":"zig-scheduler/vm-lab-incident/v1","status":"REFUSE" if os.environ["HARD_FAILURE"] == "true" else "SKIP","incident":os.environ["CODE"],"detail":os.environ["DETAIL"],"mode":os.environ["MODE"],"output_dir":os.environ["OUT_DIR"],"host_mutation":False}
Path(os.environ["INCIDENT_FILE"]).write_text(json.dumps(incident, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

normalize_runner_events() {
  RUNNER_STDOUT="$1" EVENT_FILE="$event_file" START_SEQ="$seq" RUN_ID="$run_id" ACTION_ID="$action_id" ROLLBACK_ID="$rollback_id" python3 - <<'PY'
import json, os
from pathlib import Path
seq = int(os.environ["START_SEQ"]); event_file = Path(os.environ["EVENT_FILE"]); rows = []
for line in Path(os.environ["RUNNER_STDOUT"]).read_text(errors="replace").splitlines():
    marker = "ZIGSCHED_DAEMON_EVENT "
    if marker not in line: continue
    payload = json.loads(line.split(marker, 1)[1])
    row = {"schema":"zig-scheduler/daemon-event/v1","seq":seq,"event":str(payload.get("event", "incident")),"action":"vm_lab_backend","action_id":os.environ["ACTION_ID"],"run_id":os.environ["RUN_ID"],"target_id":"target-"+os.environ["RUN_ID"][:48],"rollback_id":os.environ["ROLLBACK_ID"],"state":str(payload.get("state", "unknown")),"status":str(payload.get("status", "unknown")),"reason":str(payload.get("reason", "runner_event")),"artifact":str(payload.get("artifact", "")),"host_mutation":False,"lifecycle_source":"run_microvm_live_lab"}
    artifact = Path(row["artifact"])
    if row["event"] == "rollback" and artifact.is_file():
        ledger = json.loads(artifact.read_text().splitlines()[0])
        row["rollback_id"] = str(ledger.get("rollback_id") or row["rollback_id"])
        if ledger.get("audit_id"): row["audit_id"] = str(ledger["audit_id"])
    if row["state"] in {"stale_target_refused", "duplicate_rollback_refused"} and artifact.is_file():
        for raw_refusal in artifact.read_text().splitlines():
            refusal = json.loads(raw_refusal)
            if refusal.get("state") == row["state"]:
                row["rollback_id"] = str(refusal.get("rollback_id") or row["rollback_id"])
                if refusal.get("audit_id"): row["audit_id"] = str(refusal["audit_id"])
                break
    if payload.get("ops"): row["ops"] = str(payload["ops"])
    if payload.get("live_bundle_path"): row["live_bundle_path"] = str(payload["live_bundle_path"])
    rows.append(row); seq += 1
with event_file.open("a", encoding="utf-8") as fh:
    for row in rows: fh.write(json.dumps(row, sort_keys=True, separators=(",", ":")) + "\n")
print(seq)
PY
}

emit_refusal_lifecycle() {
  local status="$1" reason="$2" state="$3"
  json_event_append boot "$status" "$state" "$reason" "$incident_file"
  json_event_append marker "$status" not_started "$guest_marker unavailable" "$incident_file"
  json_event_append verifier "$status" not_started "verifier not run: $reason" "$incident_file"
  json_event_append attach "$status" not_started "attach not run: $reason" "$incident_file"
  json_event_append runtime_sample "$status" not_started "runtime sampling not run: $reason" "$incident_file"
  json_event_append rollback "$status" not_started "rollback not required: $reason" "$incident_file"
  json_event_append cleanup PASS clean "cleanup scan recorded" "$cleanup_file"
  json_event_append validation "$status" refused "VM backend validation refused: $reason" "$summary_file"
  json_event_append incident "$status" incident "$reason" "$incident_file"
}
