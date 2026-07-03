#!/usr/bin/env python3
"""Manifest and dereferenced artifact validators for matrix-run/v1."""
from __future__ import annotations

from pathlib import Path

from qa.daemon_event_contract_check import ContractError as DaemonEventContractError
from qa.daemon_event_contract_check import validate as validate_daemon_event_stream
from qa.runtime_sample_check import RuntimeSampleError
from qa.runtime_sample_check import validate_file as validate_runtime_sample_file
from qa.matrix_run_json import (
    bool_field,
    file_sha256,
    load_json,
    obj,
    reject_private,
    reject_workload_artifact_private,
    require,
    require_descendant,
    require_manifest_root,
    require_only_fields,
    require_safe_path,
    text,
)
from qa.matrix_run_model import (
    CLEANUP_PROOF_FIELDS,
    HOST_REFUSAL_FIELDS,
    ID_RE,
    INCIDENT_FIELDS,
    MANIFEST_FIELDS,
    MANIFEST_ROW_FIELDS,
    PATH_FIELDS,
    ROLLBACK_PROOF_FIELDS,
    RUN_ID_MAX,
    RUN_ID_RE,
    VM_MARKER,
    VM_MARKER_PROOF_FIELDS,
    JsonObject,
    MatrixRunContractError,
)
from qa.matrix_run_validate import validate_row
from qa.matrix_run_live_backend import validate_live_backend_summary_consistency
from qa.matrix_run_workload import (
    expected_workload_metadata,
    require_expected_workload_metadata,
    validate_privacy_report,
    validate_workload_capability,
    validate_workload_spec,
)

def validate_manifest(manifest_path: Path) -> tuple[int, int]:
    manifest_root = require_manifest_root(manifest_path)
    manifest = load_json(manifest_path)
    require_only_fields(manifest, MANIFEST_FIELDS, str(manifest_path))
    require(manifest.get("schema") == "zig-scheduler/vm-harness-matrix-index/v1", f"{manifest_path}.schema unsupported")
    require(manifest.get("host_mutation") is False, f"{manifest_path}.host_mutation must be false")
    require(manifest.get("release_eligible") is False, f"{manifest_path}.release_eligible must be false")
    manifest_run_id = text(manifest.get("matrix_run_id"), f"{manifest_path}.matrix_run_id")
    require(RUN_ID_RE.fullmatch(manifest_run_id) is not None, f"{manifest_path}.matrix_run_id must be 1-{RUN_ID_MAX} safe characters")
    require(manifest_run_id == manifest_root.name, f"{manifest_path}.matrix_run_id must equal out_dir basename {manifest_root.name}")
    require(Path(require_safe_path(manifest.get("out_dir"), f"{manifest_path}.out_dir")) == manifest_root, f"{manifest_path}.out_dir must match manifest directory")
    daemon_events_path = Path(require_safe_path(manifest.get("daemon_events_path"), f"{manifest_path}.daemon_events_path"))
    require_descendant(daemon_events_path, manifest_root, f"{manifest_path}.daemon_events_path")
    mode = text(manifest.get("mode"), f"{manifest_path}.mode")
    fixture_mode = bool_field(manifest.get("fixture_mode"), f"{manifest_path}.fixture_mode")
    _ = text(manifest.get("started_at"), f"{manifest_path}.started_at")
    _ = text(manifest.get("ended_at"), f"{manifest_path}.ended_at")
    rows = manifest.get("rows")
    if not isinstance(rows, list):
        raise MatrixRunContractError(f"{manifest_path}.rows must be a list")
    require(manifest.get("row_count") == len(rows), f"{manifest_path}.row_count must match rows length")
    seen_scenarios: set[str] = set()
    seen_artifacts: set[str] = set()
    validate_manifest_daemon_events(daemon_events_path, manifest_root, f"{manifest_path}.daemon_events_path")
    for index, raw_row in enumerate(rows):
        manifest_row = obj(raw_row, f"{manifest_path}.rows[{index}]")
        require_only_fields(manifest_row, MANIFEST_ROW_FIELDS, f"{manifest_path}.rows[{index}]")
        scenario_id = text(manifest_row.get("scenario_id"), f"{manifest_path}.rows[{index}].scenario_id")
        require(ID_RE.fullmatch(scenario_id) is not None, f"{manifest_path}.rows[{index}].scenario_id is not a stable identifier")
        require(scenario_id not in seen_scenarios, f"{manifest_path}.rows[{index}].scenario_id duplicates an earlier row")
        seen_scenarios.add(scenario_id)
        artifact_path = Path(require_safe_path(manifest_row.get("artifact_path"), f"{manifest_path}.rows[{index}].artifact_path"))
        artifact_key = artifact_path.as_posix()
        require(artifact_key not in seen_artifacts, f"{manifest_path}.rows[{index}].artifact_path duplicates an earlier row")
        seen_artifacts.add(artifact_key)
        require_descendant(artifact_path, manifest_root, f"{manifest_path}.rows[{index}].artifact_path")
        require(artifact_path.name == "matrix-run.json", f"{manifest_path}.rows[{index}].artifact_path must point to matrix-run.json")
        row = load_json(artifact_path)
        validate_row(row, artifact_path.as_posix())
        validate_manifest_row_paths(row, manifest_root, artifact_path.as_posix())
        validate_manifest_vm_claim(row, mode, fixture_mode, manifest_root, artifact_path.as_posix())
        validate_live_backend_summary_consistency(row, artifact_path, artifact_path.as_posix())
        require(row.get("matrix_run_id") == manifest_run_id, f"{artifact_path}.matrix_run_id must match manifest")
        require(manifest_row.get("scenario_id") == row.get("scenario_id"), f"{manifest_path}.rows[{index}].scenario_id mismatch")
        require(manifest_row.get("outcome") == row.get("outcome"), f"{manifest_path}.rows[{index}].outcome mismatch")
    return len(rows), 0

def validate_manifest_daemon_events(path: Path, manifest_root: Path, context: str) -> None:
    require_descendant(path, manifest_root, context)
    try:
        validate_daemon_event_stream(path, False)
    except DaemonEventContractError as exc:
        raise MatrixRunContractError(f"{context} invalid daemon event stream: {exc}") from exc

def validate_manifest_vm_claim(row: JsonObject, mode: str, fixture_mode: bool, manifest_root: Path, context: str) -> None:
    marker = obj(row.get("vm_marker"), f"{context}.vm_marker")
    marker_required = bool_field(marker.get("required"), f"{context}.vm_marker.required")
    marker_present = bool_field(marker.get("present"), f"{context}.vm_marker.present")
    evidence_mode = text(row.get("evidence_mode"), f"{context}.evidence_mode")
    outcome = text(row.get("outcome"), f"{context}.outcome")
    fixture_authorized = fixture_mode and mode in {"host-safe", "auto"}
    if evidence_mode == "fixture":
        require(fixture_authorized, f"{context} fixture evidence requires explicit fixture_mode=true on a host-safe/auto manifest")
    if outcome == "PASS" and not fixture_authorized:
        require(evidence_mode == "vm-live", f"{context} non-fixture PASS requires vm-live evidence")
    if fixture_authorized:
        require(not marker_present, f"{context} fixture manifest must not claim VM marker presence")
        require(evidence_mode != "vm-live", f"{context} fixture manifest must not claim vm-live evidence")
        if outcome == "PASS":
            require(evidence_mode == "fixture", f"{context} fixture PASS must use fixture evidence")
    if evidence_mode == "vm-live" or marker_present:
        marker_path = Path(require_safe_path(marker.get("checked_by"), f"{context}.vm_marker.checked_by"))
        require_descendant(marker_path, manifest_root, f"{context}.vm_marker.checked_by")
        validate_vm_marker_proof(load_json(marker_path), marker_required, marker_present, evidence_mode, f"{context}.vm_marker.proof")

def validate_vm_marker_proof(data: JsonObject, marker_required: bool, marker_present: bool, evidence_mode: str, context: str) -> None:
    require_only_fields(data, VM_MARKER_PROOF_FIELDS, context)
    require(data.get("schema") == "zig-scheduler/vm-marker-proof/v1", f"{context}.schema unsupported")
    require(data.get("path") == VM_MARKER, f"{context}.path mismatch")
    require(data.get("required") == marker_required, f"{context}.required must match row marker")
    require(data.get("present") == marker_present, f"{context}.present must match row marker")
    require(data.get("evidence_mode") == evidence_mode, f"{context}.evidence_mode must match row evidence_mode")
    require(marker_required and marker_present and evidence_mode == "vm-live", f"{context} must prove a real vm-live marker")
    require(data.get("host_mutation") is False, f"{context}.host_mutation must be false")

def validate_manifest_runtime_sample(path: Path, context: str) -> None:
    try:
        validate_runtime_sample_file(path)
    except RuntimeSampleError as exc:
        raise MatrixRunContractError(f"{context} invalid runtime sample artifact: {exc}") from exc

def validate_incident_artifact(data: JsonObject, scenario_id: str, outcome: str, context: str) -> None:
    require_only_fields(data, INCIDENT_FIELDS, context)
    require(data.get("schema") == "zig-scheduler/matrix-incident/v1", f"{context}.schema unsupported")
    require(data.get("scenario_id") == scenario_id, f"{context}.scenario_id must match row")
    require(data.get("outcome") == outcome, f"{context}.outcome must match row")
    _ = text(data.get("reason"), f"{context}.reason")
    require(data.get("host_mutation") is False, f"{context}.host_mutation must be false")
    require(data.get("release_eligible") is False, f"{context}.release_eligible must be false")
    reject_private(data, context)

def validate_rollback_artifact(data: JsonObject, scenario_id: str, context: str) -> None:
    require_only_fields(data, ROLLBACK_PROOF_FIELDS, context)
    require(data.get("schema") == "zig-scheduler/rollback-proof/v1", f"{context}.schema unsupported")
    require(data.get("scenario_id") == scenario_id, f"{context}.scenario_id must match row")
    _ = text(data.get("status"), f"{context}.status")
    _ = text(data.get("scheduler_state"), f"{context}.scheduler_state")
    _ = text(data.get("ops"), f"{context}.ops")
    require(data.get("host_mutation") is False, f"{context}.host_mutation must be false")
    reject_private(data, context)

def validate_cleanup_artifact(data: JsonObject, scenario_id: str, outcome: str, context: str) -> None:
    require_only_fields(data, CLEANUP_PROOF_FIELDS, context)
    require(data.get("schema") == "zig-scheduler/cleanup-proof/v1", f"{context}.schema unsupported")
    require(data.get("scenario_id") == scenario_id, f"{context}.scenario_id must match row")
    _ = text(data.get("status"), f"{context}.status")
    for field in ("owned_qemu_leftovers", "owned_temp_leftovers", "host_mutation"):
        require(data.get(field) is False, f"{context}.{field} must be false")
    for field in ("qemu_scan_before", "qemu_scan_after", "temp_scan_before", "temp_scan_after"):
        _ = require_safe_path(data.get(field), f"{context}.{field}")
    if outcome != "FAIL":
        require(data.get("status") == "PASS", f"{context}.status must be PASS unless row outcome is FAIL")
    reject_private(data, context)

def validate_host_refusal_artifact(data: JsonObject, scenario_id: str, context: str) -> None:
    require_only_fields(data, HOST_REFUSAL_FIELDS, context)
    require(data.get("schema") == "zig-scheduler/host-refusal-proof/v1", f"{context}.schema unsupported")
    require(data.get("scenario_id") == scenario_id, f"{context}.scenario_id must match row")
    require(data.get("status") == "REFUSE", f"{context}.status must be REFUSE")
    _ = text(data.get("reason"), f"{context}.reason")
    for field in ("no_bpf_load_attach", "no_cgroup_write", "no_sys_write", "no_proc_write"):
        require(data.get(field) is True, f"{context}.{field} must be true")
    require(data.get("host_mutation") is False, f"{context}.host_mutation must be false")
    reject_private(data, context)

def validate_manifest_proof_artifacts(row: JsonObject, context: str) -> None:
    scenario_id = text(row.get("scenario_id"), f"{context}.scenario_id")
    outcome = text(row.get("outcome"), f"{context}.outcome")
    validate_manifest_runtime_sample(Path(text(row.get("runtime_sample_path"), f"{context}.runtime_sample_path")), f"{context}.runtime_sample_path")
    validate_incident_artifact(load_json(Path(text(row.get("incident_path"), f"{context}.incident_path"))), scenario_id, outcome, f"{context}.incident")
    validate_rollback_artifact(load_json(Path(text(row.get("rollback_proof_path"), f"{context}.rollback_proof_path"))), scenario_id, f"{context}.rollback_proof")
    validate_cleanup_artifact(load_json(Path(text(row.get("cleanup_proof_path"), f"{context}.cleanup_proof_path"))), scenario_id, outcome, f"{context}.cleanup_proof")
    validate_host_refusal_artifact(load_json(Path(text(row.get("host_refusal_proof_path"), f"{context}.host_refusal_proof_path"))), scenario_id, f"{context}.host_refusal_proof")

def validate_manifest_row_paths(row: JsonObject, manifest_root: Path, context: str) -> None:
    daemon_event_path = Path(require_safe_path(row.get("daemon_event_path"), f"{context}.daemon_event_path"))
    require_descendant(daemon_event_path, manifest_root, f"{context}.daemon_event_path")
    validate_manifest_daemon_events(daemon_event_path, manifest_root, f"{context}.daemon_event_path")
    for field in PATH_FIELDS:
        require_descendant(Path(require_safe_path(row.get(field), f"{context}.{field}")), manifest_root, f"{context}.{field}")
    policy = obj(row.get("policy"), f"{context}.policy")
    require_descendant(Path(require_safe_path(policy.get("object_path"), f"{context}.policy.object_path")), manifest_root, f"{context}.policy.object_path")
    workload = obj(row.get("workload"), f"{context}.workload")
    spec_path = Path(require_safe_path(workload.get("spec_path"), f"{context}.workload.spec_path"))
    require_descendant(spec_path, manifest_root, f"{context}.workload.spec_path")
    privacy = obj(row.get("privacy_scan"), f"{context}.privacy_scan")
    privacy_path = Path(require_safe_path(privacy.get("report_path"), f"{context}.privacy_scan.report_path"))
    require_descendant(privacy_path, manifest_root, f"{context}.privacy_scan.report_path")
    validate_manifest_workload_artifacts(row, manifest_root, spec_path, privacy_path, context)
    validate_manifest_proof_artifacts(row, context)

def validate_manifest_workload_artifacts(row: JsonObject, manifest_root: Path, spec_path: Path, privacy_path: Path, context: str) -> None:
    workload = obj(row.get("workload"), f"{context}.workload")
    scenario_id = text(row.get("scenario_id"), f"{context}.scenario_id")
    expected = require_expected_workload_metadata(scenario_id, context) if scenario_id.startswith("workload-") else expected_workload_metadata(scenario_id)
    workload_class = text(workload.get("name"), f"{context}.workload.name")
    if expected is not None:
        require(workload_class == expected.workload_class, f"{context}.workload.name must match scenario {scenario_id} workload class {expected.workload_class}")
    expected_sha = text(workload.get("spec_sha256"), f"{context}.workload.spec_sha256")
    require(file_sha256(spec_path) == expected_sha, f"{context}.workload.spec_sha256 does not match referenced workload spec")
    spec = load_json(spec_path)
    reject_workload_artifact_private(spec, f"{context}.workload.spec")
    capability_path_value = validate_workload_spec(spec, scenario_id, workload_class, expected, f"{context}.workload.spec", manifest_root)
    if capability_path_value is None:
        raise MatrixRunContractError(f"{context}.workload.spec.capability_artifact_path is required in manifest mode")
    capability_path = Path(capability_path_value)
    require_descendant(capability_path, manifest_root, f"{context}.workload.spec.capability_artifact_path")
    capability = load_json(capability_path)
    reject_workload_artifact_private(capability, f"{context}.workload.capability")
    validate_workload_capability(capability, scenario_id, workload_class, expected, text(row.get("outcome"), f"{context}.outcome"), f"{context}.workload.capability")
    privacy_report = load_json(privacy_path)
    reject_workload_artifact_private(privacy_report, f"{context}.privacy_scan.report")
    validate_privacy_report(privacy_report, f"{context}.privacy_scan.report")
