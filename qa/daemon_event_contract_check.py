#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from tempfile import TemporaryDirectory
from typing import Final, TypeAlias

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from qa.frontend_contract_pack_types import ContractPackError, parse_json_value

JsonValue: TypeAlias = None | bool | int | float | str | list["JsonValue"] | dict[str, "JsonValue"]
JsonObject: TypeAlias = dict[str, JsonValue]

SCHEMA: Final = "zig-scheduler/daemon-event/v1"
REQUIRED_LIFECYCLE: Final = frozenset({"boot", "marker", "verifier", "attach", "runtime_sample", "rollback", "cleanup", "validation", "incident"})
PRIVATE_NEEDLES: Final = ("cmdline", "command_line", "argv", "environment", '"env"', "secret", "api_key", "--token", "password=")
IDENTIFIER: Final = re.compile(r"^[A-Za-z0-9_.-]{1,96}$")
AUDIT_ID: Final = re.compile(r"^AUD-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{7,12}-[0-9a-f]{6}$")
SHA256_RE: Final = re.compile(r"^[0-9a-f]{64}$")
UNAVAILABLE_DIGESTS: Final = frozenset({"", "missing", "none", "null", "unavailable", "unknown"})


@dataclass(frozen=True, slots=True)
class Args:
    input: Path
    require_lifecycle: bool
    require_task9_lifecycle: bool
    self_test: bool


@dataclass(frozen=True, slots=True)
class EventRow:
    seq: int
    event: str
    host_mutation: bool
    raw: JsonObject


class ContractError(Exception):
    pass


class ParsedArgs(argparse.Namespace):
    input: Path
    require_lifecycle: bool
    require_task9_lifecycle: bool

    def __init__(self) -> None:
        super().__init__()
        self.input = Path()
        self.require_lifecycle = False
        self.require_task9_lifecycle = False


def parse_args(argv: list[str]) -> Args:
    if argv == ["--self-test"]:
        return Args(input=Path(), require_lifecycle=False, require_task9_lifecycle=False, self_test=True)
    parser = argparse.ArgumentParser(description="Validate daemon event JSONL schema/privacy contracts.")
    _ = parser.add_argument("--input", required=True, type=Path)
    _ = parser.add_argument("--require-lifecycle", action="store_true")
    _ = parser.add_argument("--require-task9-lifecycle", action="store_true")
    parsed = parser.parse_args(argv, namespace=ParsedArgs())
    return Args(input=parsed.input, require_lifecycle=parsed.require_lifecycle, require_task9_lifecycle=parsed.require_task9_lifecycle, self_test=False)


def parse_object(line: str, line_number: int) -> JsonObject:
    try:
        loaded = parse_json_value(line, f"line {line_number}")
    except ContractPackError as exc:
        raise ContractError(f"line {line_number}: invalid JSON: {exc}") from exc
    if not isinstance(loaded, dict):
        raise ContractError(f"line {line_number}: JSONL row is not an object")
    row: JsonObject = {}
    for key, value in loaded.items():
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


def require_artifact(row: EventRow, label: str) -> Path:
    artifact = Path(require_string(row.raw, "artifact", label))
    if artifact.is_absolute() or ".." in artifact.parts or not artifact.exists():
        raise ContractError(f"{label} artifact is unsafe or missing: {artifact}")
    return artifact


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


def load_jsonl_objects(path: Path, context: str) -> list[JsonObject]:
    rows: list[JsonObject] = []
    try:
        lines = path.read_text().splitlines()
    except FileNotFoundError as exc:
        raise ContractError(f"{context} artifact missing: {path}") from exc
    for line_number, line in enumerate(lines, 1):
        if not line.strip():
            continue
        rows.append(parse_object(line, line_number))
    if not rows:
        raise ContractError(f"{context} artifact is empty: {path}")
    return rows


def require_object(row: JsonObject, field: str, context: str) -> JsonObject:
    value = row.get(field)
    if not isinstance(value, dict):
        raise ContractError(f"{context}: missing object field {field}")
    return value


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


def require_task9_lifecycle(path: Path) -> None:
    rows = load_rows(path)
    events = {row.event for row in rows}
    missing = sorted(REQUIRED_LIFECYCLE - events)
    if missing:
        raise ContractError(f"missing lifecycle events: {', '.join(missing)}")
    states = {require_string(row.raw, "state", f"event {row.seq}") for row in rows}
    for state in ("vm_live_validated", "stale_target_refused", "duplicate_rollback_refused"):
        if state not in states:
            raise ContractError(f"missing Task 9 state: {state}")
    verifier = find_event(rows, "verifier")
    attach = find_event(rows, "attach")
    runtime = find_event(rows, "runtime_sample")
    rollback = find_event(rows, "rollback")
    runtime_artifact = require_artifact(runtime, "runtime_sample")
    rollback_artifact = require_artifact(rollback, "rollback")
    for row, label in ((verifier, "verifier"), (attach, "attach")):
        _ = require_artifact(row, label)
    if runtime.raw.get("ops") != "zigsched_minimal":
        raise ContractError("runtime_sample does not show zigsched_minimal")
    validate_task9_runtime_samples(runtime_artifact)
    rollback_ids = validate_task9_rollback_link(rollback, rollback_artifact)
    for row in rows:
        if row.raw.get("state") in {"stale_target_refused", "duplicate_rollback_refused"}:
            if row.raw.get("status") not in {"REFUSE", "refused"}:
                raise ContractError(f"event {row.seq}: refusal state must use refused status")
            if row.host_mutation is not False:
                raise ContractError(f"event {row.seq}: refusal must be host_mutation=false")
            validate_task9_refusal_link(row, rollback_ids)


def validate_task9_runtime_samples(path: Path) -> None:
    rows = load_jsonl_objects(path, "runtime_sample")
    saw_live_ops = False
    for index, row in enumerate(rows):
        if row.get("observation_source") != "vm_serial_sched_ext":
            raise ContractError(f"runtime sample {index}: missing VM observation source")
        if row.get("sample_source_event") not in {"before", "register", "unregister"}:
            raise ContractError(f"runtime sample {index}: unsupported sample source event")
        ops = require_object(row, "ops", f"runtime sample {index}")
        if ops.get("value") == "zigsched_minimal":
            saw_live_ops = True
        digest = row.get("cgroup_membership_digest")
        if not isinstance(digest, str) or not SHA256_RE.match(digest) or digest == "0" * 64 or digest.lower() in UNAVAILABLE_DIGESTS:
            raise ContractError(f"runtime sample {index}: missing observed sha256 cgroup digest")
        cgroup_status = require_object(row, "cgroup_membership_status", f"runtime sample {index}")
        if cgroup_status.get("status") != "present" or cgroup_status.get("value") != "present":
            raise ContractError(f"runtime sample {index}: cgroup membership was not observed present")
        if not isinstance(row.get("workload_alive"), bool):
            raise ContractError(f"runtime sample {index}: missing observed workload state")
    if not saw_live_ops:
        raise ContractError("runtime samples never observed zigsched_minimal")


def validate_task9_rollback_link(rollback: EventRow, ledger_path: Path) -> tuple[str, str]:
    ledger = load_jsonl_objects(ledger_path, "rollback")[0]
    ledger_rollback_id = require_string(ledger, "rollback_id", "rollback ledger")
    ledger_audit_id = require_string(ledger, "audit_id", "rollback ledger")
    daemon_rollback_id = require_string(rollback.raw, "rollback_id", f"event {rollback.seq}")
    daemon_audit_id = require_string(rollback.raw, "audit_id", f"event {rollback.seq}")
    if daemon_rollback_id != ledger_rollback_id or daemon_audit_id != ledger_audit_id:
        raise ContractError("daemon rollback event IDs do not match audit ledger")
    return ledger_rollback_id, ledger_audit_id


def validate_task9_refusal_link(row: EventRow, rollback_ids: tuple[str, str]) -> None:
    rollback_id, audit_id = rollback_ids
    if require_string(row.raw, "rollback_id", f"event {row.seq}") != rollback_id:
        raise ContractError(f"event {row.seq}: refusal rollback_id does not match ledger")
    if require_string(row.raw, "audit_id", f"event {row.seq}") != audit_id:
        raise ContractError(f"event {row.seq}: refusal audit_id does not match ledger")
    artifact = require_artifact(row, f"event {row.seq}")
    refusals = load_jsonl_objects(artifact, f"event {row.seq} refusal")
    matching = [item for item in refusals if item.get("state") == row.raw.get("state")]
    if not matching:
        raise ContractError(f"event {row.seq}: refusal artifact missing state")
    refusal = matching[0]
    if refusal.get("rollback_id") != rollback_id or refusal.get("audit_id") != audit_id:
        raise ContractError(f"event {row.seq}: refusal artifact IDs do not match ledger")
    if row.raw.get("state") == "stale_target_refused" and refusal.get("refusal_path") != "refuse_stale_rollback_target":
        raise ContractError(f"event {row.seq}: stale refusal was not produced by VM refusal path")
    if row.raw.get("state") == "duplicate_rollback_refused":
        bpftool_rc = refusal.get("bpftool_rc")
        if not isinstance(bpftool_rc, int) or bpftool_rc == 0:
            raise ContractError(f"event {row.seq}: duplicate refusal lacks failing bpftool rc")


def find_event(rows: list[EventRow], event: str) -> EventRow:
    for row in rows:
        if row.event == event:
            return row
    raise ContractError(f"missing event: {event}")


def write_self_test_rows(path: Path, rows: list[JsonObject]) -> None:
    _ = path.write_text("".join(json.dumps(row, sort_keys=True) + "\n" for row in rows))


def run_self_test() -> None:
    good: JsonObject = {
        "schema": SCHEMA,
        "seq": 1,
        "event": "incident",
        "status": "unsafe_to_assume",
        "state": "unsafe_to_assume",
        "reason": "missing_attestation",
        "host_mutation": False,
    }
    with TemporaryDirectory(prefix="zigsched-daemon-event-contract-") as tmp:
        root = Path(tmp)
        good_path = root / "good.jsonl"
        write_self_test_rows(good_path, [good])
        validate(good_path, False)

        def reject(label: str, row: JsonObject) -> None:
            bad_path = root / f"{label}.jsonl"
            write_self_test_rows(bad_path, [row])
            try:
                validate(bad_path, False)
            except ContractError as exc:
                print(f"PASS daemon self-test rejected {label}: {exc}")
            else:
                raise ContractError(f"self-test failed to reject {label}")

        host_mutation: JsonObject = dict(good)
        host_mutation["host_mutation"] = True
        reject("host-mutation-true", host_mutation)

        private_key: JsonObject = dict(good)
        private_key["environment"] = "redacted"
        reject("private-field", private_key)

        private_text: JsonObject = dict(good)
        private_text["state"] = "password=redacted"
        reject("private-text", private_text)

        bad_seq: JsonObject = dict(good)
        bad_seq["seq"] = 2
        reject("nonmonotonic-seq", bad_seq)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    try:
        if args.self_test:
            run_self_test()
        else:
            validate(args.input, args.require_lifecycle)
            if args.require_task9_lifecycle:
                require_task9_lifecycle(args.input)
    except ContractError as exc:
        print(f"FAIL daemon event contract: {exc}", file=sys.stderr)
        return 1
    print(f"PASS daemon event contract: {args.input}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
