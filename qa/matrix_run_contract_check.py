#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
# ─── How to run ───
# noqa: SIZE_OK — integration gate driver intentionally keeps schema/docs/fixture/manifest dereference checks in one audited fail-closed entrypoint; split next by moving manifest artifact validators and self-test case builders.
# python3 qa/matrix_run_contract_check.py --fixtures fixtures/matrix-run --schemas schemas/control --docs docs/control
from __future__ import annotations

import argparse
from contextlib import suppress
import hashlib
import json
import re
import shutil
from collections.abc import Callable
import sys
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tempfile import TemporaryDirectory
from typing import TYPE_CHECKING, Final, NoReturn, Protocol, TypeAlias

from qa.daemon_event_contract_check import ContractError as DaemonEventContractError
from qa.daemon_event_contract_check import validate as validate_daemon_event_stream
from qa.matrix_benchmark_provenance import MatrixBenchmarkProvenanceError
from qa.matrix_benchmark_provenance import validate_entries as validate_benchmark_provenance_entries
from qa.matrix_benchmark_provenance_selftest import BENCHMARK_PROVENANCE_SELF_TEST_CASES
from qa.matrix_benchmark_provenance_selftest import MatrixBenchmarkSelfTestError
from qa.matrix_benchmark_provenance_selftest import apply_case as apply_benchmark_provenance_self_test_case
from qa.runtime_sample_check import RuntimeSampleError, good_sample as runtime_good_sample
from qa.runtime_sample_check import validate_file as validate_runtime_sample_file

JsonValue: TypeAlias = None | bool | int | float | str | list["JsonValue"] | dict[str, "JsonValue"]
JsonObject: TypeAlias = dict[str, JsonValue]

SCHEMA: Final = "zig-scheduler/matrix-run/v1"
SCHEMA_FILE: Final = "matrix-run.v1.schema.json"
DOC_FILE: Final = "matrix-run-contract.md"
VM_MARKER: Final = "/run/zig-scheduler-vm-lab.marker"
OUTCOMES: Final = frozenset({"PASS", "SKIP", "REFUSE", "INCIDENT", "FAIL"})
EVIDENCE_MODES: Final = frozenset({"vm-live", "host-refusal-only", "fixture"})
TUPLE_STATUS: Final = frozenset({"supported", "unsupported", "unknown"})
REQUIRED_FIXTURES: Final = frozenset({"pass.json", "live-backend.json", "skip-unsupported-tuple.json", "host-refusal-only.json", "incident-verifier-reject.json", "rollback-failure.json", "cleanup-residue.json", "workload-cpu-saturation.json", "workload-interactive-latency.json", "workload-scheduler-affinity-churn.json", "workload-fork-ipc-pressure.json", "workload-mixed-io.json", "workload-cgroup-weight-quota.json", "workload-cpu-hotplug.json"})
REQUIRED_INVALID_FIXTURES: Final = frozenset({"host-mutation-true.json", "release-eligible-true.json", "invalid-outcome.json", "stale-git.json", "dirty-git.json", "missing-vm-marker.json", "unsafe-absolute-path.json", "unsafe-traversal-path.json", "missing-rollback-proof.json", "missing-cleanup-proof.json", "missing-cleanup-proof-on-skip.json", "missing-cleanup-proof-on-refuse.json", "missing-host-refusal-proof.json", "privacy-failed.json", "malformed.json", "extra-property.json"})
PATH_FIELDS: Final = ("runtime_sample_path", "daemon_event_path", "incident_path", "rollback_proof_path", "cleanup_proof_path", "host_refusal_proof_path")
ROW_FIELDS: Final = frozenset(("schema", "matrix_run_id", "scenario_id", "outcome", "evidence_mode", "kernel_tuple", "supported_tuple_status", "vm_marker", "bpf_abi_version", "policy", "workload", "action_id", "audit_id", "rollback_id", "pre_scheduler_state", "post_scheduler_state", "pre_cgroup_state", "post_cgroup_state", "runtime_sample_path", "daemon_event_path", "incident_path", "rollback_proof_path", "cleanup_proof_path", "host_refusal_proof_path", "privacy_scan", "git", "release_eligible", "host_mutation"))
KERNEL_TUPLE_FIELDS: Final = frozenset(("kernel_release", "arch", "btf", "kvm", "sched_ext"))
VM_MARKER_FIELDS: Final = frozenset(("required", "present", "path", "checked_by"))
POLICY_FIELDS: Final = frozenset(("name", "object_path", "object_sha256", "source_path", "source_sha256"))
WORKLOAD_FIELDS: Final = frozenset(("name", "spec_path", "spec_sha256"))
PRIVACY_SCAN_FIELDS: Final = frozenset(("status", "private_fields_found", "report_path"))
GIT_FIELDS: Final = frozenset(("expected_sha", "actual_sha", "status", "dirty"))
MANIFEST_ROW_FIELDS: Final = frozenset(("scenario_id", "outcome", "artifact_path", "reason"))
MANIFEST_FIELDS: Final = frozenset(("schema", "matrix_run_id", "mode", "fixture_mode", "started_at", "ended_at", "out_dir", "daemon_events_path", "row_count", "rows", "host_mutation", "release_eligible"))
MATRIX_BASE: Final = Path("evidence/lab/matrix")
MANIFEST_FILE: Final = "manifest.json"
RUN_ID_MAX: Final = 64
RUN_ID_RE: Final = re.compile(r"^[A-Za-z0-9_.-]{1,64}$")
ID_RE: Final = re.compile(r"^[A-Za-z0-9_.-]{1,96}$")
AUDIT_RE: Final = re.compile(r"^AUD-[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9_.-]+$")
SHA256_RE: Final = re.compile(r"^[0-9a-f]{64}$")
SAFE_RELATIVE_PATH_PATTERN: Final = r"^(?!/)(?!.*(?:^|/)\.\.(?:/|$)).+$"
SCHEMA_PATH_FIELDS: Final = (("runtime_sample_path",), ("daemon_event_path",), ("incident_path",), ("rollback_proof_path",), ("cleanup_proof_path",), ("host_refusal_proof_path",), ("policy", "object_path"), ("policy", "source_path"), ("workload", "spec_path"), ("privacy_scan", "report_path"))
PRIVATE_NEEDLES: Final = ("cmdline", "command_line", "argv", "environment", "secret", "api_key", "token", "password", "authorization", "bearer")
WORKLOAD_PRIVATE_NEEDLES: Final = PRIVATE_NEEDLES + ("command", "env", "cwd", "pid", "ppid")
PRIVATE_PATH_RE: Final = re.compile(r"(^|[\s=:])/(?:home|root|etc|proc|sys|var|tmp)/")
CLAIM_TEXT_RE: Final = re.compile(r"\b(?:production|release|performance)[\s_-]+(?:ready|eligible|approved|claim|slo|sla|guarantee|baseline|capacity)\b", re.IGNORECASE)
WORKLOAD_SPEC_SCHEMA: Final = "zig-scheduler/workload-fixture/v1"
WORKLOAD_CAPABILITY_SCHEMA: Final = "zig-scheduler/workload-capability/v1"
PRIVACY_SCAN_SCHEMA: Final = "zig-scheduler/privacy-scan/v1"
PRIVACY_REPORT_FIELDS: Final = frozenset(("schema", "status", "private_fields_found", "host_mutation"))
INCIDENT_FIELDS: Final = frozenset(("schema", "scenario_id", "outcome", "reason", "host_mutation", "release_eligible"))
ROLLBACK_PROOF_FIELDS: Final = frozenset(("schema", "scenario_id", "status", "scheduler_state", "ops", "host_mutation"))
CLEANUP_PROOF_FIELDS: Final = frozenset(("schema", "scenario_id", "status", "owned_qemu_leftovers", "owned_temp_leftovers", "qemu_scan_before", "qemu_scan_after", "temp_scan_before", "temp_scan_after", "host_mutation"))
HOST_REFUSAL_FIELDS: Final = frozenset(("schema", "scenario_id", "status", "reason", "no_bpf_load_attach", "no_cgroup_write", "no_sys_write", "no_proc_write", "host_mutation"))
VM_MARKER_PROOF_FIELDS: Final = frozenset(("schema", "path", "required", "present", "evidence_mode", "host_mutation"))
WORKLOAD_SPEC_FIELDS: Final = frozenset(("schema", "name", "workload_class", "scenario_id", "required_tools", "threshold_source", "thresholds", "benchmark_provenance", "capability_artifact_path", "runner", "vm_marker_required_for_live_run", "host_safe_fixture_only", "missing_prereq", "host_mutation", "release_eligible"))
WORKLOAD_THRESHOLD_FIELDS: Final = frozenset(("source", "fixture_status", "calibration_status", "production_capacity_claim"))
WORKLOAD_CAPABILITY_FIELDS: Final = frozenset(("schema", "scenario_id", "workload_class", "required_tools", "threshold_source", "mode", "status", "typed_outcome", "missing_prereq", "vm_marker_required_for_live_run", "fixture_mode", "runner", "host_mutation", "release_eligible"))
WORKLOAD_TOOL_NAMES: Final = frozenset(("stress-ng", "cyclictest", "perf", "taskset", "chrt", "hackbench-like", "fio", "cpu-hotplug-online-control", "builtin-churn"))
WORKLOAD_THRESHOLD_SOURCES: Final = frozenset(("fixture", "calibrated", "deferred", "record-only", "uncalibrated"))
WORKLOAD_CAPABILITY_MODES: Final = frozenset(("host-safe", "auto", "vm-required"))


@dataclass(frozen=True, slots=True)
class Args:
    fixtures: Path | None
    schemas: Path
    docs: Path
    manifest: Path | None
    self_test: bool


@dataclass(frozen=True, slots=True)
class WorkloadScenarioMetadata:
    scenario_id: str
    workload_class: str
    required_tools: tuple[str, ...]
    threshold_sources: frozenset[str]


class MatrixRunContractError(Exception):
    pass


class JsonLoader(Protocol):
    def loads(self, text: str, *, parse_constant: Callable[[str], NoReturn]) -> JsonValue: ...


class ParsedArgs(argparse.Namespace):
    fixtures: Path | None
    schemas: Path
    docs: Path
    manifest: Path | None

    def __init__(self) -> None:
        super().__init__()
        self.fixtures = None
        self.schemas = Path()
        self.docs = Path()
        self.manifest = None


if TYPE_CHECKING:
    json_loader: JsonLoader
else:
    json_loader = json


WORKLOAD_SCENARIO_METADATA: Final = {
    "workload-cpu-saturation": WorkloadScenarioMetadata("workload-cpu-saturation", "cpu-saturation", ("stress-ng",), frozenset({"record-only"})),
    "workload-interactive-latency": WorkloadScenarioMetadata("workload-interactive-latency", "interactive-latency", ("cyclictest", "perf"), frozenset({"record-only"})),
    "workload-scheduler-affinity-churn": WorkloadScenarioMetadata("workload-scheduler-affinity-churn", "scheduler-affinity-churn", ("stress-ng", "taskset", "chrt"), frozenset({"record-only"})),
    "workload-fork-ipc-pressure": WorkloadScenarioMetadata("workload-fork-ipc-pressure", "bounded-fork-ipc-pressure", ("hackbench-like",), frozenset({"record-only"})),
    "workload-mixed-io": WorkloadScenarioMetadata("workload-mixed-io", "mixed-io", ("fio",), frozenset({"record-only"})),
    "workload-cgroup-weight-quota": WorkloadScenarioMetadata("workload-cgroup-weight-quota", "cgroup-weight-quota-pressure", ("stress-ng",), frozenset({"record-only"})),
    "workload-cpu-hotplug": WorkloadScenarioMetadata("workload-cpu-hotplug", "cpu-hotplug-offline", ("cpu-hotplug-online-control",), frozenset({"record-only"})),
}


def parse_args(argv: list[str]) -> Args:
    if argv == ["--self-test"]:
        return Args(Path("fixtures/matrix-run"), Path("schemas/control"), Path("docs/control"), None, True)
    parser = argparse.ArgumentParser(description="Validate standalone matrix-run/v1 evidence manifests.")
    _ = parser.add_argument("--fixtures", type=Path)
    _ = parser.add_argument("--manifest", type=Path)
    _ = parser.add_argument("--schemas", required=True, type=Path)
    _ = parser.add_argument("--docs", required=True, type=Path)
    parsed = parser.parse_args(argv, namespace=ParsedArgs())
    if (parsed.fixtures is None) == (parsed.manifest is None):
        raise MatrixRunContractError("exactly one of --fixtures or --manifest is required")
    return Args(parsed.fixtures, parsed.schemas, parsed.docs, parsed.manifest, False)


def reject_constant(value: str) -> NoReturn:
    raise MatrixRunContractError(f"invalid JSON constant: {value}")


def load_json(path: Path) -> JsonObject:
    try:
        raw = json_loader.loads(path.read_text(), parse_constant=reject_constant)
    except FileNotFoundError as exc:
        raise MatrixRunContractError(f"missing JSON file: {path}") from exc
    except json.JSONDecodeError as exc:
        raise MatrixRunContractError(f"invalid JSON in {path} at byte {exc.pos}: {exc.msg}") from exc
    return obj(raw, str(path))


def obj(value: JsonValue | None, context: str) -> JsonObject:
    if not isinstance(value, dict):
        raise MatrixRunContractError(f"{context} must be an object")
    return value


def text(value: JsonValue | None, context: str) -> str:
    if not isinstance(value, str) or value == "":
        raise MatrixRunContractError(f"{context} must be non-empty text")
    return value


def bool_field(value: JsonValue | None, context: str) -> bool:
    if not isinstance(value, bool):
        raise MatrixRunContractError(f"{context} must be a boolean")
    return value


def require(condition: bool, message: str) -> None:
    if not condition:
        raise MatrixRunContractError(message)


def require_only_fields(row: JsonObject, allowed: frozenset[str], context: str) -> None:
    extra = sorted(set(row) - allowed)
    require(not extra, f"{context} has unexpected field(s): {', '.join(extra)}")


def reject_private(value: JsonValue, context: str) -> None:
    match value:  # noqa: MATCH_OK — JsonValue cases are exhausted; pyright reports an assert_never default as unreachable.
        case dict():
            for key, child in value.items():
                lowered = key.lower()
                require(not any(needle in lowered for needle in PRIVATE_NEEDLES), f"privacy-unsafe key in {context}.{key}")
                reject_private(child, f"{context}.{key}")
        case list():
            for index, child in enumerate(value):
                reject_private(child, f"{context}[{index}]")
        case str():
            lowered = value.lower()
            require(not any(needle in lowered for needle in PRIVATE_NEEDLES), f"privacy-unsafe text in {context}")
        case None | bool() | int() | float():
            return


def reject_workload_artifact_private(value: JsonValue, context: str) -> None:
    match value:  # noqa: MATCH_OK — JsonValue cases are exhausted; pyright reports an assert_never default as unreachable.
        case dict():
            for key, child in value.items():
                lowered = key.lower()
                require(not any(needle in lowered for needle in WORKLOAD_PRIVATE_NEEDLES), f"privacy-unsafe workload key in {context}.{key}")
                reject_workload_artifact_private(child, f"{context}.{key}")
        case list():
            for index, child in enumerate(value):
                reject_workload_artifact_private(child, f"{context}[{index}]")
        case str():
            lowered = value.lower()
            require(not any(needle in lowered for needle in WORKLOAD_PRIVATE_NEEDLES), f"privacy-unsafe workload text in {context}")
            require(CLAIM_TEXT_RE.search(value) is None, f"claim-unsafe workload text in {context}")
            require(PRIVATE_PATH_RE.search(value) is None, f"privacy-unsafe workload path in {context}")
        case None | bool() | int() | float():
            return


def require_safe_path(value: JsonValue | None, context: str) -> str:
    raw = text(value, context)
    path = Path(raw)
    require(not path.is_absolute() and ".." not in path.parts, f"{context} must be relative and non-traversing: {raw}")
    return raw


def require_manifest_root(manifest_path: Path) -> Path:
    require(not manifest_path.is_absolute() and ".." not in manifest_path.parts, "--manifest must be relative and non-traversing")
    parts = manifest_path.parts
    require(len(parts) == 5 and parts[:3] == MATRIX_BASE.parts and parts[4] == MANIFEST_FILE, f"--manifest must be {MATRIX_BASE}/<run-id>/{MANIFEST_FILE}: {manifest_path}")
    require(RUN_ID_RE.fullmatch(parts[3]) is not None, f"--manifest run id must be 1-{RUN_ID_MAX} safe characters: {parts[3]}")
    return Path(*parts[:4])


def require_descendant(path: Path, root: Path, context: str) -> None:
    require(path == root or path.parts[: len(root.parts)] == root.parts, f"{context} must stay under {root}: {path}")


def require_identifier(row: JsonObject, field: str, pattern: re.Pattern[str], context: str) -> None:
    raw = text(row.get(field), f"{context}.{field}")
    require(pattern.fullmatch(raw) is not None, f"{context}.{field} is not a stable identifier")


def require_sha(row: JsonObject, field: str, context: str) -> None:
    raw = text(row.get(field), f"{context}.{field}")
    require(SHA256_RE.fullmatch(raw) is not None, f"{context}.{field} must be sha256 hex")


def file_sha256(path: Path) -> str:
    try:
        return hashlib.sha256(path.read_bytes()).hexdigest()
    except FileNotFoundError as exc:
        raise MatrixRunContractError(f"missing referenced artifact: {path}") from exc


def text_list(value: JsonValue | None, context: str) -> list[str]:
    if not isinstance(value, list):
        raise MatrixRunContractError(f"{context} must be a list")
    items: list[str] = []
    for index, item in enumerate(value):
        items.append(text(item, f"{context}[{index}]"))
    return items


def expected_workload_metadata(scenario_id: str) -> WorkloadScenarioMetadata | None:
    return WORKLOAD_SCENARIO_METADATA.get(scenario_id)


def require_expected_workload_metadata(scenario_id: str, context: str) -> WorkloadScenarioMetadata:
    expected = expected_workload_metadata(scenario_id)
    if expected is None:
        raise MatrixRunContractError(f"{context}.scenario_id has no canonical workload metadata: {scenario_id}")
    return expected


def require_expected_tools(tools: list[str], expected: WorkloadScenarioMetadata, context: str) -> None:
    actual = set(tools)
    expected_tools = set(expected.required_tools)
    require(len(actual) == len(tools), f"{context} must not contain duplicate tools")
    require(actual == expected_tools, f"{context} must match scenario {expected.scenario_id} required tools: {', '.join(expected.required_tools)}")


def require_expected_threshold_source(source: str, expected: WorkloadScenarioMetadata, context: str) -> None:
    require(source in expected.threshold_sources, f"{context} must match scenario {expected.scenario_id} threshold_source: {', '.join(sorted(expected.threshold_sources))}")


def require_expected_missing_prereq(missing: str, expected: WorkloadScenarioMetadata, context: str) -> None:
    require(missing == "" or missing in set(expected.required_tools), f"{context} must be empty or one of scenario {expected.scenario_id} required tools: {', '.join(expected.required_tools)}")


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
    require_identifier(row, "matrix_run_id", RUN_ID_RE, context)
    for field in ("scenario_id", "action_id", "rollback_id"):
        require_identifier(row, field, ID_RE, context)
    scenario_id = text(row.get("scenario_id"), f"{context}.scenario_id")
    require_identifier(row, "audit_id", AUDIT_RE, context)
    for field in PATH_FIELDS:
        _ = require_safe_path(row.get(field), f"{context}.{field}")
    for field in ("pre_scheduler_state", "post_scheduler_state", "pre_cgroup_state", "post_cgroup_state"):
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


def validate_workload(workload: JsonObject, scenario_id: str, context: str) -> None:
    require_only_fields(workload, WORKLOAD_FIELDS, f"{context}.workload")
    workload_name = text(workload.get("name"), f"{context}.workload.name")
    _ = require_safe_path(workload.get("spec_path"), f"{context}.workload.spec_path")
    require_sha(workload, "spec_sha256", f"{context}.workload")
    expected = require_expected_workload_metadata(scenario_id, context) if scenario_id.startswith("workload-") else expected_workload_metadata(scenario_id)
    if expected is not None:
        require(workload_name == expected.workload_class, f"{context}.workload.name must match scenario {scenario_id} workload class {expected.workload_class}")


def require_workload_tools(value: JsonValue | None, context: str) -> list[str]:
    tools = text_list(value, context)
    require(bool(tools), f"{context} must not be empty")
    for tool in tools:
        require(tool in WORKLOAD_TOOL_NAMES, f"{context} has unsafe tool name: {tool}")
    return tools


def validate_workload_thresholds(thresholds: JsonObject, source: str, context: str) -> None:
    require_only_fields(thresholds, WORKLOAD_THRESHOLD_FIELDS, context)
    require(thresholds.get("source") == source, f"{context}.source must match threshold_source")
    _ = text(thresholds.get("fixture_status"), f"{context}.fixture_status")
    _ = text(thresholds.get("calibration_status"), f"{context}.calibration_status")
    require(thresholds.get("production_capacity_claim") is False, f"{context}.production_capacity_claim must be false")


def validate_workload_benchmark_provenance(value: JsonValue | None, manifest_root: Path | None, context: str) -> None:
    try:
        validate_benchmark_provenance_entries(value, manifest_root, context)
    except MatrixBenchmarkProvenanceError as exc:
        raise MatrixRunContractError(str(exc)) from exc


def validate_workload_spec(spec: JsonObject, scenario_id: str, workload_class: str, expected: WorkloadScenarioMetadata | None, context: str, manifest_root: Path | None = None) -> str | None:
    require_only_fields(spec, WORKLOAD_SPEC_FIELDS, context)
    require({"schema", "workload_class", "scenario_id", "required_tools", "threshold_source", "thresholds", "vm_marker_required_for_live_run", "host_mutation", "release_eligible"}.issubset(spec), f"{context} missing required workload spec fields")
    require(spec.get("schema") == WORKLOAD_SPEC_SCHEMA, f"{context}.schema unsupported")
    require(spec.get("scenario_id") == scenario_id, f"{context}.scenario_id must match row scenario")
    require(spec.get("workload_class") == workload_class, f"{context}.workload_class must match row workload name")
    if "name" in spec:
        require(spec.get("name") == workload_class, f"{context}.name must match workload_class")
    tools = require_workload_tools(spec.get("required_tools"), f"{context}.required_tools")
    if expected is not None:
        require_expected_tools(tools, expected, f"{context}.required_tools")
    threshold_source = text(spec.get("threshold_source"), f"{context}.threshold_source")
    require(threshold_source in WORKLOAD_THRESHOLD_SOURCES, f"{context}.threshold_source invalid")
    if expected is not None:
        require_expected_threshold_source(threshold_source, expected, f"{context}.threshold_source")
    validate_workload_thresholds(obj(spec.get("thresholds"), f"{context}.thresholds"), threshold_source, f"{context}.thresholds")
    benchmark_provenance = spec.get("benchmark_provenance")
    if threshold_source == "calibrated":
        require(benchmark_provenance is not None, f"{context}.benchmark_provenance required when threshold_source is calibrated")
    validate_workload_benchmark_provenance(benchmark_provenance, manifest_root, f"{context}.benchmark_provenance")
    require(spec.get("vm_marker_required_for_live_run") is True, f"{context}.vm_marker_required_for_live_run must be true")
    require(spec.get("host_mutation") is False, f"{context}.host_mutation must be false")
    require(spec.get("release_eligible") is False, f"{context}.release_eligible must be false")
    if "missing_prereq" in spec:
        missing = spec.get("missing_prereq")
        if not isinstance(missing, str):
            raise MatrixRunContractError(f"{context}.missing_prereq must be text")
        require(missing == "" or missing in WORKLOAD_TOOL_NAMES, f"{context}.missing_prereq has unsafe tool name")
        if expected is not None:
            require_expected_missing_prereq(missing, expected, f"{context}.missing_prereq")
    if "capability_artifact_path" in spec:
        return require_safe_path(spec.get("capability_artifact_path"), f"{context}.capability_artifact_path")
    return None


def validate_workload_capability(capability: JsonObject, scenario_id: str, workload_class: str, expected: WorkloadScenarioMetadata | None, row_outcome: str, context: str) -> None:
    require_only_fields(capability, WORKLOAD_CAPABILITY_FIELDS, context)
    require({"schema", "scenario_id", "workload_class", "required_tools", "threshold_source", "mode", "status", "typed_outcome", "missing_prereq", "vm_marker_required_for_live_run", "host_mutation", "release_eligible"}.issubset(capability), f"{context} missing required workload capability fields")
    require(capability.get("schema") == WORKLOAD_CAPABILITY_SCHEMA, f"{context}.schema unsupported")
    require(capability.get("scenario_id") == scenario_id, f"{context}.scenario_id must match row scenario")
    require(capability.get("workload_class") == workload_class, f"{context}.workload_class must match row workload name")
    tools = require_workload_tools(capability.get("required_tools"), f"{context}.required_tools")
    if expected is not None:
        require_expected_tools(tools, expected, f"{context}.required_tools")
    threshold_source = text(capability.get("threshold_source"), f"{context}.threshold_source")
    require(threshold_source in WORKLOAD_THRESHOLD_SOURCES, f"{context}.threshold_source invalid")
    if expected is not None:
        require_expected_threshold_source(threshold_source, expected, f"{context}.threshold_source")
    mode = text(capability.get("mode"), f"{context}.mode")
    require(mode in WORKLOAD_CAPABILITY_MODES, f"{context}.mode invalid")
    status = text(capability.get("status"), f"{context}.status")
    require(status in OUTCOMES, f"{context}.status invalid")
    require(status == row_outcome, f"{context}.status must match row outcome")
    typed_outcome = text(capability.get("typed_outcome"), f"{context}.typed_outcome")
    require(typed_outcome in OUTCOMES, f"{context}.typed_outcome invalid")
    require(typed_outcome == row_outcome, f"{context}.typed_outcome must match row outcome")
    missing = text(capability.get("missing_prereq"), f"{context}.missing_prereq") if capability.get("missing_prereq") != "" else ""
    require(missing == "" or missing in WORKLOAD_TOOL_NAMES, f"{context}.missing_prereq has unsafe tool name")
    if expected is not None:
        require_expected_missing_prereq(missing, expected, f"{context}.missing_prereq")
        if row_outcome == "PASS":
            require(missing == "", f"{context}.missing_prereq must be empty for PASS")
        elif row_outcome == "SKIP":
            require(missing != "", f"{context}.missing_prereq must name the missing scenario tool for SKIP")
        elif row_outcome == "REFUSE":
            pass
        else:
            require(missing == "", f"{context}.missing_prereq must be empty unless outcome is SKIP or REFUSE")
    require(capability.get("vm_marker_required_for_live_run") is True, f"{context}.vm_marker_required_for_live_run must be true")
    require(capability.get("host_mutation") is False, f"{context}.host_mutation must be false")
    require(capability.get("release_eligible") is False, f"{context}.release_eligible must be false")


def validate_privacy_report(report: JsonObject, context: str) -> None:
    require_only_fields(report, PRIVACY_REPORT_FIELDS, context)
    require(report.get("schema") == PRIVACY_SCAN_SCHEMA, f"{context}.schema unsupported")
    require(report.get("status") == "PASS", f"{context}.status must be PASS")
    require(report.get("private_fields_found") is False, f"{context}.private_fields_found must be false")
    require(report.get("host_mutation") is False, f"{context}.host_mutation must be false")


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
    if args.manifest is not None:
        return validate_manifest(args.manifest)
    if args.fixtures is None:
        raise MatrixRunContractError("internal argument parser error")
    return validate_fixture_pack(args.fixtures)


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


def validate_live_backend_summary_consistency(row: JsonObject, artifact_path: Path, context: str) -> None:
    scenario_id = text(row.get("scenario_id"), f"{context}.scenario_id")
    if scenario_id != "live-backend":
        return
    backend_summary_path = artifact_path.parent / "backend" / "summary.json"
    if not backend_summary_path.is_file():
        return
    backend_summary = load_json(backend_summary_path)
    live_summary_value = backend_summary.get("live_summary")
    if not isinstance(live_summary_value, str):
        return
    live_summary_path = Path(live_summary_value)
    if not live_summary_path.is_file():
        return
    live_summary = load_json(live_summary_path)
    outcome = text(row.get("outcome"), f"{context}.outcome")
    evidence_mode = text(row.get("evidence_mode"), f"{context}.evidence_mode")
    if live_summary.get("git_dirty") is True:
        require(outcome != "PASS" and evidence_mode != "vm-live", f"{context} dirty live backend summary cannot back a PASS vm-live matrix row")
    live_git_sha = live_summary.get("git_sha")
    git = obj(row.get("git"), f"{context}.git")
    actual_sha = text(git.get("actual_sha"), f"{context}.git.actual_sha")
    if isinstance(live_git_sha, str) and live_git_sha and not live_git_sha.startswith(actual_sha):
        require(outcome != "PASS" and evidence_mode != "vm-live", f"{context} stale live backend summary cannot back a PASS vm-live matrix row")


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


def write_json(path: Path, value: JsonObject) -> None:
    _ = path.write_text(json.dumps(value, sort_keys=True))


def write_json_digest(path: Path, value: JsonObject) -> str:
    write_json(path, value)
    return file_sha256(path)


def without_field(row: JsonObject, field: str) -> JsonObject:
    copy = dict(row)
    del copy[field]
    return copy


def invalid_self_test_rows(good: JsonObject) -> dict[str, JsonObject | str]:
    host_mutation = dict(good)
    host_mutation["host_mutation"] = True
    release_eligible = dict(good)
    release_eligible["release_eligible"] = True
    invalid_outcome = dict(good)
    invalid_outcome["outcome"] = "SUCCESS"
    stale_git = dict(good)
    stale_git["git"] = {"expected_sha": "302cead", "actual_sha": "deadbee", "status": "stale", "dirty": False}
    dirty_git = dict(good)
    dirty_git["git"] = {"expected_sha": "302cead", "actual_sha": "302cead", "status": "current", "dirty": True}
    missing_marker = dict(good)
    missing_marker["vm_marker"] = {"required": True, "present": False, "path": VM_MARKER, "checked_by": "self-test"}
    absolute_path = dict(good)
    absolute_path["runtime_sample_path"] = "/tmp/runtime-sample.jsonl"
    traversal_path = dict(good)
    traversal_path["incident_path"] = "evidence/../incident.json"
    privacy_failed = dict(good)
    privacy_failed["privacy_scan"] = {"status": "PASS", "private_fields_found": True, "report_path": "evidence/lab/privacy.json"}
    skip_without_cleanup = dict(good)
    skip_without_cleanup["outcome"] = "SKIP"
    skip_without_cleanup["supported_tuple_status"] = "unsupported"
    refuse_without_cleanup = dict(good)
    refuse_without_cleanup["outcome"] = "REFUSE"
    refuse_without_cleanup["evidence_mode"] = "host-refusal-only"
    refuse_without_cleanup["vm_marker"] = {"required": False, "present": False, "path": VM_MARKER, "checked_by": "self-test"}
    extra_property = dict(good)
    extra_property["unexpected_field_not_in_schema"] = "must be rejected"
    return {
        "host-mutation-true.json": host_mutation,
        "release-eligible-true.json": release_eligible,
        "invalid-outcome.json": invalid_outcome,
        "stale-git.json": stale_git,
        "dirty-git.json": dirty_git,
        "missing-vm-marker.json": missing_marker,
        "unsafe-absolute-path.json": absolute_path,
        "unsafe-traversal-path.json": traversal_path,
        "missing-rollback-proof.json": without_field(good, "rollback_proof_path"),
        "missing-cleanup-proof.json": without_field(good, "cleanup_proof_path"),
        "missing-cleanup-proof-on-skip.json": without_field(skip_without_cleanup, "cleanup_proof_path"),
        "missing-cleanup-proof-on-refuse.json": without_field(refuse_without_cleanup, "cleanup_proof_path"),
        "missing-host-refusal-proof.json": without_field(good, "host_refusal_proof_path"),
        "privacy-failed.json": privacy_failed,
        "malformed.json": '{ "schema": "zig-scheduler/matrix-run/v1",',
        "extra-property.json": extra_property,
    }


def write_self_test_pack(fixtures: Path, invalid: Path, good: JsonObject) -> None:
    for name in REQUIRED_FIXTURES:
        write_json(fixtures / name, good)
    for name, row in invalid_self_test_rows(good).items():
        if isinstance(row, str):
            _ = (invalid / name).write_text(row)
        else:
            write_json(invalid / name, row)


def clone_object(value: JsonObject) -> JsonObject:
    return obj(json_loader.loads(json.dumps(value), parse_constant=reject_constant), "cloned JSON object")


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
    benchmark_record_path = row_dir / "benchmark-provenance.json"
    workload["spec_sha256"] = write_json_digest(row_dir / "workload-spec.json", {
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
                "output_path": bench_raw_path.as_posix(),
                "output_sha256": file_sha256(bench_raw_path),
                "vm_evidence": (run_root / "manifest.json").as_posix(),
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
    })
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


def assert_invalid_manifest(manifest_path: Path, name: str, expected_error: str | None = None) -> None:
    try:
        _ = validate_manifest(manifest_path)
    except MatrixRunContractError as exc:
        if expected_error is not None:
            require(expected_error in str(exc), f"self-test {name} failed on wrong rule: expected {expected_error!r}, got {exc}")
        print(f"PASS self-test rejects malformed manifest {name}: {exc}")
        return
    raise MatrixRunContractError(f"self-test failed to reject malformed manifest: {name}")


def run_manifest_self_test_case(good: JsonObject, name: str, index: int) -> None:
    run_root = MATRIX_BASE / f"selftest-{index}"
    if run_root.exists():
        shutil.rmtree(run_root)
    run_root.mkdir(parents=True)
    try:
        manifest_path = write_manifest_self_test_pack(run_root, good)
        _ = validate_manifest(manifest_path)
        manifest = load_json(manifest_path)
        rows = manifest.get("rows")
        if not isinstance(rows, list):
            raise MatrixRunContractError("manifest self-test setup produced non-list rows")
        row = obj(rows[0], "manifest self-test first row")
        artifact_path = Path(text(row.get("artifact_path"), "manifest self-test artifact_path"))
        match name:  # noqa: MATCH_OK — self-test case names are runtime strings; default raises a contract error.
            case "root-outside-matrix":
                assert_invalid_manifest(Path("evidence/lab/self-test-root") / MANIFEST_FILE, name)
            case "absolute-artifact-path":
                row["artifact_path"] = "/tmp/matrix-run.json"
                write_json(manifest_path, manifest)
                assert_invalid_manifest(manifest_path, name)
            case "artifact-outside-run-root":
                row["artifact_path"] = "fixtures/matrix-run/pass.json"
                write_json(manifest_path, manifest)
                assert_invalid_manifest(manifest_path, name)
            case "duplicate-scenario":
                rows.append(dict(row))
                manifest["row_count"] = 2
                write_json(manifest_path, manifest)
                assert_invalid_manifest(manifest_path, name)
            case "duplicate-artifact":
                second = dict(row)
                second["scenario_id"] = "fixture-pass-copy"
                rows.append(second)
                manifest["row_count"] = 2
                write_json(manifest_path, manifest)
                assert_invalid_manifest(manifest_path, name)
            case "row-count-mismatch":
                manifest["row_count"] = 2
                write_json(manifest_path, manifest)
                assert_invalid_manifest(manifest_path, name)
            case "manifest-out-dir-mismatch":
                manifest["out_dir"] = "evidence/lab/matrix/other-run"
                write_json(manifest_path, manifest)
                assert_invalid_manifest(manifest_path, name)
            case "manifest-run-id-basename-mismatch":
                manifest["matrix_run_id"] = "other-run"
                write_json(manifest_path, manifest)
                assert_invalid_manifest(manifest_path, name)
            case "row-run-id-manifest-mismatch":
                row_data = load_json(artifact_path)
                row_data["matrix_run_id"] = "other-run"
                write_json(artifact_path, row_data)
                assert_invalid_manifest(manifest_path, name)
            case "row-internal-path-outside-root":
                row_data = load_json(artifact_path)
                row_data["runtime_sample_path"] = "fixtures/matrix-run/pass.json"
                write_json(artifact_path, row_data)
                assert_invalid_manifest(manifest_path, name)
            case "missing-proof-artifact":
                row_data = load_json(artifact_path)
                Path(text(row_data.get("rollback_proof_path"), "manifest self-test rollback_proof_path")).unlink()
                assert_invalid_manifest(manifest_path, name, "missing JSON file")
            case "invalid-runtime-sample-artifact":
                row_data = load_json(artifact_path)
                runtime_path = Path(text(row_data.get("runtime_sample_path"), "manifest self-test runtime_sample_path"))
                _ = runtime_path.write_text(json.dumps({"schema": "zig-scheduler/runtime-sample/v1", "sequence": 0}) + "\n")
                assert_invalid_manifest(manifest_path, name, "invalid runtime sample artifact")
            case "host-safe-vm-live-claim":
                manifest["mode"] = "host-safe"
                manifest["fixture_mode"] = True
                write_json(manifest_path, manifest)
                assert_invalid_manifest(manifest_path, name, "fixture manifest must not claim")
            case "forged-pass-host-refusal-no-marker":
                row_data = load_json(artifact_path)
                row_data["evidence_mode"] = "host-refusal-only"
                marker = obj(row_data.get("vm_marker"), "manifest self-test vm_marker")
                marker["required"] = False
                marker["present"] = False
                marker["checked_by"] = "qa/vm/vm_harness_matrix.sh"
                write_json(artifact_path, row_data)
                assert_invalid_manifest(manifest_path, name, "PASS requires vm-live proof or explicit fixture evidence")
            case "forged-fixture-mode-false-fixture-pass":
                row_data = load_json(artifact_path)
                row_data["evidence_mode"] = "fixture"
                marker = obj(row_data.get("vm_marker"), "manifest self-test vm_marker")
                marker["required"] = False
                marker["present"] = False
                marker["checked_by"] = "qa/vm/vm_harness_matrix.sh"
                write_json(artifact_path, row_data)
                assert_invalid_manifest(manifest_path, name, "fixture evidence requires explicit fixture_mode=true")
            case "host-safe-fixture-mode-false-fixture-pass":
                manifest["mode"] = "host-safe"
                manifest["fixture_mode"] = False
                row_data = load_json(artifact_path)
                row_data["evidence_mode"] = "fixture"
                marker = obj(row_data.get("vm_marker"), "manifest self-test vm_marker")
                marker["required"] = False
                marker["present"] = False
                marker["checked_by"] = "qa/vm/vm_harness_matrix.sh"
                write_json(artifact_path, row_data)
                write_json(manifest_path, manifest)
                assert_invalid_manifest(manifest_path, name, "fixture evidence requires explicit fixture_mode=true")
            case "vm-live-missing-marker-proof":
                row_data = load_json(artifact_path)
                marker = obj(row_data.get("vm_marker"), "manifest self-test vm_marker")
                marker["checked_by"] = "qa/vm/vm_harness_matrix.sh"
                write_json(artifact_path, row_data)
                assert_invalid_manifest(manifest_path, name, "vm_marker.checked_by must stay under")
            case "vm-live-marker-proof-mismatch":
                row_data = load_json(artifact_path)
                marker = obj(row_data.get("vm_marker"), "manifest self-test vm_marker")
                marker_path = Path(text(marker.get("checked_by"), "manifest self-test vm_marker.checked_by"))
                proof = load_json(marker_path)
                proof["present"] = False
                write_json(marker_path, proof)
                assert_invalid_manifest(manifest_path, name, "present must match row marker")
            case "malicious-workload-spec-token":
                row_data = load_json(artifact_path)
                workload = obj(row_data.get("workload"), "manifest self-test workload")
                spec_path = Path(text(workload.get("spec_path"), "manifest self-test workload.spec_path"))
                spec_data = load_json(spec_path)
                spec_data["api_key"] = "must-not-persist"
                write_json(spec_path, spec_data)
                workload["spec_sha256"] = file_sha256(spec_path)
                write_json(artifact_path, row_data)
                assert_invalid_manifest(manifest_path, name)
            case "malicious-capability-token":
                row_data = load_json(artifact_path)
                workload = obj(row_data.get("workload"), "manifest self-test workload")
                spec_path = Path(text(workload.get("spec_path"), "manifest self-test workload.spec_path"))
                spec_data = load_json(spec_path)
                capability_path = Path(text(spec_data.get("capability_artifact_path"), "manifest self-test capability_artifact_path"))
                capability_data = load_json(capability_path)
                capability_data["environment"] = "api_key=must-not-persist"
                write_json(capability_path, capability_data)
                assert_invalid_manifest(manifest_path, name)
            case "false-private-fields-found":
                row_data = load_json(artifact_path)
                privacy = obj(row_data.get("privacy_scan"), "manifest self-test privacy_scan")
                privacy_path = Path(text(privacy.get("report_path"), "manifest self-test privacy_scan.report_path"))
                privacy_data = load_json(privacy_path)
                privacy_data["private_fields_found"] = False
                write_json(privacy_path, privacy_data)
                workload = obj(row_data.get("workload"), "manifest self-test workload")
                spec_path = Path(text(workload.get("spec_path"), "manifest self-test workload.spec_path"))
                spec_data = load_json(spec_path)
                spec_data["notes"] = "contains api_key while report claims clean"
                write_json(spec_path, spec_data)
                workload["spec_sha256"] = file_sha256(spec_path)
                write_json(artifact_path, row_data)
                assert_invalid_manifest(manifest_path, name)
            case "workload-claim-leakage":
                row_data = load_json(artifact_path)
                workload = obj(row_data.get("workload"), "manifest self-test workload")
                spec_path = Path(text(workload.get("spec_path"), "manifest self-test workload.spec_path"))
                spec_data = load_json(spec_path)
                thresholds = obj(spec_data.get("thresholds"), "manifest self-test workload.spec.thresholds")
                thresholds["calibration_status"] = "production ready"
                write_json(spec_path, spec_data)
                workload["spec_sha256"] = file_sha256(spec_path)
                write_json(artifact_path, row_data)
                assert_invalid_manifest(manifest_path, name, "claim-unsafe workload text")
            case "workload-spec-class-mismatch":
                row_data = load_json(artifact_path)
                workload = obj(row_data.get("workload"), "manifest self-test workload")
                spec_path = Path(text(workload.get("spec_path"), "manifest self-test workload.spec_path"))
                spec_data = load_json(spec_path)
                spec_data["workload_class"] = "mixed-io"
                spec_data["name"] = "mixed-io"
                write_json(spec_path, spec_data)
                workload["spec_sha256"] = file_sha256(spec_path)
                write_json(artifact_path, row_data)
                assert_invalid_manifest(manifest_path, name)
            case "workload-spec-required-tools-mismatch":
                row_data = load_json(artifact_path)
                workload = obj(row_data.get("workload"), "manifest self-test workload")
                spec_path = Path(text(workload.get("spec_path"), "manifest self-test workload.spec_path"))
                spec_data = load_json(spec_path)
                spec_data["required_tools"] = ["fio"]
                write_json(spec_path, spec_data)
                workload["spec_sha256"] = file_sha256(spec_path)
                write_json(artifact_path, row_data)
                assert_invalid_manifest(manifest_path, name, "workload.spec.required_tools must match scenario workload-cpu-saturation required tools: stress-ng")
            case "workload-mixed-metadata-canonical-mismatch":
                row_data = load_json(artifact_path)
                workload = obj(row_data.get("workload"), "manifest self-test workload")
                spec_path = Path(text(workload.get("spec_path"), "manifest self-test workload.spec_path"))
                spec_data = load_json(spec_path)
                capability_path = Path(text(spec_data.get("capability_artifact_path"), "manifest self-test capability_artifact_path"))
                spec_data["required_tools"] = ["fio"]
                spec_data["threshold_source"] = "calibrated"
                thresholds = obj(spec_data.get("thresholds"), "manifest self-test workload.spec.thresholds")
                thresholds["source"] = "calibrated"
                write_json(spec_path, spec_data)
                capability_data = load_json(capability_path)
                capability_data["required_tools"] = ["fio"]
                capability_data["threshold_source"] = "calibrated"
                write_json(capability_path, capability_data)
                workload["spec_sha256"] = file_sha256(spec_path)
                write_json(artifact_path, row_data)
                assert_invalid_manifest(manifest_path, name, "workload.spec.required_tools must match scenario workload-cpu-saturation required tools: stress-ng")
            case "workload-spec-threshold-source-mismatch":
                row_data = load_json(artifact_path)
                workload = obj(row_data.get("workload"), "manifest self-test workload")
                spec_path = Path(text(workload.get("spec_path"), "manifest self-test workload.spec_path"))
                spec_data = load_json(spec_path)
                spec_data["threshold_source"] = "calibrated"
                thresholds = obj(spec_data.get("thresholds"), "manifest self-test workload.spec.thresholds")
                thresholds["source"] = "calibrated"
                write_json(spec_path, spec_data)
                workload["spec_sha256"] = file_sha256(spec_path)
                write_json(artifact_path, row_data)
                assert_invalid_manifest(manifest_path, name)
            case _ if name in BENCHMARK_PROVENANCE_SELF_TEST_CASES:
                try:
                    apply_benchmark_provenance_self_test_case(name, manifest_path, artifact_path, assert_invalid_manifest)
                except MatrixBenchmarkSelfTestError as exc:
                    raise MatrixRunContractError(str(exc)) from exc
            case "workload-uncataloged-scenario":
                row_data = load_json(artifact_path)
                row_data["scenario_id"] = "workload-uncataloged"
                write_json(artifact_path, row_data)
                manifest_row = obj(rows[0], "manifest self-test manifest row")
                manifest_row["scenario_id"] = "workload-uncataloged"
                write_json(manifest_path, manifest)
                assert_invalid_manifest(manifest_path, name)
            case "workload-capability-required-tools-mismatch":
                row_data = load_json(artifact_path)
                workload = obj(row_data.get("workload"), "manifest self-test workload")
                spec_path = Path(text(workload.get("spec_path"), "manifest self-test workload.spec_path"))
                spec_data = load_json(spec_path)
                capability_path = Path(text(spec_data.get("capability_artifact_path"), "manifest self-test capability_artifact_path"))
                capability_data = load_json(capability_path)
                capability_data["required_tools"] = ["fio"]
                write_json(capability_path, capability_data)
                assert_invalid_manifest(manifest_path, name)
            case "workload-capability-threshold-source-mismatch":
                row_data = load_json(artifact_path)
                workload = obj(row_data.get("workload"), "manifest self-test workload")
                spec_path = Path(text(workload.get("spec_path"), "manifest self-test workload.spec_path"))
                spec_data = load_json(spec_path)
                capability_path = Path(text(spec_data.get("capability_artifact_path"), "manifest self-test capability_artifact_path"))
                capability_data = load_json(capability_path)
                capability_data["threshold_source"] = "calibrated"
                write_json(capability_path, capability_data)
                assert_invalid_manifest(manifest_path, name)
            case "workload-capability-missing-prereq-mismatch":
                row_data = load_json(artifact_path)
                row_data["outcome"] = "REFUSE"
                workload = obj(row_data.get("workload"), "manifest self-test workload")
                spec_path = Path(text(workload.get("spec_path"), "manifest self-test workload.spec_path"))
                spec_data = load_json(spec_path)
                capability_path = Path(text(spec_data.get("capability_artifact_path"), "manifest self-test capability_artifact_path"))
                capability_data = load_json(capability_path)
                capability_data["status"] = "REFUSE"
                capability_data["typed_outcome"] = "REFUSE"
                capability_data["missing_prereq"] = "fio"
                write_json(capability_path, capability_data)
                write_json(artifact_path, row_data)
                manifest_row = obj(rows[0], "manifest self-test manifest row")
                manifest_row["outcome"] = "REFUSE"
                write_json(manifest_path, manifest)
                assert_invalid_manifest(manifest_path, name, "workload.capability.missing_prereq must be empty or one of scenario workload-cpu-saturation required tools: stress-ng")
            case "workload-capability-outcome-mismatch":
                row_data = load_json(artifact_path)
                workload = obj(row_data.get("workload"), "manifest self-test workload")
                spec_path = Path(text(workload.get("spec_path"), "manifest self-test workload.spec_path"))
                spec_data = load_json(spec_path)
                capability_path = Path(text(spec_data.get("capability_artifact_path"), "manifest self-test capability_artifact_path"))
                capability_data = load_json(capability_path)
                capability_data["status"] = "REFUSE"
                capability_data["typed_outcome"] = "REFUSE"
                capability_data["missing_prereq"] = "stress-ng"
                write_json(capability_path, capability_data)
                assert_invalid_manifest(manifest_path, name)
            case "workload-capability-pass-missing-prereq":
                row_data = load_json(artifact_path)
                workload = obj(row_data.get("workload"), "manifest self-test workload")
                spec_path = Path(text(workload.get("spec_path"), "manifest self-test workload.spec_path"))
                spec_data = load_json(spec_path)
                capability_path = Path(text(spec_data.get("capability_artifact_path"), "manifest self-test capability_artifact_path"))
                capability_data = load_json(capability_path)
                capability_data["missing_prereq"] = "stress-ng"
                write_json(capability_path, capability_data)
                assert_invalid_manifest(manifest_path, name)
            case "workload-capability-skip-empty-missing-prereq":
                row_data = load_json(artifact_path)
                row_data["outcome"] = "SKIP"
                write_json(artifact_path, row_data)
                workload = obj(row_data.get("workload"), "manifest self-test workload")
                spec_path = Path(text(workload.get("spec_path"), "manifest self-test workload.spec_path"))
                spec_data = load_json(spec_path)
                capability_path = Path(text(spec_data.get("capability_artifact_path"), "manifest self-test capability_artifact_path"))
                capability_data = load_json(capability_path)
                capability_data["status"] = "SKIP"
                capability_data["typed_outcome"] = "SKIP"
                capability_data["missing_prereq"] = ""
                write_json(capability_path, capability_data)
                manifest_row = obj(rows[0], "manifest self-test manifest row")
                manifest_row["outcome"] = "SKIP"
                write_json(manifest_path, manifest)
                assert_invalid_manifest(manifest_path, name)
            case "live-backend-forged-pass-without-marker-proof":
                live_manifest = write_manifest_self_test_pack(run_root, good, "live-backend")
                live_manifest_data = load_json(live_manifest)
                live_rows = live_manifest_data.get("rows")
                if not isinstance(live_rows, list):
                    raise MatrixRunContractError("live-backend self-test setup produced non-list rows")
                live_row_ref = obj(live_rows[0], "live-backend self-test manifest row")
                live_artifact_path = Path(text(live_row_ref.get("artifact_path"), "live-backend self-test artifact_path"))
                live_row = load_json(live_artifact_path)
                marker = obj(live_row.get("vm_marker"), "live-backend self-test vm_marker")
                marker["checked_by"] = "qa/vm/marker-check"
                write_json(live_artifact_path, live_row)
                assert_invalid_manifest(live_manifest, name, "vm_marker.checked_by must stay under")
            case "live-backend-missing-cleanup-proof-artifact":
                live_manifest = write_manifest_self_test_pack(run_root, good, "live-backend")
                live_rows = load_json(live_manifest).get("rows")
                if not isinstance(live_rows, list):
                    raise MatrixRunContractError("live-backend self-test setup produced non-list rows")
                live_row_ref = obj(live_rows[0], "live-backend self-test manifest row")
                live_artifact_path = Path(text(live_row_ref.get("artifact_path"), "live-backend self-test artifact_path"))
                live_row = load_json(live_artifact_path)
                Path(text(live_row.get("cleanup_proof_path"), "live-backend cleanup_proof_path")).unlink()
                assert_invalid_manifest(live_manifest, name, "missing JSON file")
            case "live-backend-missing-host-refusal-proof-artifact":
                live_manifest = write_manifest_self_test_pack(run_root, good, "live-backend")
                live_rows = load_json(live_manifest).get("rows")
                if not isinstance(live_rows, list):
                    raise MatrixRunContractError("live-backend self-test setup produced non-list rows")
                live_row_ref = obj(live_rows[0], "live-backend self-test manifest row")
                live_artifact_path = Path(text(live_row_ref.get("artifact_path"), "live-backend self-test artifact_path"))
                live_row = load_json(live_artifact_path)
                Path(text(live_row.get("host_refusal_proof_path"), "live-backend host_refusal_proof_path")).unlink()
                assert_invalid_manifest(live_manifest, name, "missing JSON file")
            case "live-backend-daemon-events-outside-root":
                live_manifest = write_manifest_self_test_pack(run_root, good, "live-backend")
                live_rows = load_json(live_manifest).get("rows")
                if not isinstance(live_rows, list):
                    raise MatrixRunContractError("live-backend self-test setup produced non-list rows")
                live_row_ref = obj(live_rows[0], "live-backend self-test manifest row")
                live_artifact_path = Path(text(live_row_ref.get("artifact_path"), "live-backend self-test artifact_path"))
                live_row = load_json(live_artifact_path)
                live_row["daemon_event_path"] = "fixtures/matrix-run/pass.json"
                write_json(live_artifact_path, live_row)
                assert_invalid_manifest(live_manifest, name, "daemon_event_path must stay under")
            case "live-backend-dirty-summary-masked-pass":
                live_manifest = write_manifest_self_test_pack(run_root, good, "live-backend")
                live_rows = load_json(live_manifest).get("rows")
                if not isinstance(live_rows, list):
                    raise MatrixRunContractError("live-backend self-test setup produced non-list rows")
                live_row_ref = obj(live_rows[0], "live-backend self-test manifest row")
                live_artifact_path = Path(text(live_row_ref.get("artifact_path"), "live-backend self-test artifact_path"))
                backend_dir = live_artifact_path.parent / "backend"
                live_dir = backend_dir / "live"
                live_dir.mkdir(parents=True)
                write_json(live_dir / "summary.json", {"schema": "zig-scheduler/run-all-lab/v1", "status": "PASS", "git_sha": "abcdef012345", "git_dirty": True, "host_mutation": False})
                write_json(backend_dir / "summary.json", {"schema": "zig-scheduler/vm-backend-run/v1", "status": "PASS", "live_summary": (live_dir / "summary.json").as_posix(), "host_mutation": False})
                assert_invalid_manifest(live_manifest, name, "dirty live backend summary cannot back")
            case "extra-property":
                manifest["unexpected_field_not_in_schema"] = "reject"
                write_json(manifest_path, manifest)
                assert_invalid_manifest(manifest_path, name)
            case _:
                raise MatrixRunContractError(f"unknown manifest self-test case: {name}")
    finally:
        shutil.rmtree(run_root)


def assert_invalid_fixture_gate(args: Args, name: str, good: JsonObject) -> None:
    if args.fixtures is None:
        raise MatrixRunContractError("self-test fixture directory missing")
    write_json(args.fixtures / "invalid" / name, good)
    try:
        _ = validate(args)
    except MatrixRunContractError as exc:
        print(f"PASS self-test detects missing rejection coverage for {name}: {exc}")
        return
    raise MatrixRunContractError(f"self-test failed to reject accepted invalid fixture: {name}")


def run_self_test() -> None:
    good = load_json(Path("fixtures/matrix-run/pass.json"))
    for name in sorted(REQUIRED_INVALID_FIXTURES):
        with TemporaryDirectory(prefix="zigsched-matrix-run-") as tmp:
            root = Path(tmp)
            fixtures = root / "fixtures"
            invalid = fixtures / "invalid"
            schemas = root / "schemas"
            docs = root / "docs"
            invalid.mkdir(parents=True)
            schemas.mkdir()
            docs.mkdir()
            _ = (schemas / SCHEMA_FILE).write_text((Path("schemas/control") / SCHEMA_FILE).read_text())
            _ = (docs / DOC_FILE).write_text((Path("docs/control") / DOC_FILE).read_text())
            write_self_test_pack(fixtures, invalid, good)
            args = Args(fixtures, schemas, docs, None, False)
            _ = validate(args)
            assert_invalid_fixture_gate(args, name, good)
    MATRIX_BASE.mkdir(parents=True, exist_ok=True)
    try:
        host_safe_root = MATRIX_BASE / "selftest-host-safe-fixture-pass"
        if host_safe_root.exists():
            shutil.rmtree(host_safe_root)
        host_safe_root.mkdir(parents=True)
        try:
            host_safe_manifest = write_host_safe_fixture_pass_self_test_pack(host_safe_root, good)
            _ = validate_manifest(host_safe_manifest)
            print("PASS self-test accepts host-safe fixture PASS without VM marker claim")
        finally:
            shutil.rmtree(host_safe_root)
        for index, name in enumerate((
            "root-outside-matrix",
            "absolute-artifact-path",
            "artifact-outside-run-root",
            "duplicate-scenario",
            "duplicate-artifact",
            "row-count-mismatch",
            "manifest-out-dir-mismatch",
            "manifest-run-id-basename-mismatch",
            "row-run-id-manifest-mismatch",
            "row-internal-path-outside-root",
            "missing-proof-artifact",
            "invalid-runtime-sample-artifact",
            "host-safe-vm-live-claim",
            "forged-pass-host-refusal-no-marker",
            "forged-fixture-mode-false-fixture-pass",
            "host-safe-fixture-mode-false-fixture-pass",
            "vm-live-missing-marker-proof",
            "vm-live-marker-proof-mismatch",
            "malicious-workload-spec-token",
            "malicious-capability-token",
            "false-private-fields-found",
            "workload-claim-leakage",
            "workload-spec-class-mismatch",
            "workload-spec-required-tools-mismatch",
            "workload-mixed-metadata-canonical-mismatch",
            "workload-spec-threshold-source-mismatch",
            "workload-benchmark-provenance-missing",
            "workload-calibrated-benchmark-provenance-absent",
            "workload-benchmark-provenance-malformed",
            "workload-benchmark-provenance-claim",
            "workload-uncataloged-scenario",
            "workload-capability-required-tools-mismatch",
            "workload-capability-threshold-source-mismatch",
            "workload-capability-missing-prereq-mismatch",
            "workload-capability-outcome-mismatch",
            "workload-capability-pass-missing-prereq",
            "workload-capability-skip-empty-missing-prereq",
            "live-backend-forged-pass-without-marker-proof",
            "live-backend-missing-cleanup-proof-artifact",
            "live-backend-missing-host-refusal-proof-artifact",
            "live-backend-daemon-events-outside-root",
            "live-backend-dirty-summary-masked-pass",
            "extra-property",
        )):
            run_manifest_self_test_case(good, name, index)
    finally:
        with suppress(OSError):
            MATRIX_BASE.rmdir()


def run(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.self_test:
        run_self_test()
        print("PASS matrix-run contract self-test")
    else:
        valid_count, invalid_count = validate(args)
        if args.manifest is not None:
            print(f"PASS matrix-run contract: manifest={args.manifest} valid={valid_count} docs={args.docs}")
        else:
            print(f"PASS matrix-run contract: fixtures={args.fixtures} valid={valid_count} invalid={invalid_count} docs={args.docs}")
    return 0


def main() -> int:
    try:
        return run(sys.argv[1:])
    except (OSError, UnicodeError, MatrixRunContractError) as exc:
        print(f"FAIL matrix-run contract: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
