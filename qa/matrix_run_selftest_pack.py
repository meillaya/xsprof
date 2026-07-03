#!/usr/bin/env python3
"""Fixture and manifest self-test pack builders for matrix-run checks."""
from __future__ import annotations

import json
from pathlib import Path

from qa.runtime_sample_check import good_sample as runtime_good_sample
from qa.matrix_run_json import file_sha256, load_json, obj, text
from qa.matrix_run_model import (
    MANIFEST_FILE,
    PRIVACY_SCAN_SCHEMA,
    VM_MARKER,
    WORKLOAD_CAPABILITY_SCHEMA,
    WORKLOAD_SPEC_SCHEMA,
    JsonObject,
    JsonValue,
    MatrixRunContractError,
)
from qa.matrix_run_selftest_common import clone_object, write_json, write_json_digest
from qa.matrix_run_workload import expected_workload_metadata, workload_semantic_fields

def write_manifest_self_test_pack(run_root: Path, good: JsonObject, scenario: str = "workload-cpu-saturation") -> Path:
    expected = expected_workload_metadata(scenario)
    row_dir = run_root / "rows" / scenario
    row_dir.mkdir(parents=True)
    run_id = run_root.name
    row = clone_object(good)
    row["matrix_run_id"] = run_id
    row["scenario_id"] = scenario
    row["evidence_mode"] = "vm-live"
    row["runtime_sample_path"] = (row_dir / "runtime-sample.jsonl").as_posix()
    row["daemon_event_path"] = (run_root / "daemon-events.jsonl").as_posix()
    row["incident_path"] = (row_dir / "incident.json").as_posix()
    row["rollback_proof_path"] = (row_dir / "rollback-proof.json").as_posix()
    row["cleanup_proof_path"] = (row_dir / "cleanup-proof.json").as_posix()
    row["host_refusal_proof_path"] = (row_dir / "host-refusal.json").as_posix()
    marker = obj(row.get("vm_marker"), "manifest self-test vm_marker")
    marker["required"] = True
    marker["present"] = True
    marker["checked_by"] = (row_dir / "vm-marker-proof.json").as_posix()
    policy = obj(row.get("policy"), "manifest self-test policy")
    policy["object_path"] = (row_dir / "policy.o").as_posix()
    workload = obj(row.get("workload"), "manifest self-test workload")
    workload_class = expected.workload_class if expected is not None else "backend-live-proof"
    required_tools = list(expected.required_tools) if expected is not None else ["builtin-churn"]
    required_tools_json: list[JsonValue] = list(required_tools)
    workload["name"] = workload_class
    workload["spec_path"] = (row_dir / "workload-spec.json").as_posix()
    privacy_scan = obj(row.get("privacy_scan"), "manifest self-test privacy_scan")
    privacy_scan["report_path"] = (row_dir / "privacy-scan.json").as_posix()
    _ = write_json_digest(row_dir / "privacy-scan.json", {"schema": PRIVACY_SCAN_SCHEMA, "status": "PASS", "private_fields_found": False, "host_mutation": False})
    threshold_source = next(iter(expected.threshold_sources)) if expected is not None else "fixture"
    capability_path = row_dir / "workload-capability.json"
    _ = write_json_digest(capability_path, {
        "schema": WORKLOAD_CAPABILITY_SCHEMA,
        "scenario_id": scenario,
        "workload_class": workload_class,
        "required_tools": required_tools_json,
        "threshold_source": threshold_source,
        "mode": "host-safe",
        "status": "PASS",
        "typed_outcome": "PASS",
        "missing_prereq": "",
        "vm_marker_required_for_live_run": True,
        "host_mutation": False,
        "release_eligible": False,
    })
    bench_raw_path = row_dir / "bench" / "perf-bench-sched-messaging.txt"
    bench_raw_path.parent.mkdir()
    _ = bench_raw_path.write_text("# Running 'sched/messaging' benchmark:\n# 20 sender and receiver processes per group\n# 10 groups == 400 processes run\n     Total time: 0.123 [sec]\n")
    benchmark_record_path = row_dir / "benchmark-provenance" / "perf_bench_sched_messaging.benchmark-output.json"
    benchmark_record_path.parent.mkdir()
    workload_spec: JsonObject = {
        "schema": WORKLOAD_SPEC_SCHEMA,
        "name": workload_class,
        "workload_class": workload_class,
        "scenario_id": scenario,
        "required_tools": required_tools_json,
        "threshold_source": threshold_source,
        "thresholds": {"source": threshold_source, "fixture_status": "deterministic", "calibration_status": "uncalibrated", "production_capacity_claim": False},
        "benchmark_provenance": [{
            "record_path": benchmark_record_path.as_posix(),
            "record_sha256": write_json_digest(benchmark_record_path, {
                "schema": "zig-scheduler/benchmark-output/v1",
                "status": "RECORDED",
                "tool": "perf",
                "command_family": "perf_bench_sched_messaging",
                "record_only": True,
                "output_path": bench_raw_path.as_posix(),
                "output_sha256": file_sha256(bench_raw_path),
                "vm_evidence": (run_root / "manifest.json").as_posix(),
                "parser_provenance": {
                    "parser": "qa/benchmark_output_parse.py",
                    "parser_version": "benchmark-output/v1",
                    "parser_status": "PARSED",
                },
                "metrics": {"groups": 10.0, "processes": 400.0, "total_time_seconds": 0.123},
                "units": {"groups": "count", "processes": "count", "total_time_seconds": "seconds"},
                "sample_count": 1,
                "run_count": 1,
                "host_mutation": False,
                "release_eligible": False,
                "production_capacity_claim": False,
                "hard_thresholds_enforced": False,
                "threshold_status": "record_only",
                "privacy_sanitized": True,
            }),
            "record_only": True,
        }],
        "capability_artifact_path": capability_path.as_posix(),
        "vm_marker_required_for_live_run": True,
        "host_mutation": False,
        "release_eligible": False,
    }
    workload_spec.update(workload_semantic_fields(scenario))
    workload["spec_sha256"] = write_json_digest(row_dir / "workload-spec.json", workload_spec)
    write_json(row_dir / "vm-marker-proof.json", {"schema": "zig-scheduler/vm-marker-proof/v1", "path": VM_MARKER, "required": True, "present": True, "evidence_mode": "vm-live", "host_mutation": False})
    write_json(row_dir / "incident.json", {"schema": "zig-scheduler/matrix-incident/v1", "scenario_id": scenario, "outcome": "PASS", "reason": "self-test", "host_mutation": False, "release_eligible": False})
    write_json(row_dir / "rollback-proof.json", {"schema": "zig-scheduler/rollback-proof/v1", "scenario_id": scenario, "status": "PASS", "scheduler_state": "disabled", "ops": "none", "host_mutation": False})
    write_json(row_dir / "cleanup-proof.json", {"schema": "zig-scheduler/cleanup-proof/v1", "scenario_id": scenario, "status": "PASS", "owned_qemu_leftovers": False, "owned_temp_leftovers": False, "qemu_scan_before": (row_dir / "qemu-process-scan-before.txt").as_posix(), "qemu_scan_after": (row_dir / "qemu-process-scan-after.txt").as_posix(), "temp_scan_before": (row_dir / "temp-scan-before.txt").as_posix(), "temp_scan_after": (row_dir / "temp-scan-after.txt").as_posix(), "host_mutation": False})
    write_json(row_dir / "host-refusal.json", {"schema": "zig-scheduler/host-refusal-proof/v1", "scenario_id": scenario, "status": "REFUSE", "reason": "host mutation refused", "no_bpf_load_attach": True, "no_cgroup_write": True, "no_sys_write": True, "no_proc_write": True, "host_mutation": False})
    _ = (row_dir / "runtime-sample.jsonl").write_text(json.dumps(runtime_good_sample(), sort_keys=True) + "\n")
    row_path = row_dir / "matrix-run.json"
    _ = (run_root / "daemon-events.jsonl").write_text(json.dumps({"schema": "zig-scheduler/daemon-event/v1", "seq": 1, "event": "validation", "status": "PASS", "run_id": run_id, "target_id": scenario, "action_id": "ACT-" + scenario, "audit_id": "AUD-20260629T120000Z-abcdef0-000001", "rollback_id": "RB-" + scenario, "reason": "self-test", "artifact_paths": [row_path.as_posix()], "git_sha": "abcdef012345", "host_mutation": False}, sort_keys=True) + "\n")
    write_json(row_path, row)
    manifest: JsonObject = {
        "schema": "zig-scheduler/vm-harness-matrix-index/v1",
        "matrix_run_id": run_id,
        "mode": "vm-required",
        "fixture_mode": False,
        "started_at": "2026-06-29T12:00:00Z",
        "ended_at": "2026-06-29T12:00:01Z",
        "out_dir": run_root.as_posix(),
        "daemon_events_path": (run_root / "daemon-events.jsonl").as_posix(),
        "row_count": 1,
        "rows": [{"scenario_id": scenario, "outcome": text(row.get("outcome"), "manifest self-test row.outcome"), "artifact_path": row_path.as_posix(), "reason": "self-test"}],
        "host_mutation": False,
        "release_eligible": False,
    }
    manifest_path = run_root / MANIFEST_FILE
    write_json(manifest_path, manifest)
    return manifest_path

def write_host_safe_fixture_pass_self_test_pack(run_root: Path, good: JsonObject) -> Path:
    manifest_path = write_manifest_self_test_pack(run_root, good)
    manifest = load_json(manifest_path)
    manifest["mode"] = "host-safe"
    manifest["fixture_mode"] = True
    rows = manifest.get("rows")
    if not isinstance(rows, list):
        raise MatrixRunContractError("host-safe fixture self-test setup produced non-list rows")
    row = obj(rows[0], "host-safe fixture self-test first row")
    artifact_path = Path(text(row.get("artifact_path"), "host-safe fixture self-test artifact_path"))
    row_data = load_json(artifact_path)
    row_data["evidence_mode"] = "fixture"
    marker = obj(row_data.get("vm_marker"), "host-safe fixture self-test vm_marker")
    marker["required"] = False
    marker["present"] = False
    marker["checked_by"] = "qa/vm/vm_harness_matrix.sh"
    write_json(artifact_path, row_data)
    write_json(manifest_path, manifest)
    return manifest_path
