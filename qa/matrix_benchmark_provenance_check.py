#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
# ─── How to run ───
# python3 qa/matrix_benchmark_provenance_check.py --self-test
"""Self-test matrix workload benchmark provenance references."""
from __future__ import annotations

import hashlib
import json
import shutil
import sys
from pathlib import Path
from tempfile import TemporaryDirectory

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from qa.matrix_benchmark_provenance import MatrixBenchmarkProvenanceError
from qa.matrix_benchmark_provenance import validate_entries

JsonValue = None | bool | int | float | str | list["JsonValue"] | dict[str, "JsonValue"]
JsonObject = dict[str, JsonValue]


def file_sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path: Path, data: JsonObject) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    _ = path.write_text(json.dumps(data, allow_nan=False, indent=2, sort_keys=True) + "\n")


def copied_fixture(root: Path) -> tuple[Path, Path]:
    raw = root / "bench" / "stress-ng.txt"
    record = root / "records" / "stress-ng.benchmark-output.json"
    raw.parent.mkdir(parents=True, exist_ok=True)
    record.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile("fixtures/benchmark-output/raw/stress-ng.txt", raw)
    shutil.copyfile("fixtures/benchmark-output/valid/stress-ng.benchmark-output.json", record)
    data = json.loads(record.read_text())
    if not isinstance(data, dict):
        raise MatrixBenchmarkProvenanceError("copied benchmark record must be an object")
    data["output_path"] = raw.as_posix()
    data["output_sha256"] = file_sha256(raw)
    data["vm_evidence"] = (root / "summary.json").as_posix()
    write_json(root / "summary.json", {"schema": "zig-scheduler/matrix-summary/v1", "host_mutation": False})
    write_json(record, data)
    return raw, record


def valid_entry(record: Path) -> JsonObject:
    return {"record_only": True, "record_path": record.as_posix(), "record_sha256": file_sha256(record)}


def expect_reject(label: str, entries: list[JsonValue], root: Path) -> None:
    try:
        validate_entries(entries, root, "self-test.benchmark_provenance")
    except MatrixBenchmarkProvenanceError as exc:
        print(f"PASS benchmark provenance self-test rejected {label}: {exc}")
        return
    raise MatrixBenchmarkProvenanceError(f"self-test failed to reject {label}")


def self_test() -> None:
    scratch = Path(".omo/tmp")
    scratch.mkdir(parents=True, exist_ok=True)
    with TemporaryDirectory(prefix="zigsched-benchmark-provenance-", dir=scratch) as tmp:
        root = Path(tmp).relative_to(Path.cwd())
        raw, record = copied_fixture(root)
        entry = valid_entry(record)
        validate_entries([entry], root, "self-test.benchmark_provenance")
        print("PASS benchmark provenance self-test accepted valid stress-ng record link")

        missing = dict(entry)
        missing["record_sha256"] = "0" * 64
        expect_reject("stale record hash", [missing], root)

        unsafe_path = dict(entry)
        unsafe_path["record_path"] = "../escape.json"
        expect_reject("traversing record path", [unsafe_path], root)

        stale_raw = dict(entry)
        _ = raw.write_text(raw.read_text() + "stress-ng: info: stale raw mutation\n")
        expect_reject("stale raw output hash", [stale_raw], root)

        _ = copied_fixture(root)
        claim = dict(entry)
        record_data = json.loads(record.read_text())
        if not isinstance(record_data, dict):
            raise MatrixBenchmarkProvenanceError("benchmark record must be an object")
        record_data["production_capacity_claim"] = True
        write_json(record, record_data)
        claim["record_sha256"] = file_sha256(record)
        expect_reject("claiming benchmark record", [claim], root)
    print("PASS benchmark provenance self-test")


def main(argv: list[str]) -> int:
    if argv != ["--self-test"]:
        print("usage: matrix_benchmark_provenance_check.py --self-test", file=sys.stderr)
        return 2
    try:
        self_test()
    except (OSError, json.JSONDecodeError, MatrixBenchmarkProvenanceError) as exc:
        print(f"FAIL benchmark provenance: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
