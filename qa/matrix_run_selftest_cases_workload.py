#!/usr/bin/env python3
"""Workload manifest self-test mutations for matrix-run checks."""
from __future__ import annotations

from pathlib import Path

from qa.matrix_benchmark_provenance_selftest import BENCHMARK_PROVENANCE_SELF_TEST_CASES
from qa.matrix_benchmark_provenance_selftest import MatrixBenchmarkSelfTestError
from qa.matrix_benchmark_provenance_selftest import apply_case as apply_benchmark_provenance_self_test_case
from qa.matrix_run_json import file_sha256, load_json, obj, text
from qa.matrix_run_model import JsonObject, MatrixRunContractError
from qa.matrix_run_selftest_common import ManifestSelfTestContext, assert_invalid_manifest, write_json


def handle_workload_manifest_case(ctx: ManifestSelfTestContext) -> bool:
    match ctx.name:  # noqa: RUF100  # noqa: MATCH_OK - self-test case names are runtime strings; false means another group may own it.
        case "workload-claim-leakage":
            row_data = load_json(ctx.artifact_path)
            workload = obj(row_data.get("workload"), "manifest self-test workload")
            spec_path = Path(text(workload.get("spec_path"), "manifest self-test workload.spec_path"))
            spec_data = load_json(spec_path)
            thresholds = obj(spec_data.get("thresholds"), "manifest self-test workload.spec.thresholds")
            thresholds["calibration_status"] = "production ready"
            write_json(spec_path, spec_data)
            workload["spec_sha256"] = file_sha256(spec_path)
            write_json(ctx.artifact_path, row_data)
            assert_invalid_manifest(ctx.manifest_path, ctx.name, "claim-unsafe workload text")
        case "workload-spec-class-mismatch":
            row_data = load_json(ctx.artifact_path)
            workload = obj(row_data.get("workload"), "manifest self-test workload")
            spec_path = Path(text(workload.get("spec_path"), "manifest self-test workload.spec_path"))
            spec_data = load_json(spec_path)
            spec_data["workload_class"] = "mixed-io"
            spec_data["name"] = "mixed-io"
            write_json(spec_path, spec_data)
            workload["spec_sha256"] = file_sha256(spec_path)
            write_json(ctx.artifact_path, row_data)
            assert_invalid_manifest(ctx.manifest_path, ctx.name)
        case "workload-spec-required-tools-mismatch":
            row_data = load_json(ctx.artifact_path)
            workload = obj(row_data.get("workload"), "manifest self-test workload")
            spec_path = Path(text(workload.get("spec_path"), "manifest self-test workload.spec_path"))
            spec_data = load_json(spec_path)
            spec_data["required_tools"] = ["fio"]
            write_json(spec_path, spec_data)
            workload["spec_sha256"] = file_sha256(spec_path)
            write_json(ctx.artifact_path, row_data)
            assert_invalid_manifest(ctx.manifest_path, ctx.name, "workload.spec.required_tools must match scenario workload-cpu-saturation required tools: stress-ng")
        case "workload-mixed-metadata-canonical-mismatch":
            row_data = load_json(ctx.artifact_path)
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
            write_json(ctx.artifact_path, row_data)
            assert_invalid_manifest(ctx.manifest_path, ctx.name, "workload.spec.required_tools must match scenario workload-cpu-saturation required tools: stress-ng")
        case "workload-spec-threshold-source-mismatch":
            row_data = load_json(ctx.artifact_path)
            workload = obj(row_data.get("workload"), "manifest self-test workload")
            spec_path = Path(text(workload.get("spec_path"), "manifest self-test workload.spec_path"))
            spec_data = load_json(spec_path)
            spec_data["threshold_source"] = "calibrated"
            thresholds = obj(spec_data.get("thresholds"), "manifest self-test workload.spec.thresholds")
            thresholds["source"] = "calibrated"
            write_json(spec_path, spec_data)
            workload["spec_sha256"] = file_sha256(spec_path)
            write_json(ctx.artifact_path, row_data)
            assert_invalid_manifest(ctx.manifest_path, ctx.name)
        case _ if ctx.name in BENCHMARK_PROVENANCE_SELF_TEST_CASES:
            try:
                apply_benchmark_provenance_self_test_case(ctx.name, ctx.manifest_path, ctx.artifact_path, assert_invalid_manifest)
            except MatrixBenchmarkSelfTestError as exc:
                raise MatrixRunContractError(str(exc)) from exc
        case "workload-uncataloged-scenario":
            row_data = load_json(ctx.artifact_path)
            row_data["scenario_id"] = "workload-uncataloged"
            write_json(ctx.artifact_path, row_data)
            manifest_row = obj(ctx.rows[0], "manifest self-test manifest row")
            manifest_row["scenario_id"] = "workload-uncataloged"
            write_json(ctx.manifest_path, ctx.manifest)
            assert_invalid_manifest(ctx.manifest_path, ctx.name)
        case "workload-capability-required-tools-mismatch":
            capability_path = _capability_path(ctx.artifact_path)
            capability_data = load_json(capability_path)
            capability_data["required_tools"] = ["fio"]
            write_json(capability_path, capability_data)
            assert_invalid_manifest(ctx.manifest_path, ctx.name)
        case "workload-capability-threshold-source-mismatch":
            capability_path = _capability_path(ctx.artifact_path)
            capability_data = load_json(capability_path)
            capability_data["threshold_source"] = "calibrated"
            write_json(capability_path, capability_data)
            assert_invalid_manifest(ctx.manifest_path, ctx.name)
        case "workload-capability-missing-prereq-mismatch":
            row_data = load_json(ctx.artifact_path)
            row_data["outcome"] = "REFUSE"
            capability_path = _capability_path_from_row(row_data)
            capability_data = load_json(capability_path)
            capability_data["status"] = "REFUSE"
            capability_data["typed_outcome"] = "REFUSE"
            capability_data["missing_prereq"] = "fio"
            write_json(capability_path, capability_data)
            write_json(ctx.artifact_path, row_data)
            manifest_row = obj(ctx.rows[0], "manifest self-test manifest row")
            manifest_row["outcome"] = "REFUSE"
            write_json(ctx.manifest_path, ctx.manifest)
            assert_invalid_manifest(ctx.manifest_path, ctx.name, "workload.capability.missing_prereq must be empty or one of scenario workload-cpu-saturation required tools: stress-ng")
        case "workload-capability-outcome-mismatch":
            capability_path = _capability_path(ctx.artifact_path)
            capability_data = load_json(capability_path)
            capability_data["status"] = "REFUSE"
            capability_data["typed_outcome"] = "REFUSE"
            capability_data["missing_prereq"] = "stress-ng"
            write_json(capability_path, capability_data)
            assert_invalid_manifest(ctx.manifest_path, ctx.name)
        case "workload-capability-pass-missing-prereq":
            capability_path = _capability_path(ctx.artifact_path)
            capability_data = load_json(capability_path)
            capability_data["missing_prereq"] = "stress-ng"
            write_json(capability_path, capability_data)
            assert_invalid_manifest(ctx.manifest_path, ctx.name)
        case "workload-capability-skip-empty-missing-prereq":
            row_data = load_json(ctx.artifact_path)
            row_data["outcome"] = "SKIP"
            write_json(ctx.artifact_path, row_data)
            capability_path = _capability_path_from_row(row_data)
            capability_data = load_json(capability_path)
            capability_data["status"] = "SKIP"
            capability_data["typed_outcome"] = "SKIP"
            capability_data["missing_prereq"] = ""
            write_json(capability_path, capability_data)
            manifest_row = obj(ctx.rows[0], "manifest self-test manifest row")
            manifest_row["outcome"] = "SKIP"
            write_json(ctx.manifest_path, ctx.manifest)
            assert_invalid_manifest(ctx.manifest_path, ctx.name)
        case _:
            return False
    return True


def _capability_path(artifact_path: Path) -> Path:
    return _capability_path_from_row(load_json(artifact_path))


def _capability_path_from_row(row_data: JsonObject) -> Path:
    workload = obj(row_data.get("workload"), "manifest self-test workload")
    spec_path = Path(text(workload.get("spec_path"), "manifest self-test workload.spec_path"))
    spec_data = load_json(spec_path)
    return Path(text(spec_data.get("capability_artifact_path"), "manifest self-test capability_artifact_path"))
