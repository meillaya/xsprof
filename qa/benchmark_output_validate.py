#!/usr/bin/env python3
"""Validate benchmark-output/v1 records and committed fixtures."""
from __future__ import annotations

import math
from pathlib import Path

from qa.benchmark_output_io import load_json, load_schema
from qa.benchmark_output_model import REQUIRED, SCHEMA, SHA256_RE, SUPPORTED, UNSUPPORTED, BenchmarkOutputError, JsonObject, family, require
from qa.benchmark_output_parse import build_record, tool_for
from qa.benchmark_output_privacy import reject_private_leaks, safe_relative


def validate_record(record: JsonObject) -> None:
    reject_private_leaks(record, "record")
    extra = sorted(set(record) - set(REQUIRED))
    missing = sorted(set(REQUIRED) - set(record))
    require(not extra, f"unexpected fields: {', '.join(extra)}")
    require(not missing, f"missing fields: {', '.join(missing)}")
    require(record["schema"] == SCHEMA, "schema mismatch")
    status_value = record["status"]
    require(status_value in {"RECORDED", "UNSUPPORTED_DEFERRED"}, "bad status")
    status = str(status_value)
    command_family = family(str(record["command_family"]))
    require(record["tool"] == tool_for(command_family), "tool/family mismatch")
    _ = safe_relative(record["output_path"], "output_path")
    _ = safe_relative(record["vm_evidence"], "vm_evidence")
    require(isinstance(record["output_sha256"], str) and SHA256_RE.match(record["output_sha256"]) is not None, "output_sha256 must be lowercase sha256")
    require(record["host_mutation"] is False, "host_mutation must be false")
    require(record["release_eligible"] is False, "release_eligible must be false")
    require(record["production_capacity_claim"] is False, "production capacity claims are forbidden")
    require(record["hard_thresholds_enforced"] is False, "hard thresholds are forbidden")
    require(record["threshold_status"] == "record_only", "threshold status must be record_only")
    require(record["privacy_sanitized"] is True, "privacy_sanitized must be true")
    metrics_value = record["metrics"]
    units_value = record["units"]
    require(isinstance(metrics_value, dict) and isinstance(units_value, dict), "metrics and units must be objects")
    metrics: JsonObject = metrics_value if isinstance(metrics_value, dict) else {}
    units: JsonObject = units_value if isinstance(units_value, dict) else {}
    for name, value in metrics.items():
        require(isinstance(value, int | float) and not isinstance(value, bool) and math.isfinite(value) and value >= 0, f"invalid metric: {name}")
        unit = units.get(name)
        require(isinstance(unit, str) and unit != "", f"missing metric unit: {name}")
    samples_value = record["sample_count"]
    runs_value = record["run_count"]
    require(isinstance(samples_value, int) and isinstance(runs_value, int), "counts must be integers")
    samples = samples_value if isinstance(samples_value, int) else 0
    runs = runs_value if isinstance(runs_value, int) else 0
    if status == "RECORDED":
        require(str(record["command_family"]) in SUPPORTED, "recorded family must be supported")
        require(bool(metrics), "recorded artifacts require metrics")
        require(samples > 0 and runs > 0, "recorded counts must be positive")
    else:
        require(str(record["command_family"]) in UNSUPPORTED, "deferred family must be unsupported")
        require(metrics == {} and units == {}, "deferred artifacts must not include metrics")
        require(samples == 0 and runs == 0, "deferred counts must be zero")


def run_fixtures(root: Path, schema: Path) -> None:
    require(schema.is_file(), f"missing schema: {schema}")
    schema_doc = load_schema(schema)
    require(schema_doc.get("$id") == SCHEMA, "schema id mismatch")
    require(schema_doc.get("additionalProperties") is False, "schema must be closed")
    valid = sorted((root / "valid").glob("*.json"))
    invalid = sorted((root / "invalid").iterdir())
    require(bool(valid), "no valid benchmark fixtures")
    require(bool(invalid), "no invalid benchmark fixtures")
    for path in valid:
        validate_record(load_json(path))
        print(f"PASS valid fixture: {path}")
    for path in invalid:
        try:
            if path.suffix == ".json":
                validate_record(load_json(path))
            else:
                _ = build_record("perf_bench_sched_messaging", path, "evidence/lab/run/bench/bad.txt", "evidence/lab/run/summary.json")
        except BenchmarkOutputError as exc:
            print(f"PASS reject invalid fixture {path.name}: {exc}")
        else:
            raise BenchmarkOutputError(f"invalid fixture unexpectedly accepted: {path}")
    print(f"PASS benchmark fixtures: valid={len(valid)} invalid={len(invalid)}")
