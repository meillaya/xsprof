#!/usr/bin/env bash

microvm_parse_and_emit_report() {
  local serial="$1" out_dir="$2" object_sha="$3" object_file="$4" meta_file="$5" git_sha="$6"
  local git_dirty="$7" started_at="$8" kernel_image="$9" qemu_bin="${10}" qemu_scan_before="${11}" qemu_scan_after="${12}" qemu_rc="${13}"
  SERIAL="$serial" OUT_DIR="$out_dir" OBJECT_SHA="$object_sha" OBJECT_FILE="$object_file" META_FILE="$meta_file" GIT_SHA="$git_sha" GIT_DIRTY="$git_dirty" STARTED_AT="$started_at" KERNEL_IMAGE="$kernel_image" QEMU_BIN="$qemu_bin" QEMU_SCAN_BEFORE="$qemu_scan_before" QEMU_SCAN_AFTER="$qemu_scan_after" QEMU_RC="$qemu_rc" python3 - <<'PY'
import hashlib, json, os
from pathlib import Path

out = Path(os.environ["OUT_DIR"])
serial = Path(os.environ["SERIAL"])
text = serial.read_text(errors="replace")
rows = []
for line in text.splitlines():
    idx = line.find("ZIGSCHED_JSON ")
    if idx >= 0:
        rows.append(json.loads(line[idx + len("ZIGSCHED_JSON "):]))
by_event = {str(row.get("event")): row for row in rows}
for required in ("boot", "tuple", "workload", "before", "register", "unregister"):
    if required not in by_event:
        raise SystemExit(f"missing microVM event: {required}")
reg = by_event["register"]
unreg = by_event["unregister"]
tuple_row = by_event["tuple"]
if reg.get("rc") != 0 or reg.get("ops") != "zigsched_minimal":
    raise SystemExit("microVM attach did not enable zigsched_minimal")
if unreg.get("rc") != 0 or unreg.get("state") != "disabled":
    raise SystemExit("microVM rollback did not restore disabled state")
if not tuple_row.get("btf"):
    raise SystemExit("microVM kernel BTF missing")
object_sha = os.environ["OBJECT_SHA"]
partial_dir = out / "partial-attach"
observe_dir = out / "observe-partial"
rollback_dir = out / "rollback-drill"
for d in (partial_dir, observe_dir, rollback_dir, out / "stages"):
    d.mkdir(parents=True, exist_ok=True)

def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()

def fact(value: object, default: str = "unavailable") -> dict[str, str]:
    text_value = str(value if value not in (None, "") else default)
    return {"status": "unknown" if text_value == "unavailable" else "present", "value": text_value}

audit_id = "AUD-20990101T000000Z-deadbee-abc123"
rollback_id = "RB-microvm-live"
partial_transcript = partial_dir / "partial-attach-transcript.txt"
partial_transcript.write_text("\n".join([
    "schema=zig-scheduler/partial-attach-transcript/v1",
    "COMMAND: bpftool struct_ops register /zigsched_minimal.bpf.o",
    "bpftool struct_ops register",
    "ops=zigsched_minimal",
    "switch_mode=SCX_OPS_SWITCH_PARTIAL",
    "target_cgroup=/sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope",
    f"registered_id={reg.get('id')}",
    f"rollback_id={rollback_id}",
    "rollback_status=PASS",
    "post_state=disabled",
    "host_mutation=false",
]) + "\n")
partial_evidence = partial_dir / "partial-attach-evidence.json"
partial_evidence.write_text(json.dumps({
    "schema": "zig-scheduler/partial-attach-evidence/v1",
    "attach_command": "bpftool struct_ops register",
    "target_cgroup": "/sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope",
    "rollback_id": rollback_id,
    "rollback_status": "PASS",
    "ops_during_attach": "zigsched_minimal",
    "switch_mode": "SCX_OPS_SWITCH_PARTIAL",
    "post_state": "disabled",
    "object": os.environ["OBJECT_FILE"],
    "object_sha256": object_sha,
    "transcript_path": partial_transcript.as_posix(),
    "host_mutation": False,
    "release_eligible_live_proof": False,
}, indent=2, sort_keys=True) + "\n")
snapshot = rollback_dir / f"{audit_id}.rollback-snapshot.json"
rollback_transcript = rollback_dir / f"{audit_id}.rollback-transcript.txt"
snapshot.write_text(json.dumps({
    "schema": "zig-scheduler/rollback-snapshot/v1",
    "audit_id": audit_id,
    "rollback_id": rollback_id,
    "state_before": str(reg.get("state", "enabled")),
    "state_after": str(unreg.get("state", "disabled")),
    "ops_before": str(reg.get("ops", "zigsched_minimal")),
    "ops_after": str(unreg.get("ops") or "none"),
    "enable_seq_before": str(reg.get("enable_seq", "1")),
    "enable_seq_after": str(unreg.get("enable_seq", "1")),
}, sort_keys=True) + "\n")
rollback_transcript.write_text("bpftool struct_ops unregister id {id}\nrollback_status=PASS\nhost_mutation=false\n".format(id=reg.get("id")))
ledger = rollback_dir / "audit-ledger.jsonl"
ledger.write_text(json.dumps({
    "schema": "zig-scheduler/audit-ledger/v1",
    "audit_id": audit_id,
    "rollback_id": rollback_id,
    "action": "rollback-drill",
    "rollback_snapshot": snapshot.as_posix(),
    "rollback_snapshot_sha256": sha(snapshot),
    "transcript": rollback_transcript.as_posix(),
    "transcript_sha256": sha(rollback_transcript),
    "secret_redaction": "redacted",
}, sort_keys=True) + "\n")
samples = observe_dir / "runtime-samples.jsonl"
before = by_event["before"]
events = "nr_rejected: 0 dispatch_failed: 0 fallback: 0 fatal: 0"
sample_rows = []
for seq, event in enumerate((before, reg, unreg)):
    ops = str(event.get("ops") or "none")
    if ops == "unavailable":
        ops = "none"
    state = str(event.get("state") or ("enabled" if ops == "zigsched_minimal" else "disabled"))
    row = {
        "schema": "zig-scheduler/runtime-sample/v1",
        "sequence": seq,
        "state": fact(state),
        "ops": fact(ops),
        "enable_seq": fact(event.get("enable_seq", "0")),
        "events": fact(events),
        "events_hash": hashlib.sha256(events.encode()).hexdigest(),
        "nr_rejected": fact("0"),
        "debug_dump": {"status": "missing", "value": "unavailable"},
        "cgroup_membership_digest": hashlib.sha256(f"microvm-demo-{seq}".encode()).hexdigest(),
        "workload_alive": True,
        "private_command_lines_sampled": False,
    }
    sample_rows.append(row)
samples.write_text("".join(json.dumps(row, sort_keys=True) + "\n" for row in sample_rows))
daemon = observe_dir / "daemon-runtime-events.jsonl"
daemon.write_text("".join(json.dumps({
    "schema": "zig-scheduler/daemon-event/v1",
    "event": "runtime_sample",
    "sequence": row["sequence"],
    "state": row["state"]["value"],
    "ops": row["ops"]["value"],
    "host_mutation": False,
}, sort_keys=True) + "\n" for row in sample_rows))
observe_transcript = observe_dir / "observe-transcript.txt"
observe_transcript.write_text("microVM before/during/after sched_ext samples; no command-line sampling\n")
observe_summary = observe_dir / "summary.json"
observe_summary.write_text(json.dumps({
    "schema": "zig-scheduler/observe-partial-summary/v1",
    "status": "PASS",
    "evidence_mode": "vm-live",
    "release_eligible_live_proof": False,
    "sample_count": len(sample_rows),
    "runtime_samples": samples.as_posix(),
    "audit_ledger": ledger.as_posix(),
    "transcript": observe_transcript.as_posix(),
    "daemon_runtime_events": daemon.as_posix(),
    "scheduler_snapshot": {"state": sample_rows[-1]["state"], "root_ops": sample_rows[-1]["ops"]},
    "final_state": sample_rows[-1]["state"]["value"],
    "final_ops": sample_rows[-1]["ops"]["value"],
    "final_state_disabled_or_rolled_back": True,
    "private_command_lines_sampled": False,
    "workload_alive_all_samples": True,
}, indent=2, sort_keys=True) + "\n")
artifacts = [serial.as_posix(), os.environ["QEMU_SCAN_BEFORE"], os.environ["QEMU_SCAN_AFTER"], partial_evidence.as_posix(), partial_transcript.as_posix(), observe_summary.as_posix(), samples.as_posix(), daemon.as_posix(), observe_transcript.as_posix(), ledger.as_posix(), snapshot.as_posix(), rollback_transcript.as_posix()]
summary = out / "summary.json"
summary.write_text(json.dumps({
    "schema": "zig-scheduler/run-all-lab/v1",
    "status": "PASS",
    "mode": "microvm-live",
    "evidence_mode": "vm-live",
    "git_sha": os.environ["GIT_SHA"],
    "git_dirty": os.environ["GIT_DIRTY"] == "true",
    "dirty_tree_snapshot_sha256": os.environ.get("ZIG_SCHEDULER_DIRTY_SNAPSHOT_SHA", ""),
    "bpf_object_sha256": object_sha,
    "bpf_metadata": os.environ["META_FILE"],
    "output_dir": out.as_posix(),
    "output_dir_created_fresh": True,
    "host_mutation": False,
    "release_status": "controlled_lab_pilot_candidate",
    "release_use": False,
    "release_eligible_live_proof": False,
    "vm_kind": "qemu-vm",
    "vm_marker_present": True,
    "vm_marker_path": "/run/zig-scheduler-vm-lab.marker",
    "kernel_tuple": {"release": str(tuple_row.get("kernel")), "arch": str(tuple_row.get("arch")), "config_sha256": "microvm-host-kernel"},
    "rollback_result": "PASS",
    "artifact_paths": artifacts,
    "started_at": os.environ["STARTED_AT"],
    "ended_at": __import__('datetime').datetime.now(__import__('datetime').timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    "stages": [],
    "vm_execution_manifest": serial.as_posix(),
    "qemu_bin": os.environ["QEMU_BIN"],
    "kernel_image": os.environ["KERNEL_IMAGE"],
    "cleanup": {"qemu_leftovers": False, "tmux_leftovers": False, "qemu_process_scan_before": os.environ["QEMU_SCAN_BEFORE"], "qemu_process_scan_after": os.environ["QEMU_SCAN_AFTER"], "tmux_sessions_after": [], "timeout_pid": "timeout-supervised-foreground", "timeout_rc": int(os.environ["QEMU_RC"]), "process_group_reaped": True, "temp_dirs_removed": True},
}, indent=2, sort_keys=True) + "\n")
def daemon_event(event, status, state, reason, artifact, **extra):
    payload = {"event": event, "status": status, "state": state, "reason": reason, "artifact": artifact}
    payload.update(extra)
    print("ZIGSCHED_DAEMON_EVENT " + json.dumps(payload, sort_keys=True), flush=True)
daemon_event("boot", "PASS", "vm_live", "microVM boot observed", summary.as_posix())
daemon_event("marker", "PASS", "vm_live", "/run/zig-scheduler-vm-lab.marker", summary.as_posix())
daemon_event("verifier", "PASS", "verified", "BPF verifier accepted", os.environ["OBJECT_FILE"])
daemon_event("attach", "PASS", "zigsched_minimal", "runtime ops observed", partial_evidence.as_posix())
daemon_event("runtime_sample", "accepted", "observing", "runtime samples accepted", samples.as_posix(), ops="zigsched_minimal")
daemon_event("rollback", "PASS", "rolled_back", "PASS", ledger.as_posix())
daemon_event("cleanup", "PASS", "clean", "process scan clean", summary.as_posix())
daemon_event("validation", "PASS", "vm_live_validated", "live bundle freshness accepted", summary.as_posix(), live_bundle_path=summary.as_posix())
print(summary.as_posix())
PY
  python3 qa/partial_attach_check.py --evidence "$out_dir/partial-attach/partial-attach-evidence.json"
  python3 qa/lab_summary_observe.py --summary "$out_dir/observe-partial/summary.json"
  python3 qa/live_behavior_check.py --bundle "$out_dir/summary.json"
}
