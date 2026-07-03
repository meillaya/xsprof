#!/usr/bin/env python3
"""Workload metadata and artifact validators for matrix-run/v1."""
from __future__ import annotations

from pathlib import Path
from qa.matrix_benchmark_provenance import MatrixBenchmarkProvenanceError
from qa.matrix_benchmark_provenance import validate_entries as validate_benchmark_provenance_entries
from qa.matrix_run_json import (
    obj,
    require,
    require_only_fields,
    require_safe_path,
    require_sha,
    text,
    text_list,
)
from qa.matrix_run_model import (
    CGROUP_WORKLOAD_SEMANTICS,
    CPU_HOTPLUG_SEMANTICS,
    PRIVACY_REPORT_FIELDS,
    PRIVACY_SCAN_SCHEMA,
    WORKLOAD_CAPABILITY_FIELDS,
    WORKLOAD_CAPABILITY_MODES,
    WORKLOAD_CAPABILITY_SCHEMA,
    WORKLOAD_FIELDS,
    WORKLOAD_SCENARIO_METADATA,
    WORKLOAD_SPEC_FIELDS,
    WORKLOAD_SPEC_SCHEMA,
    WORKLOAD_THRESHOLD_FIELDS,
    WORKLOAD_THRESHOLD_SOURCES,
    WORKLOAD_TOOL_NAMES,
    JsonObject,
    JsonValue,
    OUTCOMES,
    MatrixRunContractError,
    WorkloadScenarioMetadata,
)

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

def validate_semantics_exact(value: JsonValue | None, expected: JsonObject, context: str) -> None:
    semantics = obj(value, context)
    require(set(semantics) == set(expected), f"{context} keys must match Todo 7 VM-only semantics")
    for knob, expected_label in expected.items():
        require(semantics.get(knob) == expected_label, f"{context}.{knob} must be {expected_label}")

def validate_workload_semantics(spec: JsonObject, scenario_id: str, context: str) -> None:
    if scenario_id == "workload-cgroup-weight-quota":
        validate_semantics_exact(spec.get("cgroup_semantics"), CGROUP_WORKLOAD_SEMANTICS, f"{context}.cgroup_semantics")
        require("cpu_hotplug_semantics" not in spec, f"{context}.cpu_hotplug_semantics is only allowed for workload-cpu-hotplug")
        return
    if scenario_id == "workload-cpu-hotplug":
        validate_semantics_exact(spec.get("cpu_hotplug_semantics"), CPU_HOTPLUG_SEMANTICS, f"{context}.cpu_hotplug_semantics")
        require("cgroup_semantics" not in spec, f"{context}.cgroup_semantics is only allowed for workload-cgroup-weight-quota")
        return
    require("cgroup_semantics" not in spec, f"{context}.cgroup_semantics is only allowed for workload-cgroup-weight-quota")
    require("cpu_hotplug_semantics" not in spec, f"{context}.cpu_hotplug_semantics is only allowed for workload-cpu-hotplug")

def workload_semantic_fields(scenario_id: str) -> JsonObject:
    if scenario_id == "workload-cgroup-weight-quota":
        return {"cgroup_semantics": dict(CGROUP_WORKLOAD_SEMANTICS)}
    if scenario_id == "workload-cpu-hotplug":
        return {"cpu_hotplug_semantics": dict(CPU_HOTPLUG_SEMANTICS)}
    return {}

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
    validate_workload_semantics(spec, scenario_id, context)
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
