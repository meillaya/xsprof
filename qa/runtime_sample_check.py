#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
# ─── How to run ───
# 1. Install uv (if not installed):
#      curl -LsSf https://astral.sh/uv/install.sh | sh
# 2. Run directly:
#      uv run qa/runtime_sample_check.py --input evidence/lab/observe-partial/runtime-samples.jsonl
# 3. Or with system Python (no dependencies):
#      python3 qa/runtime_sample_check.py --self-test
# ──────────────────
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import json
import shutil
import sys
from typing import Final, TypeAlias

JsonValue: TypeAlias = None | bool | int | float | str | list["JsonValue"] | dict[str, "JsonValue"]
JsonObject: TypeAlias = dict[str, JsonValue]

SAMPLE_SCHEMA: Final[str] = "zig-scheduler/runtime-sample/v1"
FORBIDDEN_KEYS: Final[frozenset[str]] = frozenset({"command_line", "cmdline", "argv", "args", "environment", "env", "secret", "token", "api_key"})
FORBIDDEN_TEXT: Final[tuple[str, ...]] = ("--token", "api_key=", "AWS_SECRET", "BEGIN PRIVATE KEY", "password=")


@dataclass(frozen=True, slots=True)
class Args:
    input_path: Path | None
    self_test: bool


class RuntimeSampleError(Exception):
    """Raised when runtime sample evidence is malformed or privacy-unsafe."""


def parse_args(argv: list[str]) -> Args:
    if argv == ["--self-test"]:
        return Args(input_path=None, self_test=True)
    if len(argv) == 2 and argv[0] == "--input":
        return Args(input_path=Path(argv[1]), self_test=False)
    raise RuntimeSampleError("usage: runtime_sample_check.py --input <runtime-samples.jsonl> | --self-test")


def load_jsonl(path: Path) -> list[JsonObject]:
    rows: list[JsonObject] = []
    try:
        lines = path.read_text().splitlines()
    except FileNotFoundError as exc:
        raise RuntimeSampleError(f"missing JSONL file: {path}") from exc
    for index, line in enumerate(lines, start=1):
        if line.strip() == "":
            continue
        try:
            raw: JsonValue = json.loads(line)
        except json.JSONDecodeError as exc:
            raise RuntimeSampleError(f"invalid JSON on line {index}: {exc}") from exc
        if not isinstance(raw, dict):
            raise RuntimeSampleError(f"line {index} must contain a JSON object")
        rows.append(raw)
    if not rows:
        raise RuntimeSampleError("runtime sample JSONL is empty")
    return rows


def require_string(data: JsonObject, field: str, context: str) -> str:
    value = data.get(field)
    if not isinstance(value, str) or value == "":
        raise RuntimeSampleError(f"{context} missing non-empty string field: {field}")
    return value


def require_bool(data: JsonObject, field: str, context: str) -> bool:
    value = data.get(field)
    if not isinstance(value, bool):
        raise RuntimeSampleError(f"{context} missing bool field: {field}")
    return value


def require_int(data: JsonObject, field: str, context: str) -> int:
    value = data.get(field)
    if not isinstance(value, int):
        raise RuntimeSampleError(f"{context} missing int field: {field}")
    return value


def require_object(data: JsonObject, field: str, context: str) -> JsonObject:
    value = data.get(field)
    if not isinstance(value, dict):
        raise RuntimeSampleError(f"{context} missing object field: {field}")
    return value


def validate_fact(data: JsonObject, field: str, context: str) -> None:
    fact = require_object(data, field, context)
    status = require_string(fact, "status", f"{context}.{field}")
    if status not in {"present", "missing", "unreadable", "unknown"}:
        raise RuntimeSampleError(f"{context}.{field} has unsupported status: {status}")
    value = fact.get("value")
    if not isinstance(value, str) or (status == "present" and value == ""):
        raise RuntimeSampleError(f"{context}.{field} has invalid value")


def reject_private_leaks(value: JsonValue, context: str) -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            lowered = key.lower()
            if lowered in FORBIDDEN_KEYS:
                raise RuntimeSampleError(f"privacy-unsafe key in runtime sample: {context}.{key}")
            reject_private_leaks(child, f"{context}.{key}")
        return
    if isinstance(value, list):
        for index, child in enumerate(value):
            reject_private_leaks(child, f"{context}[{index}]")
        return
    if isinstance(value, str):
        for needle in FORBIDDEN_TEXT:
            if needle in value:
                raise RuntimeSampleError(f"privacy-unsafe text in runtime sample: {context}")


def validate_sample(row: JsonObject, index: int) -> None:
    context = f"sample[{index}]"
    reject_private_leaks(row, context)
    if require_string(row, "schema", context) != SAMPLE_SCHEMA:
        raise RuntimeSampleError(f"{context} has unsupported schema")
    require_int(row, "sequence", context)
    for field in ("state", "ops", "enable_seq", "events", "nr_rejected", "debug_dump"):
        validate_fact(row, field, context)
    require_string(row, "events_hash", context)
    require_string(row, "cgroup_membership_digest", context)
    require_bool(row, "workload_alive", context)
    if require_bool(row, "private_command_lines_sampled", context):
        raise RuntimeSampleError(f"{context} sampled private command lines")


def validate_file(path: Path) -> None:
    for index, row in enumerate(load_jsonl(path)):
        validate_sample(row, index)


def good_sample() -> JsonObject:
    fact: JsonObject = {"status": "present", "value": "ok"}
    return {
        "schema": SAMPLE_SCHEMA,
        "sequence": 0,
        "state": {"status": "present", "value": "enabled"},
        "ops": {"status": "present", "value": "zigsched_minimal"},
        "enable_seq": {"status": "present", "value": "42"},
        "events": {"status": "present", "value": "nr_rejected: 0"},
        "events_hash": "ab12",
        "nr_rejected": fact,
        "debug_dump": {"status": "missing", "value": ""},
        "cgroup_membership_digest": "digest",
        "workload_alive": True,
        "private_command_lines_sampled": False,
    }


def reject(path: Path, label: str) -> None:
    try:
        validate_file(path)
    except RuntimeSampleError as exc:
        print(f"PASS reject {label}: {exc}")
        return
    raise RuntimeSampleError(f"expected rejection did not occur: {label}")


def self_test() -> None:
    root = Path("evidence/lab/runtime-sample-check-self-test")
    shutil.rmtree(root, ignore_errors=True)
    root.mkdir(parents=True)
    good = root / "good.jsonl"
    good.write_text(json.dumps(good_sample(), sort_keys=True) + "\n")
    validate_file(good)
    missing_privacy = root / "missing-privacy.jsonl"
    sample = good_sample()
    del sample["private_command_lines_sampled"]
    missing_privacy.write_text(json.dumps(sample, sort_keys=True) + "\n")
    reject(missing_privacy, "missing privacy flag")
    raw_command = root / "raw-command.jsonl"
    sample = good_sample()
    sample["command_line"] = "/usr/bin/demo --token secret"
    raw_command.write_text(json.dumps(sample, sort_keys=True) + "\n")
    reject(raw_command, "raw command line")
    missing_hash = root / "missing-events-hash.jsonl"
    sample = good_sample()
    del sample["events_hash"]
    missing_hash.write_text(json.dumps(sample, sort_keys=True) + "\n")
    reject(missing_hash, "missing events hash")
    shutil.rmtree(root)
    print("PASS runtime sample self-test: privacy-safe samples accepted and unsafe samples rejected")


def run(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.self_test:
        self_test()
        return 0
    if args.input_path is None:
        raise RuntimeSampleError("internal argument parser error")
    validate_file(args.input_path)
    print(f"PASS runtime sample schema: {args.input_path}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(run(sys.argv[1:]))
    except RuntimeSampleError as exc:
        print(f"FAIL runtime sample schema: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
