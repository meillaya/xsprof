#!/usr/bin/env python3
"""Schema/docs, row, fixture, and standalone artifact validators."""
from __future__ import annotations

from pathlib import Path

from qa.matrix_run_json import (
    bool_field,
    file_sha256,
    load_json,
    obj,
    reject_private,
    reject_workload_artifact_private,
    require,
    require_descendant,
    require_identifier,
    require_only_fields,
    require_safe_path,
    require_sha,
    text,
    validate_scheduler_state,
)
from qa.matrix_run_model import (
    AUDIT_RE,
    DOC_FILE,
    EVIDENCE_MODES,
    GIT_FIELDS,
    ID_RE,
    KERNEL_TUPLE_FIELDS,
    MATRIX_BPF_ABI_VERSION,
    OUTCOMES,
    PATH_FIELDS,
    POLICY_FIELDS,
    PRIVACY_SCAN_FIELDS,
    REQUIRED_FIXTURES,
    REQUIRED_INVALID_FIXTURES,
    ROW_FIELDS,
    RUN_ID_RE,
    SAFE_RELATIVE_PATH_PATTERN,
    SCHEMA,
    SCHEMA_FILE,
    SCHEMA_PATH_FIELDS,
    TUPLE_STATUS,
    VM_MARKER,
    VM_MARKER_FIELDS,
    Args,
    JsonObject,
    MatrixRunContractError,
)
from qa.matrix_run_workload import expected_workload_metadata, validate_workload, validate_workload_spec

def validate_schema_file(schemas: Path) -> None:
    schema = load_json(schemas / SCHEMA_FILE)
    require(schema.get("$id") == SCHEMA, f"{SCHEMA_FILE} has wrong $id")
    row_schema = obj(obj(schema.get("properties"), f"{SCHEMA_FILE}.properties").get("schema"), f"{SCHEMA_FILE}.properties.schema")
    require(row_schema.get("const") == SCHEMA, f"{SCHEMA_FILE} row schema const mismatch")
    required = schema.get("required")
    if not isinstance(required, list):
        raise MatrixRunContractError(f"{SCHEMA_FILE}.required must be a list")
    required_names = {item for item in required if isinstance(item, str)}
    missing = sorted(field for field in required_fields() if field not in required_names)
    require(not missing, f"{SCHEMA_FILE} missing required fields: {', '.join(missing)}")
    properties = obj(schema.get("properties"), f"{SCHEMA_FILE}.properties")
    evidence_mode_schema = obj(properties.get("evidence_mode"), f"{SCHEMA_FILE}.properties.evidence_mode")
    evidence_modes = evidence_mode_schema.get("enum")
    if not isinstance(evidence_modes, list):
        raise MatrixRunContractError(f"{SCHEMA_FILE}.properties.evidence_mode.enum must be a list")
    require(frozenset(item for item in evidence_modes if isinstance(item, str)) == EVIDENCE_MODES, f"{SCHEMA_FILE}.properties.evidence_mode.enum must match checker evidence modes")
    bpf_abi_schema = obj(properties.get("bpf_abi_version"), f"{SCHEMA_FILE}.properties.bpf_abi_version")
    require(bpf_abi_schema.get("const") == MATRIX_BPF_ABI_VERSION, f"{SCHEMA_FILE}.properties.bpf_abi_version.const must match checker")
    for path_field in SCHEMA_PATH_FIELDS:
        schema_node = properties
        field_context = ".".join(path_field)
        for segment in path_field:
            schema_node = obj(schema_node.get(segment), f"{SCHEMA_FILE}.properties.{field_context}") if segment == path_field[-1] else obj(obj(schema_node.get(segment), f"{SCHEMA_FILE}.properties.{segment}").get("properties"), f"{SCHEMA_FILE}.properties.{segment}.properties")
        require(schema_node.get("pattern") == SAFE_RELATIVE_PATH_PATTERN, f"{SCHEMA_FILE}.{field_context} missing safe relative path pattern")

def required_fields() -> tuple[str, ...]:
    return tuple(sorted(ROW_FIELDS))

def validate_docs(docs: Path) -> None:
    try:
        text_value = (docs / DOC_FILE).read_text().lower()
    except FileNotFoundError as exc:
        raise MatrixRunContractError(f"missing doc: {docs / DOC_FILE}") from exc
    for needle in (SCHEMA, "standalone", "not a daemon-event", "live-backend", "daemon_event_path", "host_mutation", "release_eligible", "relative", "rollback_proof_path", "cleanup_proof_path", "host_refusal_proof_path", "benchmark_provenance"):
        require(needle.lower() in text_value, f"{DOC_FILE} missing required text: {needle}")

def validate_row(row: JsonObject, context: str) -> None:
    require_only_fields(row, ROW_FIELDS, context)
    require(set(required_fields()).issubset(row), f"{context} missing required fields")
    require(row.get("schema") == SCHEMA, f"{context} bad schema")
    outcome = text(row.get("outcome"), f"{context}.outcome")
    require(outcome in OUTCOMES, f"{context}.outcome invalid")
    mode = text(row.get("evidence_mode"), f"{context}.evidence_mode")
    require(mode in EVIDENCE_MODES, f"{context}.evidence_mode invalid")
    require(text(row.get("supported_tuple_status"), f"{context}.supported_tuple_status") in TUPLE_STATUS, f"{context}.supported_tuple_status invalid")
    require(row.get("host_mutation") is False, f"{context}.host_mutation must be false")
    require(row.get("release_eligible") is False, f"{context}.release_eligible must be false")
    require(row.get("bpf_abi_version") == MATRIX_BPF_ABI_VERSION, f"{context}.bpf_abi_version must be {MATRIX_BPF_ABI_VERSION}")
    require_identifier(row, "matrix_run_id", RUN_ID_RE, context)
    for field in ("scenario_id", "action_id", "rollback_id"):
        require_identifier(row, field, ID_RE, context)
    scenario_id = text(row.get("scenario_id"), f"{context}.scenario_id")
    require_identifier(row, "audit_id", AUDIT_RE, context)
    for field in PATH_FIELDS:
        _ = require_safe_path(row.get(field), f"{context}.{field}")
    pre_enable_seq = validate_scheduler_state(obj(row.get("pre_scheduler_state"), f"{context}.pre_scheduler_state"), f"{context}.pre_scheduler_state")
    post_enable_seq = validate_scheduler_state(obj(row.get("post_scheduler_state"), f"{context}.post_scheduler_state"), f"{context}.post_scheduler_state")
    if pre_enable_seq is not None and post_enable_seq is not None:
        require(post_enable_seq >= pre_enable_seq, f"{context}.post_scheduler_state.enable_seq is stale")
    for field in ("pre_cgroup_state", "post_cgroup_state"):
        _ = obj(row.get(field), f"{context}.{field}")
    kernel_tuple = obj(row.get("kernel_tuple"), f"{context}.kernel_tuple")
    require_only_fields(kernel_tuple, KERNEL_TUPLE_FIELDS, f"{context}.kernel_tuple")
    validate_vm_marker(obj(row.get("vm_marker"), f"{context}.vm_marker"), mode, context)
    validate_policy(obj(row.get("policy"), f"{context}.policy"), context)
    validate_workload(obj(row.get("workload"), f"{context}.workload"), scenario_id, context)
    validate_privacy(obj(row.get("privacy_scan"), f"{context}.privacy_scan"), context)
    validate_git(obj(row.get("git"), f"{context}.git"), context)
    validate_pass_evidence_mode(outcome, mode, context)
    reject_private(row, context)

def validate_vm_marker(marker: JsonObject, mode: str, context: str) -> None:
    require_only_fields(marker, VM_MARKER_FIELDS, f"{context}.vm_marker")
    required = bool_field(marker.get("required"), f"{context}.vm_marker.required")
    present = bool_field(marker.get("present"), f"{context}.vm_marker.present")
    require(text(marker.get("path"), f"{context}.vm_marker.path") == VM_MARKER, f"{context}.vm_marker.path mismatch")
    _ = text(marker.get("checked_by"), f"{context}.vm_marker.checked_by")
    if mode == "vm-live":
        require(required and present, f"{context} VM-live row requires present VM marker")
    elif mode in {"host-refusal-only", "fixture"}:
        require(not required and not present, f"{context} {mode} row must not claim VM marker")
    else:
        raise MatrixRunContractError(f"{context}.evidence_mode invalid")

def validate_pass_evidence_mode(outcome: str, mode: str, context: str) -> None:
    if outcome == "PASS":
        require(mode in {"vm-live", "fixture"}, f"{context} PASS requires vm-live proof or explicit fixture evidence")

def validate_policy(policy: JsonObject, context: str) -> None:
    require_only_fields(policy, POLICY_FIELDS, f"{context}.policy")
    for field in ("name", "object_path", "source_path"):
        _ = text(policy.get(field), f"{context}.policy.{field}")
    _ = require_safe_path(policy.get("object_path"), f"{context}.policy.object_path")
    _ = require_safe_path(policy.get("source_path"), f"{context}.policy.source_path")
    require_sha(policy, "object_sha256", f"{context}.policy")
    require_sha(policy, "source_sha256", f"{context}.policy")

def validate_privacy(scan: JsonObject, context: str) -> None:
    require_only_fields(scan, PRIVACY_SCAN_FIELDS, f"{context}.privacy_scan")
    require(scan.get("status") == "PASS", f"{context}.privacy_scan.status must be PASS")
    require(scan.get("private_fields_found") is False, f"{context}.privacy_scan.private_fields_found must be false")
    _ = require_safe_path(scan.get("report_path"), f"{context}.privacy_scan.report_path")

def validate_git(git: JsonObject, context: str) -> None:
    require_only_fields(git, GIT_FIELDS, f"{context}.git")
    expected = text(git.get("expected_sha"), f"{context}.git.expected_sha")
    actual = text(git.get("actual_sha"), f"{context}.git.actual_sha")
    require(git.get("status") == "current", f"{context}.git.status must be current")
    require(git.get("dirty") is False, f"{context}.git.dirty must be false")
    require(expected == actual, f"{context}.git expected_sha must match actual_sha")

def fixture_names(path: Path) -> set[str]:
    return {child.name for child in path.glob("*.json") if child.is_file()}

def validate_fixture_pack(fixtures: Path) -> tuple[int, int]:
    valid_names = fixture_names(fixtures)
    missing = sorted(REQUIRED_FIXTURES - valid_names)
    extra = sorted(valid_names - REQUIRED_FIXTURES)
    require(not missing, "missing matrix-run fixture(s): " + ", ".join(missing))
    require(not extra, "unlisted matrix-run fixture(s): " + ", ".join(extra))
    for name in sorted(REQUIRED_FIXTURES):
        row = load_json(fixtures / name)
        validate_row(row, str(fixtures / name))
        validate_workload_fixture_artifacts(row, fixtures, name)
    invalid_dir = fixtures / "invalid"
    invalid_names = fixture_names(invalid_dir)
    missing_invalid = sorted(REQUIRED_INVALID_FIXTURES - invalid_names)
    extra_invalid = sorted(invalid_names - REQUIRED_INVALID_FIXTURES)
    require(not missing_invalid, "missing invalid fixture(s): " + ", ".join(missing_invalid))
    require(not extra_invalid, "unlisted invalid fixture(s): " + ", ".join(extra_invalid))
    for name in sorted(REQUIRED_INVALID_FIXTURES):
        try:
            validate_row(load_json(invalid_dir / name), str(invalid_dir / name))
        except MatrixRunContractError:
            continue
        raise MatrixRunContractError(f"invalid fixture was accepted: {invalid_dir / name}")
    return len(valid_names), len(invalid_names)

def validate_workload_fixture_artifacts(row: JsonObject, fixtures: Path, fixture_name: str) -> None:
    scenario_id = text(row.get("scenario_id"), f"{fixtures / fixture_name}.scenario_id")
    expected = expected_workload_metadata(scenario_id)
    if expected is None:
        return
    require(fixture_name == f"{scenario_id}.json", f"{fixtures / fixture_name} filename must match workload scenario_id")
    workload = obj(row.get("workload"), f"{fixtures / fixture_name}.workload")
    workload_class = text(workload.get("name"), f"{fixtures / fixture_name}.workload.name")
    require(workload_class == expected.workload_class, f"{fixtures / fixture_name}.workload.name must match scenario workload class")
    spec_path = Path(require_safe_path(workload.get("spec_path"), f"{fixtures / fixture_name}.workload.spec_path"))
    require_descendant(spec_path, fixtures, f"{fixtures / fixture_name}.workload.spec_path")
    expected_sha = text(workload.get("spec_sha256"), f"{fixtures / fixture_name}.workload.spec_sha256")
    require(file_sha256(spec_path) == expected_sha, f"{fixtures / fixture_name}.workload.spec_sha256 does not match referenced workload spec")
    spec = load_json(spec_path)
    reject_workload_artifact_private(spec, f"{fixtures / fixture_name}.workload.spec")
    capability_path_value = validate_workload_spec(spec, scenario_id, workload_class, expected, f"{fixtures / fixture_name}.workload.spec")
    require(capability_path_value is None, f"{fixtures / fixture_name}.workload.spec.capability_artifact_path must not be committed in fixture specs")

def validate(args: Args) -> tuple[int, int]:
    validate_schema_file(args.schemas)
    validate_docs(args.docs)
    if args.fixtures is None:
        raise MatrixRunContractError("internal argument parser error")
    return validate_fixture_pack(args.fixtures)
