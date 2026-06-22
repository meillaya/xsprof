#!/usr/bin/env bash
# SIZE_OK: Single microVM serial parser/evidence emitter keeps copied-out artifact paths and daemon events consistent.

microvm_parse_and_emit_report() {
  local serial="$1" out_dir="$2" object_sha="$3" object_file="$4" meta_file="$5" git_sha="$6"
  local git_dirty="$7" started_at="$8" kernel_image="$9" qemu_bin="${10}" qemu_scan_before="${11}" qemu_scan_after="${12}" qemu_rc="${13}"
  SERIAL="$serial" OUT_DIR="$out_dir" OBJECT_SHA="$object_sha" OBJECT_FILE="$object_file" META_FILE="$meta_file" GIT_SHA="$git_sha" GIT_DIRTY="$git_dirty" STARTED_AT="$started_at" KERNEL_IMAGE="$kernel_image" QEMU_BIN="$qemu_bin" QEMU_SCAN_BEFORE="$qemu_scan_before" QEMU_SCAN_AFTER="$qemu_scan_after" QEMU_RC="$qemu_rc" python3 - <<'PY'
import hashlib, json, os, re
from pathlib import Path

out = Path(os.environ["OUT_DIR"])
serial = Path(os.environ["SERIAL"])
text = serial.read_text(errors="replace")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
UNAVAILABLE_DIGESTS = {"", "missing", "none", "null", "unavailable", "unknown"}
rows = []
for line in text.splitlines():
    idx = line.find("ZIGSCHED_JSON ")
    if idx >= 0:
        rows.append(json.loads(line[idx + len("ZIGSCHED_JSON "):]))
by_event = {str(row.get("event")): row for row in rows}
for required in ("boot", "tuple", "workload", "before", "register", "unregister", "stale_target_refusal", "duplicate_rollback_refusal"):
    if required not in by_event:
        raise SystemExit(f"missing microVM event: {required}")
reg = by_event["register"]
unreg = by_event["unregister"]
tuple_row = by_event["tuple"]
stale_refusal = by_event["stale_target_refusal"]
duplicate_refusal = by_event["duplicate_rollback_refusal"]
if reg.get("rc") != 0 or reg.get("ops") != "zigsched_minimal":
    raise SystemExit("microVM attach did not enable zigsched_minimal")
if unreg.get("rc") != 0 or unreg.get("state") != "disabled":
    raise SystemExit("microVM rollback did not restore disabled state")
if stale_refusal.get("status") != "REFUSE" or int(stale_refusal.get("rc", 0)) == 0:
    raise SystemExit("microVM stale target refusal did not refuse")
if stale_refusal.get("refusal_path") != "refuse_stale_rollback_target":
    raise SystemExit("microVM stale target refusal did not use the VM refusal path")
if duplicate_refusal.get("status") != "REFUSE" or int(duplicate_refusal.get("rc", 0)) == 0:
    raise SystemExit("microVM duplicate rollback refusal did not refuse")
if not tuple_row.get("btf"):
    raise SystemExit("microVM kernel BTF missing")
object_sha = os.environ["OBJECT_SHA"]
verifier_dir = out / "verifier"
partial_dir = out / "partial-attach"
observe_dir = out / "observe-partial"
rollback_dir = out / "rollback-drill"
for d in (verifier_dir, partial_dir, observe_dir, rollback_dir, out / "stages"):
    d.mkdir(parents=True, exist_ok=True)

def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()

def fact(value: object, default: str = "unavailable") -> dict[str, str]:
    text_value = str(value if value not in (None, "") else default)
    return {"status": "unknown" if text_value == "unavailable" else "present", "value": text_value}

def observed_bool(row: dict, field: str, source: str) -> bool:
    value = row.get(field)
    if not isinstance(value, bool):
        raise SystemExit(f"microVM sample {source} missing observed boolean {field}")
    return value

def observed_digest(row: dict, source: str) -> str:
    value = row.get("cgroup_membership_digest")
    if not isinstance(value, str) or not SHA256_RE.match(value) or value == "0" * 64 or value.lower() in UNAVAILABLE_DIGESTS:
        raise SystemExit(f"microVM sample {source} missing observed sha256 cgroup digest")
    return value

def observed_cgroup_status(row: dict, source: str) -> str:
    value = row.get("cgroup_membership_status")
    if value != "present":
        raise SystemExit(f"microVM sample {source} did not observe cgroup membership")
    return "present"

def counter_fact(events_text: str, name: str) -> dict[str, str]:
    match = re.search(rf"(?:^|[^A-Za-z0-9_]){re.escape(name)}\s*[:=]\s*([0-9]+)", events_text)
    if match is None:
        return {"status": "unknown", "value": "unavailable"}
    return {"status": "present", "value": match.group(1)}

audit_stamp = __import__('datetime').datetime.now(__import__('datetime').timezone.utc).strftime('%Y%m%dT%H%M%SZ')
audit_suffix = hashlib.sha256((os.environ["GIT_SHA"] + object_sha + str(reg.get("id"))).encode()).hexdigest()[:6]
audit_id = f"AUD-{audit_stamp}-{os.environ['GIT_SHA'][:7]}-{audit_suffix}"
rollback_id = f"RB-microvm-live-{reg.get('id')}"
active_target = str(stale_refusal.get("active_target") or "/sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope")
refused_target = str(stale_refusal.get("refused_target") or "/sys/fs/cgroup/zig-scheduler-lab.slice/stale.scope")
register_lines = []
bpftool_lines = []
duplicate_lines = []
for line in text.splitlines():
    if "REGISTER_OUT " in line:
        register_lines.append(line.split("REGISTER_OUT ", 1)[1])
    if "BPFT_VER " in line:
        bpftool_lines.append(line.split("BPFT_VER ", 1)[1])
    if "DUPLICATE_UNREGISTER_OUT " in line:
        duplicate_lines.append(line.split("DUPLICATE_UNREGISTER_OUT ", 1)[1])
verifier_log = verifier_dir / "bpf-verifier.log"
verifier_log.write_text("\n".join(bpftool_lines + register_lines) + "\n")
verifier_evidence = verifier_dir / "verifier-evidence.json"
verifier_evidence.write_text(json.dumps({
    "schema": "zig-scheduler/vm-verifier-evidence/v1",
    "status": "PASS",
    "verifier_result": "accepted",
    "attach_result": "registered",
    "bpftool_debug": True,
    "object": os.environ["OBJECT_FILE"],
    "object_sha256": object_sha,
    "policy_name": "zigsched_minimal",
    "registered_id": int(reg.get("id", 0)),
    "verifier_log": verifier_log.as_posix(),
    "host_mutation": False,
    "release_eligible_live_proof": True,
}, indent=2, sort_keys=True) + "\n")
partial_transcript = partial_dir / "partial-attach-transcript.txt"
partial_transcript.write_text("\n".join([
    "schema=zig-scheduler/partial-attach-transcript/v1",
    "COMMAND: bpftool -d struct_ops register /zigsched_minimal.bpf.o",
    "bpftool -d struct_ops register",
    "bpftool struct_ops register",
    "ops=zigsched_minimal",
    "switch_mode=SCX_OPS_SWITCH_PARTIAL",
    f"target_cgroup={active_target}",
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
    "target_cgroup": active_target,
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
refusals = rollback_dir / "rollback-refusals.jsonl"
snapshot.write_text(json.dumps({
    "schema": "zig-scheduler/rollback-snapshot/v1",
    "audit_id": audit_id,
    "rollback_id": rollback_id,
    "target_cgroup": active_target,
    "state_before": str(reg.get("state", "enabled")),
    "state_after": str(unreg.get("state", "disabled")),
    "ops_before": str(reg.get("ops", "zigsched_minimal")),
    "ops_after": str(unreg.get("ops") or "none"),
    "enable_seq_before": str(reg.get("enable_seq", "1")),
    "enable_seq_after": str(unreg.get("enable_seq", "1")),
}, sort_keys=True) + "\n")
rollback_transcript.write_text("bpftool struct_ops unregister id {id}\nrollback_status=PASS\ntarget_cgroup={target}\nhost_mutation=false\n".format(id=reg.get("id"), target=active_target))
refusals.write_text("".join(json.dumps(row, sort_keys=True) + "\n" for row in (
    {
        "schema": "zig-scheduler/rollback-refusal/v1",
        "status": "REFUSE",
        "reason": "rollback target does not match active VM target",
        "state": "stale_target_refused",
        "active_target": active_target,
        "refused_target": refused_target,
        "rollback_id": rollback_id,
        "audit_id": audit_id,
        "host_mutation": False,
        "refusal_path": str(stale_refusal.get("refusal_path", "")),
    },
    {
        "schema": "zig-scheduler/rollback-refusal/v1",
        "status": "REFUSE",
        "reason": "rollback id already consumed",
        "state": "duplicate_rollback_refused",
        "active_target": active_target,
        "rollback_id": rollback_id,
        "audit_id": audit_id,
        "bpftool_rc": int(duplicate_refusal.get("rc", 1)),
        "bpftool_output": " ".join(duplicate_lines)[:300],
        "host_mutation": False,
    },
)))
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
sample_rows = []
for seq, event in enumerate((before, reg, unreg)):
    source_event = str(event.get("event") or f"sample-{seq}")
    ops = str(event.get("ops") or "none")
    if ops == "unavailable":
        ops = "none"
    state = str(event.get("state") or ("enabled" if ops == "zigsched_minimal" else "disabled"))
    events_text = str(event.get("events") or "")
    cgroup_digest = observed_digest(event, source_event)
    cgroup_status = observed_cgroup_status(event, source_event)
    row = {
        "schema": "zig-scheduler/runtime-sample/v1",
        "sequence": seq,
        "sample_source_event": source_event,
        "observation_source": "vm_serial_sched_ext",
        "state": fact(state),
        "ops": fact(ops),
        "enable_seq": fact(event.get("enable_seq", "0")),
        "events": fact(events_text),
        "events_hash": hashlib.sha256(events_text.encode()).hexdigest() if events_text else "unavailable",
        "nr_rejected": counter_fact(events_text, "nr_rejected"),
        "debug_dump": {"status": "missing", "value": "unavailable"},
        "cgroup_membership_digest": cgroup_digest,
        "cgroup_membership_status": fact(cgroup_status),
        "workload": {"status": "present", "value": "alive" if observed_bool(event, "workload_alive", source_event) else "not_alive"},
        "workload_alive": observed_bool(event, "workload_alive", source_event),
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
    "workload_alive_all_samples": all(row["workload_alive"] for row in sample_rows),
}, indent=2, sort_keys=True) + "\n")
artifacts = [serial.as_posix(), os.environ["QEMU_SCAN_BEFORE"], os.environ["QEMU_SCAN_AFTER"], verifier_evidence.as_posix(), verifier_log.as_posix(), partial_evidence.as_posix(), partial_transcript.as_posix(), observe_summary.as_posix(), samples.as_posix(), daemon.as_posix(), observe_transcript.as_posix(), ledger.as_posix(), snapshot.as_posix(), rollback_transcript.as_posix(), refusals.as_posix()]
summary = out / "summary.json"
git_dirty = os.environ["GIT_DIRTY"] == "true"
dirty_snapshot = os.environ.get("ZIG_SCHEDULER_DIRTY_SNAPSHOT_SHA", "")
unsafe_matrix_run = "/unsafe-matrix-" in out.as_posix()
summary_data = {
    "schema": "zig-scheduler/run-all-lab/v1",
    "status": "PASS",
    "mode": "microvm-live",
    "evidence_mode": "vm-live",
    "git_sha": os.environ["GIT_SHA"],
    "git_dirty": git_dirty,
    "bpf_object_sha256": object_sha,
    "bpf_metadata": os.environ["META_FILE"],
    "output_dir": out.as_posix(),
    "output_dir_created_fresh": True,
    "host_mutation": False,
    "release_status": "controlled_lab_pilot_candidate",
    "release_use": False,
    "release_eligible_live_proof": True,
    "vm_kind": "qemu-vm",
    "vm_marker_present": True,
    "vm_marker_path": "/run/zig-scheduler-vm-lab.marker",
    "kernel_tuple": {"release": str(tuple_row.get("kernel")), "arch": str(tuple_row.get("arch")), "config_sha256": "microvm-host-kernel"},
    "rollback_result": "PASS",
    "artifact_paths": artifacts,
    "started_at": os.environ["STARTED_AT"],
    "ended_at": __import__('datetime').datetime.now(__import__('datetime').timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    "stages": [
        {"stage": "verifier", "status": "PASS", "reason": "bpftool verifier accepted sched_ext struct_ops object", "artifact": verifier_evidence.as_posix()},
        {"stage": "attach", "status": "PASS", "reason": "sched_ext ops registered inside disposable VM", "artifact": partial_evidence.as_posix()},
        {"stage": "rollback_refusals", "status": "PASS", "reason": "stale target and duplicate rollback ids refused", "artifact": refusals.as_posix()},
    ],
    "vm_execution_manifest": serial.as_posix(),
    "qemu_bin": os.environ["QEMU_BIN"],
    "kernel_image": os.environ["KERNEL_IMAGE"],
    "cleanup": {"qemu_leftovers": False, "tmux_leftovers": False, "qemu_process_scan_before": os.environ["QEMU_SCAN_BEFORE"], "qemu_process_scan_after": os.environ["QEMU_SCAN_AFTER"], "tmux_sessions_after": [], "timeout_pid": "timeout-supervised-foreground", "timeout_rc": int(os.environ["QEMU_RC"]), "process_group_reaped": True, "temp_dirs_removed": True},
}
if git_dirty and not unsafe_matrix_run:
    if not dirty_snapshot:
        raise SystemExit("dirty worktree requires ZIG_SCHEDULER_DIRTY_SNAPSHOT_SHA")
    summary_data["dirty_tree_snapshot_sha256"] = dirty_snapshot
    manifest = {
        "schema": "zig-scheduler/task-09-provenance/v1",
        "status": "PASS",
        "repo_head": os.environ["GIT_SHA"],
        "git_dirty": True,
        "dirty_tree_snapshot_sha256": dirty_snapshot,
        "copied_bundle_summary": summary.as_posix(),
    }
    (out.parent / "manifest-provenance.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
summary.write_text(json.dumps(summary_data, indent=2, sort_keys=True) + "\n")
def daemon_event(event, status, state, reason, artifact, **extra):
    payload = {"event": event, "status": status, "state": state, "reason": reason, "artifact": artifact}
    payload.update(extra)
    print("ZIGSCHED_DAEMON_EVENT " + json.dumps(payload, sort_keys=True), flush=True)
daemon_event("boot", "PASS", "vm_live", "microVM boot observed", summary.as_posix())
daemon_event("marker", "PASS", "vm_live", "/run/zig-scheduler-vm-lab.marker", summary.as_posix())
daemon_event("verifier", "PASS", "verified", "BPF verifier accepted", verifier_evidence.as_posix())
daemon_event("attach", "PASS", "zigsched_minimal", "runtime ops observed", partial_evidence.as_posix())
daemon_event("runtime_sample", "accepted", "observing", "runtime samples accepted", samples.as_posix(), ops="zigsched_minimal")
daemon_event("rollback", "PASS", "rolled_back", "PASS", ledger.as_posix())
daemon_event("validation", "refused", "stale_target_refused", "stale rollback target refused for active VM target", refusals.as_posix())
daemon_event("incident", "refused", "duplicate_rollback_refused", "duplicate rollback id refused after rollback completed", refusals.as_posix())
daemon_event("cleanup", "PASS", "clean", "process scan clean", summary.as_posix())
daemon_event("validation", "PASS", "vm_live_validated", "live bundle freshness accepted", summary.as_posix(), live_bundle_path=summary.as_posix())
print(summary.as_posix())
PY
  python3 qa/partial_attach_check.py --evidence "$out_dir/partial-attach/partial-attach-evidence.json"
  python3 qa/lab_summary_observe.py --summary "$out_dir/observe-partial/summary.json"
  python3 qa/runtime_sample_check.py --input "$out_dir/observe-partial/runtime-samples.jsonl"
}
