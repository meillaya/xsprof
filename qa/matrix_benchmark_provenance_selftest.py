#!/usr/bin/env python3
"""Self-test mutations for matrix benchmark provenance failures."""
from __future__ import annotations

import hashlib
import json
from collections.abc import Callable
from pathlib import Path
from typing import Final, TypeAlias

from qa.matrix_benchmark_provenance import load_json

JsonValue: TypeAlias = None | bool | int | float | str | list["JsonValue"] | dict[str, "JsonValue"]
JsonObject: TypeAlias = dict[str, JsonValue]
BENCHMARK_PROVENANCE_SELF_TEST_CASES: Final = frozenset({
    "workload-benchmark-provenance-missing",
    "workload-calibrated-benchmark-provenance-absent",
    "workload-benchmark-provenance-malformed",
    "workload-benchmark-provenance-claim",
})
InvalidManifestAsserter: TypeAlias = Callable[[Path, str, str | None], None]


class MatrixBenchmarkSelfTestError(Exception):
    """Raised when benchmark provenance self-test setup is malformed."""


def obj(value: JsonValue | None, context: str) -> JsonObject:
    if not isinstance(value, dict):
        raise MatrixBenchmarkSelfTestError(f"{context} must be an object")
    return value


def text(value: JsonValue | None, context: str) -> str:
    if not isinstance(value, str) or value == "":
        raise MatrixBenchmarkSelfTestError(f"{context} must be non-empty text")
    return value


def write_json(path: Path, data: JsonObject) -> None:
    _ = path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")


def file_sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def first_benchmark_entry(spec_data: JsonObject) -> JsonObject:
    entries = spec_data.get("benchmark_provenance")
    if not isinstance(entries, list) or not entries:
        raise MatrixBenchmarkSelfTestError("manifest self-test benchmark_provenance setup missing")
    return obj(entries[0], "manifest self-test benchmark_provenance[0]")


def workload_spec(row_data: JsonObject) -> tuple[JsonObject, JsonObject, Path]:
    workload = obj(row_data.get("workload"), "manifest self-test workload")
    spec_path = Path(text(workload.get("spec_path"), "manifest self-test workload.spec_path"))
    return workload, load_json(spec_path), spec_path


def apply_case(name: str, manifest_path: Path, artifact_path: Path, assert_invalid: InvalidManifestAsserter) -> None:
    row_data = load_json(artifact_path)
    workload, spec_data, spec_path = workload_spec(row_data)
    if name == "workload-benchmark-provenance-missing":
        first_entry = first_benchmark_entry(spec_data)
        Path(text(first_entry.get("record_path"), "manifest self-test benchmark_provenance[0].record_path")).unlink()
        assert_invalid(manifest_path, name, "missing referenced artifact")
        return
    if name == "workload-calibrated-benchmark-provenance-absent":
        apply_calibrated_absent(name, manifest_path, artifact_path, assert_invalid, row_data, workload, spec_data, spec_path)
        return
    if name == "workload-benchmark-provenance-malformed":
        mutate_record(name, manifest_path, artifact_path, assert_invalid, row_data, workload, spec_data, spec_path, "unexpected_field_not_in_schema", "reject")
        return
    if name == "workload-benchmark-provenance-claim":
        mutate_record(name, manifest_path, artifact_path, assert_invalid, row_data, workload, spec_data, spec_path, "production_capacity_claim", True)
        return
    raise MatrixBenchmarkSelfTestError(f"unknown benchmark provenance self-test case: {name}")


def apply_calibrated_absent(name: str, manifest_path: Path, artifact_path: Path, assert_invalid: InvalidManifestAsserter, row_data: JsonObject, workload: JsonObject, spec_data: JsonObject, spec_path: Path) -> None:
    manifest = load_json(manifest_path)
    rows = manifest.get("rows")
    if not isinstance(rows, list) or not rows:
        raise MatrixBenchmarkSelfTestError("manifest self-test rows setup missing")
    row_data["scenario_id"] = "fixture-pass"
    workload["name"] = "cpu-smoke"
    spec_data["scenario_id"] = "fixture-pass"
    spec_data["workload_class"] = "cpu-smoke"
    spec_data["name"] = "cpu-smoke"
    spec_data["required_tools"] = ["builtin-churn"]
    spec_data["threshold_source"] = "calibrated"
    thresholds = obj(spec_data.get("thresholds"), "manifest self-test workload.spec.thresholds")
    thresholds["source"] = "calibrated"
    del spec_data["benchmark_provenance"]
    write_json(spec_path, spec_data)
    workload["spec_sha256"] = file_sha256(spec_path)
    write_json(artifact_path, row_data)
    manifest_row = obj(rows[0], "manifest self-test manifest row")
    manifest_row["scenario_id"] = "fixture-pass"
    write_json(manifest_path, manifest)
    assert_invalid(manifest_path, name, "benchmark_provenance required when threshold_source is calibrated")


def mutate_record(name: str, manifest_path: Path, artifact_path: Path, assert_invalid: InvalidManifestAsserter, row_data: JsonObject, workload: JsonObject, spec_data: JsonObject, spec_path: Path, key: str, value: JsonValue) -> None:
    first_entry = first_benchmark_entry(spec_data)
    record_path = Path(text(first_entry.get("record_path"), "manifest self-test benchmark_provenance[0].record_path"))
    record = load_json(record_path)
    record[key] = value
    write_json(record_path, record)
    first_entry["record_sha256"] = file_sha256(record_path)
    write_json(spec_path, spec_data)
    workload["spec_sha256"] = file_sha256(spec_path)
    write_json(artifact_path, row_data)
    assert_invalid(manifest_path, name, "invalid benchmark provenance")
