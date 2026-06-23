#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
# ─── How to run ───
# python3 qa/daemon_golden_transcript_check.py --daemon zig-out/bin/zig-scheduler-daemon --fixtures fixtures/control/golden
"""Validate daemon golden transcript fixtures for safe live lifecycle UX."""

from __future__ import annotations

import json
import sys
from dataclasses import dataclass
from pathlib import Path
from tempfile import TemporaryDirectory
from typing import Final

JsonValue = None | bool | int | float | str | list["JsonValue"] | dict[str, "JsonValue"]
JsonObject = dict[str, JsonValue]

SCHEMA: Final = "zig-scheduler/daemon-event/v1"
REQUIRED_SCENARIOS: Final = (
    "queued",
    "booting",
    "verifier",
    "attached-partial-switch-lab",
    "observing",
    "rollback-ready",
    "rollback-active",
    "cleaned",
    "incident",
    "malformed-action",
    "stale-target",
    "duplicate-target",
    "stream-backpressure",
    "stale-git",
    "privacy-rejection",
)
EVENTS: Final = {"boot", "marker", "verifier", "attach", "state_changed", "stage_started", "stage_finished", "microvm_boot", "vm_marker", "bpf_register", "runtime_sample", "rollback", "cleanup", "validation", "incident", "refusal", "lab_run_active", "journal_record", "rollback_completed"}
FORBIDDEN_KEYS: Final = {"command", "shell", "argv", "env", "environment", "secret", "api_key", "token", "password"}
FORBIDDEN_TEXT: Final = ("--token", "password=", "api_key", "AWS_SECRET", "BEGIN PRIVATE KEY")
PATH_FIELDS: Final = ("artifact", "live_bundle_path")


@dataclass(frozen=True, slots=True)
class Args:
    daemon: Path | None
    fixtures: Path
    self_test: bool


class DaemonGoldenError(Exception):
    """Raised when daemon golden transcripts drift or leak unsafe data."""


def parse_args(argv: list[str]) -> Args:
    if argv == ["--self-test"]:
        return Args(None, Path("fixtures/control/golden"), True)
    if len(argv) == 4 and argv[0] == "--daemon" and argv[2] == "--fixtures":
        return Args(Path(argv[1]), Path(argv[3]), False)
    if len(argv) == 2 and argv[0] == "--fixtures":
        return Args(None, Path(argv[1]), False)
    raise DaemonGoldenError("usage: daemon_golden_transcript_check.py --daemon <bin> --fixtures <dir> | --fixtures <dir> | --self-test")


def load_jsonl(path: Path) -> list[JsonObject]:
    rows: list[JsonObject] = []
    for line_number, line in enumerate(path.read_text().splitlines(), start=1):
        if not line.strip():
            continue
        try:
            raw = json.loads(line)
        except json.JSONDecodeError as exc:
            raise DaemonGoldenError(f"invalid JSON in {path}:{line_number}: {exc}") from exc
        if not isinstance(raw, dict):
            raise DaemonGoldenError(f"{path}:{line_number} is not an object")
        rows.append(raw)
    if not rows:
        raise DaemonGoldenError(f"empty fixture: {path}")
    return rows


def reject_private(value: JsonValue, context: str) -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            if key.lower() in FORBIDDEN_KEYS:
                raise DaemonGoldenError(f"privacy-unsafe key in {context}.{key}")
            reject_private(child, f"{context}.{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            reject_private(child, f"{context}[{index}]")
    elif isinstance(value, str):
        for needle in FORBIDDEN_TEXT:
            if needle in value:
                raise DaemonGoldenError(f"privacy-unsafe text in {context}")


def require_safe_path(raw: JsonValue, context: str) -> None:
    if raw is None:
        return
    if not isinstance(raw, str) or raw == "":
        raise DaemonGoldenError(f"{context} path must be text")
    path = Path(raw)
    if path.is_absolute() or ".." in path.parts:
        raise DaemonGoldenError(f"{context} path escapes repo: {raw}")


def validate_row(row: JsonObject, path: Path, expected_seq: int) -> None:
    if row.get("schema") != SCHEMA:
        raise DaemonGoldenError(f"{path} bad schema")
    if row.get("seq") != expected_seq:
        raise DaemonGoldenError(f"{path} nonmonotonic seq: expected {expected_seq}")
    event = row.get("event")
    if not isinstance(event, str) or event not in EVENTS:
        raise DaemonGoldenError(f"{path} invalid event: {event}")
    status = row.get("status")
    if not isinstance(status, str) or status == "":
        raise DaemonGoldenError(f"{path} missing status")
    if row.get("host_mutation") is not False:
        raise DaemonGoldenError(f"{path} host_mutation must be false")
    reject_private(row, str(path))
    for field in PATH_FIELDS:
        require_safe_path(row.get(field), f"{path}.{field}")


def validate_fixture(path: Path) -> None:
    for expected_seq, row in enumerate(load_jsonl(path), start=1):
        validate_row(row, path, expected_seq)


def validate_all(fixtures: Path, daemon: Path | None) -> None:
    if daemon is not None and not daemon.exists():
        raise DaemonGoldenError(f"daemon binary missing: {daemon}")
    missing = [name for name in REQUIRED_SCENARIOS if not (fixtures / f"{name}.jsonl").is_file()]
    if missing:
        raise DaemonGoldenError("missing golden fixture(s): " + ", ".join(missing))
    for name in REQUIRED_SCENARIOS:
        validate_fixture(fixtures / f"{name}.jsonl")


def run_self_test(args: Args) -> None:
    validate_all(args.fixtures, None)
    with TemporaryDirectory(prefix="zigsched-daemon-golden-") as tmp:
        bad_dir = Path(tmp)
        bad = bad_dir / "queued.jsonl"
        bad.write_text(json.dumps({"schema": SCHEMA, "seq": 2, "event": "state_changed", "status": "ready", "host_mutation": False}) + "\n")
        try:
            validate_fixture(bad)
        except DaemonGoldenError as exc:
            print(f"PASS self-test rejected nonmonotonic seq: {exc}")
        else:
            raise DaemonGoldenError("self-test failed to reject nonmonotonic seq")
        bad.write_text(json.dumps({"schema": SCHEMA, "seq": 1, "event": "state_changed", "status": "ready", "host_mutation": True}) + "\n")
        try:
            validate_fixture(bad)
        except DaemonGoldenError as exc:
            print(f"PASS self-test rejected host mutation: {exc}")
            return
    raise DaemonGoldenError("self-test failed to reject host mutation")


def run(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.self_test:
        run_self_test(args)
    else:
        validate_all(args.fixtures, args.daemon)
        print(f"PASS daemon golden transcripts: fixtures={args.fixtures}")
    return 0


def main() -> int:
    try:
        return run(sys.argv[1:])
    except (OSError, UnicodeError, DaemonGoldenError) as exc:
        print(f"FAIL daemon golden transcripts: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
