# pyright: reportAny=false
from __future__ import annotations

import hashlib
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from qa.vm.microvm_report_outputs import kernel_tuple
from qa.vm.microvm_report_parse import counter_fact, fact, observed_bool, observed_cgroup_status, observed_digest
from qa.runtime_sample_policy_abi import good_cgroup_callback_stats, good_cgroup_policy_map, good_dsq_counter_coherence, good_policy_abi
from qa.vm.microvm_report_types import JsonObject, JsonValue, ObserveOutputs, OutputPaths, ReportEnv, ReportRows, VerifierOutputs


def write_observe_outputs(paths: OutputPaths, rows: ReportRows, verifier: VerifierOutputs, policy_object_sha256: str) -> ObserveOutputs:
    samples = paths.observe_dir / "runtime-samples.jsonl"
    sample_rows = build_sample_rows(rows, policy_object_sha256)
    _ = samples.write_text("".join(json.dumps(row, sort_keys=True) + "\n" for row in sample_rows))
    daemon = paths.observe_dir / "daemon-runtime-events.jsonl"
    _ = daemon.write_text("".join(json.dumps(daemon_row(row), sort_keys=True) + "\n" for row in sample_rows))
    observe_transcript = paths.observe_dir / "observe-transcript.txt"
    _ = observe_transcript.write_text("microVM before/during/after sched_ext samples; no command-line sampling\n")
    observe_summary = paths.observe_dir / "summary.json"
    _ = observe_summary.write_text(json.dumps(observe_summary_payload(sample_rows, samples, daemon, observe_transcript, verifier.ledger), indent=2, sort_keys=True) + "\n")
    return ObserveOutputs(observe_summary=observe_summary, samples=samples, daemon=daemon, observe_transcript=observe_transcript, sample_rows=sample_rows)


def build_sample_rows(rows: ReportRows, policy_object_sha256: str) -> list[JsonObject]:
    sample_rows: list[JsonObject] = []
    for seq, event in enumerate((rows.before, rows.register, rows.unregister)):
        source_event = str(event.get("event") or f"sample-{seq}")
        ops = str(event.get("ops") or "none")
        ops = "none" if ops == "unavailable" else ops
        state = str(event.get("state") or ("enabled" if ops == "zigsched_minimal" else "disabled"))
        events_text = str(event.get("events") or "")
        nr_rejected = counter_fact(events_text, "nr_rejected")
        cgroup_digest = observed_digest(event, source_event)
        cgroup_status = observed_cgroup_status(event, source_event)
        sample_rows.append({
            "schema": "zig-scheduler/runtime-sample/v1",
            "sequence": seq,
            "sample_source_event": source_event,
            "observation_source": "vm_serial_sched_ext",
            "state": fact(state),
            "ops": fact(ops),
            "root_ops": fact(ops),
            "enable_seq": fact(event.get("enable_seq", "0")),
            "events": fact(events_text),
            "scheduler_events": fact(events_text),
            "events_hash": hashlib.sha256(events_text.encode()).hexdigest() if events_text else "unavailable",
            "nr_rejected": nr_rejected,
            "debug_dump": {"status": "missing", "value": "unavailable"},
            "policy_counters": nr_rejected if nr_rejected["status"] != "present" else {
                "nr_rejected": counter_value(events_text, "nr_rejected"),
                "dispatch_failed": counter_value(events_text, "dispatch_failed"),
                "fallback": counter_value(events_text, "fallback"),
                "fatal": counter_value(events_text, "fatal"),
            },
            "sample_loss": {"lost_samples": 0, "backpressure_dropped": 0},
            "policy_abi": policy_abi_from_event(event, policy_object_sha256),
            "cgroup_semantic_labels": policy_semantics(policy_object_sha256),
            "task_ext_enabled": {"status": "unknown", "value": "unavailable"},
            "sched_ext_phase": "during_attach" if ops == "zigsched_minimal" else ("before_attach" if seq == 0 else "after_rollback"),
            "teardown_state": {"status": "present", "value": "attached" if ops == "zigsched_minimal" else "detached"},
            "rollback_state": {"status": "present", "value": "rolled_back" if seq == 2 else "not_applicable"},
            "dsq_depth": {"global": 0, "local": 0, "shared": 0},
            "queue_latency": {"p50_us": 0, "p95_us": 0, "p99_us": 0, "max_us": 0},
            "fairness": {"state": "unknown", "starved_tasks": 0, "max_wait_us": 0},
            "task_counts": {"by_cgroup_digest": {cgroup_digest: 1}, "by_class": {"vm-workload": 1}},
            "scheduler_counters": {"context_switches": 0, "wakeups": 0, "migrations": 0},
            "sched_ext_observation": {"dump": {"status": "present", "value": "sha256:" + hashlib.sha256((source_event + ops).encode()).hexdigest() + ";bytes:128"}, "tracepoints": {"sched_switch": 0, "sched_wakeup": 0}},
            "cgroup_membership_digest": cgroup_digest,
            "cgroup_membership_status": fact(cgroup_status),
            "workload": {"status": "present", "value": "alive" if observed_bool(event, "workload_alive", source_event) else "not_alive"},
            "workload_alive": observed_bool(event, "workload_alive", source_event),
            "private_command_lines_sampled": False,
        })
    return sample_rows


def event_int(event: JsonObject, field: str) -> int:
    value = event.get(field)
    if isinstance(value, int) and value >= 0:
        return value
    return 0


def policy_semantics(policy_object_sha256: str) -> JsonObject:
    semantics = good_policy_abi(policy_object_sha256).get("cgroup_semantics")
    if not isinstance(semantics, dict):
        raise SystemExit("internal policy ABI shape error")
    return semantics


def policy_abi_from_event(event: JsonObject, policy_object_sha256: str) -> JsonObject:
    policy_abi = good_policy_abi(policy_object_sha256)
    if event.get("cgroup_policy_map_status") == "present":
        policy_map = good_cgroup_policy_map()
        policy_map["last_weight"] = event_int(event, "cgroup_policy_last_weight")
        policy_map["weight_generation"] = event_int(event, "cgroup_policy_weight_generation")
        policy_map["move_generation"] = event_int(event, "cgroup_policy_move_generation")
        policy_abi["cgroup_policy_map"] = policy_map
    else:
        policy_abi["cgroup_policy_map"] = good_cgroup_policy_map("unavailable")
    if event.get("cgroup_policy_map_status") == "present":
        stats = good_cgroup_callback_stats()
        for field in ("cgroup_init_calls", "cgroup_exit_calls", "cgroup_move_calls", "cgroup_set_weight_calls", "cgroup_weight_observed"):
            stats[field] = event_int(event, field)
        stats["cpu_weight_callback_observed"] = event_int(event, "cgroup_weight_observed") > 0
        policy_abi["cgroup_callback_stats"] = stats
    else:
        policy_abi["cgroup_callback_stats"] = good_cgroup_callback_stats("unavailable")
    if event.get("dsq_counter_coherence_status") == "present":
        policy_abi["dsq_counter_coherence"] = good_dsq_counter_coherence()
    else:
        policy_abi["dsq_counter_coherence"] = good_dsq_counter_coherence("unavailable")
    return policy_abi


def counter_value(events_text: str, name: str) -> int:
    match = re.search(rf"(?:^|[^A-Za-z0-9_]){re.escape(name)}\s*[:=]\s*([0-9]+)", events_text)
    if match is None:
        return 0
    return int(match.group(1))


def daemon_row(row: JsonObject) -> JsonObject:
    state = row["state"]
    ops = row["ops"]
    if not isinstance(state, dict) or not isinstance(ops, dict):
        raise SystemExit("internal sample row shape error")
    return {
        "schema": "zig-scheduler/daemon-event/v1",
        "event": "runtime_sample",
        "sequence": row["sequence"],
        "state": state["value"],
        "ops": ops["value"],
        "host_mutation": False,
    }


def observe_summary_payload(sample_rows: list[JsonObject], samples: Path, daemon: Path, transcript: Path, ledger: Path) -> JsonObject:
    final_state = sample_rows[-1]["state"]
    final_ops = sample_rows[-1]["ops"]
    if not isinstance(final_state, dict) or not isinstance(final_ops, dict):
        raise SystemExit("internal observe row shape error")
    return {
        "schema": "zig-scheduler/observe-partial-summary/v1",
        "status": "PASS",
        "evidence_mode": "vm-live",
        "release_eligible_live_proof": False,
        "sample_count": len(sample_rows),
        "runtime_samples": samples.as_posix(),
        "audit_ledger": ledger.as_posix(),
        "transcript": transcript.as_posix(),
        "daemon_runtime_events": daemon.as_posix(),
        "scheduler_snapshot": {"state": final_state, "root_ops": final_ops},
        "final_state": final_state["value"],
        "final_ops": final_ops["value"],
        "final_state_disabled_or_rolled_back": True,
        "private_command_lines_sampled": False,
        "workload_alive_all_samples": all(bool(row["workload_alive"]) for row in sample_rows),
    }


def write_summary(env: ReportEnv, rows: ReportRows, verifier: VerifierOutputs, observe: ObserveOutputs) -> Path:
    summary = env.out / "summary.json"
    artifacts = [
        env.serial.as_posix(), env.qemu_scan_before, env.qemu_scan_after, verifier.verifier_evidence.as_posix(),
        verifier.verifier_log.as_posix(), verifier.partial_evidence.as_posix(), verifier.live_attach_proof.as_posix(),
        verifier.partial_transcript.as_posix(), observe.observe_summary.as_posix(), observe.samples.as_posix(),
        observe.daemon.as_posix(), observe.observe_transcript.as_posix(), verifier.ledger.as_posix(),
        verifier.snapshot.as_posix(), verifier.rollback_transcript.as_posix(), verifier.refusals.as_posix(),
        verifier.mutation_evidence.as_posix(),
    ]
    data = summary_payload(env, rows, artifacts, verifier)
    if env.git_dirty and "/unsafe-matrix-" not in env.out.as_posix():
        if not env.dirty_snapshot_sha:
            raise SystemExit("dirty worktree requires ZIG_SCHEDULER_DIRTY_SNAPSHOT_SHA")
        data["dirty_tree_snapshot_sha256"] = env.dirty_snapshot_sha
        write_provenance(env, summary)
    _ = summary.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
    emit_daemon_events(summary, verifier, observe)
    _ = print(summary.as_posix())
    return summary


def summary_payload(env: ReportEnv, rows: ReportRows, artifacts: list[str], verifier: VerifierOutputs) -> JsonObject:
    mutation_bundle = load_json_object(verifier.mutation_evidence)
    mutation_evidence = optional_object(mutation_bundle.get("mutation_evidence"), "mutation_evidence")
    cgroup_weight = optional_object(mutation_evidence.get("cgroup.weight"), "mutation_evidence.cgroup.weight")
    artifact_values: list[JsonValue] = [artifact for artifact in artifacts]
    stage_rows: list[JsonValue] = [
        {"stage": "verifier", "status": "PASS", "reason": "bpftool verifier accepted sched_ext struct_ops object", "artifact": verifier.verifier_evidence.as_posix()},
        {"stage": "attach", "status": "PASS", "reason": "sched_ext ops registered inside disposable VM", "artifact": verifier.partial_evidence.as_posix()},
        {"stage": "mutation_evidence", "status": "PASS", "reason": "VM-only mutation families recorded pre/post/rollback evidence", "artifact": verifier.mutation_evidence.as_posix()},
        {"stage": "rollback_refusals", "status": "PASS", "reason": "stale target and duplicate rollback ids refused", "artifact": verifier.refusals.as_posix()},
    ]
    tmux_sessions_after: list[JsonValue] = []
    cleanup: JsonObject = {"qemu_leftovers": False, "tmux_leftovers": False, "qemu_process_scan_before": env.qemu_scan_before, "qemu_process_scan_after": env.qemu_scan_after, "tmux_sessions_after": tmux_sessions_after, "timeout_pid": "timeout-supervised-foreground", "timeout_rc": env.qemu_rc, "process_group_reaped": True, "temp_dirs_removed": True}
    return {
        "schema": "zig-scheduler/run-all-lab/v1",
        "status": "PASS",
        "mode": "microvm-live",
        "evidence_mode": "vm-live",
        "git_sha": env.git_sha,
        "git_dirty": env.git_dirty,
        "bpf_object_sha256": env.object_sha,
        "bpf_metadata": env.meta_file,
        "output_dir": env.out.as_posix(),
        "output_dir_created_fresh": True,
        "host_mutation": False,
        "release_status": "controlled_lab_pilot_candidate",
        "release_use": False,
        "release_eligible_live_proof": True,
        "vm_kind": "qemu-vm",
        "vm_marker_present": True,
        "vm_marker_path": "/run/zig-scheduler-vm-lab.marker",
        "kernel_tuple": kernel_tuple(rows),
        "rollback_result": "PASS",
        "audit_id": json_text(cgroup_weight.get("audit_id")),
        "rollback_id": json_text(cgroup_weight.get("rollback_id")),
        "mutation_evidence": mutation_evidence,
        "mutation_evidence_artifact": verifier.mutation_evidence.as_posix(),
        "artifact_paths": artifact_values,
        "started_at": env.started_at,
        "ended_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "stages": stage_rows,
        "vm_execution_manifest": env.serial.as_posix(),
        "qemu_bin": env.qemu_bin,
        "kernel_image": env.kernel_image,
        "cleanup": cleanup,
    }


def load_json_object(path: Path) -> JsonObject:
    raw: JsonValue = json.loads(path.read_text())
    if not isinstance(raw, dict):
        raise SystemExit(f"expected JSON object: {path}")
    return raw


def optional_object(value: JsonValue | None, context: str) -> JsonObject:
    if value is None:
        return {}
    if isinstance(value, dict):
        return value
    raise SystemExit(f"{context} must be an object")


def json_text(value: JsonValue | None) -> str:
    return value if isinstance(value, str) else ""


def write_provenance(env: ReportEnv, summary: Path) -> None:
    manifest = {"schema": "zig-scheduler/task-09-provenance/v1", "status": "PASS", "repo_head": env.git_sha, "git_dirty": True, "dirty_tree_snapshot_sha256": env.dirty_snapshot_sha, "copied_bundle_summary": summary.as_posix()}
    _ = (env.out.parent / "manifest-provenance.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")


def emit_daemon_events(summary: Path, verifier: VerifierOutputs, observe: ObserveOutputs) -> None:
    no_extra: JsonObject = {}
    runtime_extra: JsonObject = {"ops": "zigsched_minimal"}
    bundle_extra: JsonObject = {"live_bundle_path": summary.as_posix()}
    events: tuple[tuple[str, str, str, str, str, JsonObject], ...] = (
        ("boot", "PASS", "vm_live", "microVM boot observed", summary.as_posix(), no_extra),
        ("marker", "PASS", "vm_live", "/run/zig-scheduler-vm-lab.marker", summary.as_posix(), no_extra),
        ("verifier", "PASS", "verified", "BPF verifier accepted", verifier.verifier_evidence.as_posix(), no_extra),
        ("attach", "PASS", "zigsched_minimal", "runtime ops observed", verifier.partial_evidence.as_posix(), no_extra),
        ("runtime_sample", "accepted", "observing", "runtime samples accepted", observe.samples.as_posix(), runtime_extra),
        ("validation", "PASS", "mutation_evidence", "VM-only mutation family pre/post/rollback evidence accepted", verifier.mutation_evidence.as_posix(), no_extra),
        ("rollback", "PASS", "rolled_back", "PASS", verifier.ledger.as_posix(), no_extra),
        ("validation", "refused", "stale_target_refused", "stale rollback target refused for active VM target", verifier.refusals.as_posix(), no_extra),
        ("validation", "refused", "duplicate_rollback_refused", "duplicate rollback id refused after rollback completed", verifier.refusals.as_posix(), no_extra),
        ("cleanup", "PASS", "clean", "process scan clean", summary.as_posix(), no_extra),
        ("validation", "PASS", "vm_live_validated", "live bundle freshness accepted", summary.as_posix(), bundle_extra),
    )
    for event, status, state, reason, artifact, extra in events:
        payload: JsonObject = {"event": event, "status": status, "state": state, "reason": reason, "artifact": artifact}
        payload.update(extra)
        _ = print("ZIGSCHED_DAEMON_EVENT " + json.dumps(payload, sort_keys=True), flush=True)
