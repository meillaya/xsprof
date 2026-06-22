#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Final, TypeAlias

JsonValue: TypeAlias = None | bool | int | float | str | list["JsonValue"] | dict[str, "JsonValue"]
JsonObject: TypeAlias = dict[str, JsonValue]

SCHEMA: Final = "zig-scheduler/daemon-event/v1"
REQUIRED_LIFECYCLE: Final = frozenset({
    "boot",
    "marker",
    "verifier",
    "attach",
    "runtime_sample",
    "rollback",
    "cleanup",
    "validation",
    "incident",
})
PRIVATE_NEEDLES: Final = ("cmdline", "command_line", "argv", "environment", '"env"', "secret", "api_key", "--token", "password=")
IDENTIFIER: Final = re.compile(r"^[A-Za-z0-9_.-]{1,96}$")
AUDIT_ID: Final = re.compile(r"^AUD-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{7,12}-[0-9a-f]{6}$")


@dataclass(frozen=True, slots=True)
class Args:
    input: Path
    require_lifecycle: bool


@dataclass(frozen=True, slots=True)
class EventRow:
    seq: int
    event: str
    host_mutation: bool
    raw: JsonObject


class ContractError(Exception):
    pass


def parse_args(argv: list[str]) -> Args:
    parser = argparse.ArgumentParser(description="Validate daemon event JSONL schema/privacy contracts.")
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--require-lifecycle", action="store_true")
    parsed = parser.parse_args(argv)
    return Args(input=parsed.input, require_lifecycle=parsed.require_lifecycle)


def parse_object(line: str, line_number: int) -> JsonObject:
    try:
        loaded = json.loads(line)
    except json.JSONDecodeError as exc:
        raise ContractError(f"line {line_number}: invalid JSON: {exc}") from exc
    if not isinstance(loaded, dict):
        raise ContractError(f"line {line_number}: JSONL row is not an object")
    row: JsonObject = {}
    for key, value in loaded.items():
        if not isinstance(key, str):
            raise ContractError(f"line {line_number}: JSON object key is not a string")
        row[key] = value
    return row


def require_int(row: JsonObject, field: str, context: str) -> int:
    value = row.get(field)
    if not isinstance(value, int):
        raise ContractError(f"{context}: missing int field {field}")
    return value


def require_string(row: JsonObject, field: str, context: str) -> str:
    value = row.get(field)
    if not isinstance(value, str) or value == "":
        raise ContractError(f"{context}: missing string field {field}")
    return value


def require_bool(row: JsonObject, field: str, context: str) -> bool:
    value = row.get(field)
    if not isinstance(value, bool):
        raise ContractError(f"{context}: missing bool field {field}")
    return value


def load_rows(path: Path) -> list[EventRow]:
    rows: list[EventRow] = []
    for line_number, line in enumerate(path.read_text().splitlines(), 1):
        if not line.strip():
            continue
        raw = parse_object(line, line_number)
        rows.append(EventRow(
            seq=require_int(raw, "seq", f"line {line_number}"),
            event=require_string(raw, "event", f"line {line_number}"),
            host_mutation=require_bool(raw, "host_mutation", f"line {line_number}"),
            raw=raw,
        ))
    if not rows:
        raise ContractError("event stream is empty")
    return rows


def validate_identifier(row: EventRow, field: str) -> None:
    value = row.raw.get(field)
    if value is None or value == "":
        return
    if not isinstance(value, str) or not IDENTIFIER.fullmatch(value):
        raise ContractError(f"event {row.seq}: invalid {field}")


def validate_row(row: EventRow, expected_seq: int) -> None:
    if row.raw.get("schema") != SCHEMA:
        raise ContractError(f"event {expected_seq}: unsupported schema")
    if row.seq != expected_seq:
        raise ContractError(f"event sequence is not incremental: expected {expected_seq}, got {row.seq}")
    if row.host_mutation is not False:
        raise ContractError(f"event {expected_seq}: host_mutation must be false")
    for field in ("action_id", "run_id", "target_id", "rollback_id", "target_action_id"):
        validate_identifier(row, field)
    audit_id = row.raw.get("audit_id")
    if audit_id is not None and audit_id != "" and (not isinstance(audit_id, str) or not AUDIT_ID.fullmatch(audit_id)):
        raise ContractError(f"event {expected_seq}: invalid audit_id")
    if contains_private_field(row.raw):
        raise ContractError(f"event {expected_seq}: private field leaked")


def contains_private_field(value: JsonValue) -> bool:
    match value:
        case None | bool() | int() | float():
            return False
        case str() as text:
            return any(needle in text for needle in PRIVATE_NEEDLES)
        case list() as items:
            return any(contains_private_field(item) for item in items)
        case dict() as mapping:
            for key, item in mapping.items():
                if key == "command_argv_hash":
                    continue
                if any(needle in key for needle in PRIVATE_NEEDLES) or contains_private_field(item):
                    return True
            return False


def validate(path: Path, require_lifecycle: bool) -> None:
    rows = load_rows(path)
    for expected_seq, row in enumerate(rows, 1):
        validate_row(row, expected_seq)
    if require_lifecycle:
        events = {row.event for row in rows}
        missing = sorted(REQUIRED_LIFECYCLE - events)
        if missing:
            raise ContractError(f"missing lifecycle events: {', '.join(missing)}")


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    try:
        validate(args.input, args.require_lifecycle)
    except ContractError as exc:
        print(f"FAIL daemon event contract: {exc}", file=sys.stderr)
        return 1
    print(f"PASS daemon event contract: {args.input}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
