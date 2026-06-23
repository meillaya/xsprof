#!/usr/bin/env python3
"""Validate record-only VM performance calibration evidence."""

from __future__ import annotations

import json
import sys
from dataclasses import dataclass
from pathlib import Path
from tempfile import TemporaryDirectory
from typing import TypeAlias

JsonValue: TypeAlias = None | bool | int | float | str | list["JsonValue"] | dict[str, "JsonValue"]
JsonObject: TypeAlias = dict[str, JsonValue]


@dataclass(frozen=True, slots=True)
class Args:
    self_test: bool
    bundle: Path | None
    out: Path | None


class PerfCalibrationError(Exception):
    pass


def parse_args(argv: list[str]) -> Args:
    if argv == ["--self-test"]:
        return Args(True, None, None)
    if len(argv) == 4 and argv[0] == "--bundle" and argv[2] == "--out":
        return Args(False, Path(argv[1]), Path(argv[3]))
    raise PerfCalibrationError("usage: perf_calibration_evidence_check.py --self-test | --bundle <summary.json> --out <evidence.json>")


def load_object(path: Path) -> JsonObject:
    try:
        raw = json.loads(path.read_text())
    except FileNotFoundError as exc:
        raise PerfCalibrationError(f"missing JSON file: {path}") from exc
    if not isinstance(raw, dict):
        raise PerfCalibrationError(f"JSON root must be object: {path}")
    return raw


def require(condition: bool, message: str) -> None:
    if not condition:
        raise PerfCalibrationError(message)


def text(data: JsonObject, key: str) -> str:
    value = data.get(key)
    if not isinstance(value, str) or value == "":
        raise PerfCalibrationError(f"missing text field: {key}")
    return value


def build_evidence(bundle: Path) -> JsonObject:
    summary = load_object(bundle)
    require(summary.get("schema") == "zig-scheduler/run-all-lab/v1", "bundle schema mismatch")
    require(summary.get("status") == "PASS", "bundle must pass before calibration is recorded")
    require(summary.get("host_mutation") is False, "bundle host_mutation must be false")
    sample_path = find_runtime_samples(summary)
    sample_count = sum(1 for line in sample_path.read_text().splitlines() if line.strip())
    require(sample_count > 0, "runtime samples are empty")
    return {
        "schema": "zig-scheduler/perf-calibration-evidence/v1",
        "status": "RECORDED",
        "evidence_mode": "vm-live-record-only",
        "source_bundle": bundle.as_posix(),
        "runtime_samples": sample_path.as_posix(),
        "sample_count": sample_count,
        "threshold_status": "record_only",
        "hard_thresholds_enforced": False,
        "production_capacity_claim": False,
        "release_eligible": False,
        "host_mutation": False,
    }


def find_runtime_samples(summary: JsonObject) -> Path:
    for value in summary.get("artifact_paths", []):
        if isinstance(value, str) and value.endswith("observe-partial/runtime-samples.jsonl"):
            path = Path(value)
            if path.is_file():
                return path
    raise PerfCalibrationError("bundle missing runtime sample artifact")


def validate_evidence(data: JsonObject) -> None:
    require(data.get("schema") == "zig-scheduler/perf-calibration-evidence/v1", "bad schema")
    require(data.get("status") == "RECORDED", "status must be RECORDED")
    require(data.get("evidence_mode") == "vm-live-record-only", "evidence mode must be record-only")
    require(text(data, "threshold_status") == "record_only", "threshold status must be record_only")
    require(data.get("hard_thresholds_enforced") is False, "hard thresholds are forbidden")
    require(data.get("production_capacity_claim") is False, "production capacity claim is forbidden")
    require(data.get("release_eligible") is False, "calibration evidence is not release eligible")
    require(data.get("host_mutation") is False, "host_mutation must be false")
    sample_count = data.get("sample_count")
    require(isinstance(sample_count, int) and sample_count > 0, "sample_count must be positive")


def self_test() -> None:
    good = {
        "schema": "zig-scheduler/perf-calibration-evidence/v1",
        "status": "RECORDED",
        "evidence_mode": "vm-live-record-only",
        "source_bundle": "bundle.json",
        "runtime_samples": "runtime-samples.jsonl",
        "sample_count": 3,
        "threshold_status": "record_only",
        "hard_thresholds_enforced": False,
        "production_capacity_claim": False,
        "release_eligible": False,
        "host_mutation": False,
    }
    validate_evidence(good)
    for label, key, value in (
        ("hard-threshold", "hard_thresholds_enforced", True),
        ("prod-capacity", "production_capacity_claim", True),
        ("pass-threshold", "threshold_status", "PASS"),
    ):
        bad = dict(good)
        bad[key] = value
        try:
            validate_evidence(bad)
        except PerfCalibrationError as exc:
            print(f"PASS reject {label}: {exc}")
        else:
            raise PerfCalibrationError(f"expected rejection did not occur: {label}")
    with TemporaryDirectory(prefix="zigsched-perf-calibration-") as tmp:
        root = Path(tmp)
        samples = root / "observe-partial" / "runtime-samples.jsonl"
        samples.parent.mkdir()
        samples.write_text('{"sample":0}\n')
        bundle = root / "summary.json"
        bundle.write_text(json.dumps({"schema":"zig-scheduler/run-all-lab/v1","status":"PASS","host_mutation":False,"artifact_paths":[samples.as_posix()]}) + "\n")
        validate_evidence(build_evidence(bundle))
    print("PASS perf calibration self-test")


def run(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.self_test:
        self_test()
        return 0
    if args.bundle is None or args.out is None:
        raise PerfCalibrationError("bundle/out required")
    evidence = build_evidence(args.bundle)
    validate_evidence(evidence)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n")
    print(f"PASS perf calibration evidence: {args.out}")
    return 0


def main() -> int:
    try:
        return run(sys.argv[1:])
    except (OSError, UnicodeError, json.JSONDecodeError, PerfCalibrationError) as exc:
        print(f"FAIL perf calibration evidence: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
