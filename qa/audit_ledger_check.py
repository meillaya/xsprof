#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
# ─── How to run ───
# 1. Install uv (if not installed): curl -LsSf https://astral.sh/uv/install.sh | sh
# 2. Run: uv run qa/audit_ledger_check.py --ledger evidence/lab/rollback-drill/audit-ledger.jsonl
# 3. Or: python3 qa/audit_ledger_check.py --self-test
# ──────────────────
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import hashlib
import json
import re
import shutil
import sys
from typing import Final, TypeAlias

JsonValue: TypeAlias = None | bool | int | float | str | list["JsonValue"] | dict[str, "JsonValue"]
JsonObject: TypeAlias = dict[str, JsonValue]

AUDIT_RE: Final[re.Pattern[str]] = re.compile(r"^AUD-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{7,12}-[0-9a-f]{6}$")
SECRET_RE: Final[re.Pattern[str]] = re.compile(r"secret|password|token|authorization|api[_-]?key", re.IGNORECASE)
LEDGER_SCHEMA: Final[str] = "zig-scheduler/audit-ledger/v1"
SNAPSHOT_SCHEMA: Final[str] = "zig-scheduler/rollback-snapshot/v1"


@dataclass(frozen=True, slots=True)
class Args:
    ledger: Path | None
    self_test: bool


class AuditLedgerError(Exception):
    """Raised when rollback audit ledger evidence is invalid."""


def parse_args(argv: list[str]) -> Args:
    if argv == ["--self-test"]:
        return Args(ledger=None, self_test=True)
    if len(argv) == 2 and argv[0] == "--ledger":
        return Args(ledger=Path(argv[1]), self_test=False)
    raise AuditLedgerError("usage: audit_ledger_check.py --ledger <audit-ledger.jsonl> | --self-test")


def load_object(path: Path) -> JsonObject:
    try:
        raw: JsonValue = json.loads(path.read_text())
    except FileNotFoundError as exc:
        raise AuditLedgerError(f"missing JSON file: {path}") from exc
    except json.JSONDecodeError as exc:
        raise AuditLedgerError(f"invalid JSON in {path}: {exc}") from exc
    if not isinstance(raw, dict):
        raise AuditLedgerError(f"{path} must contain a JSON object")
    return raw


def load_jsonl(path: Path) -> list[JsonObject]:
    rows: list[JsonObject] = []
    try:
        lines = path.read_text().splitlines()
    except FileNotFoundError as exc:
        raise AuditLedgerError(f"missing ledger: {path}") from exc
    for index, line in enumerate(lines, start=1):
        if line.strip() == "":
            continue
        try:
            raw: JsonValue = json.loads(line)
        except json.JSONDecodeError as exc:
            raise AuditLedgerError(f"invalid JSONL line {index}: {exc}") from exc
        if not isinstance(raw, dict):
            raise AuditLedgerError(f"line {index} must be a JSON object")
        rows.append(raw)
    if not rows:
        raise AuditLedgerError("ledger is empty")
    return rows


def require_string(data: JsonObject, field: str, context: str) -> str:
    value = data.get(field)
    if not isinstance(value, str) or value == "":
        raise AuditLedgerError(f"{context} missing non-empty string field: {field}")
    if SECRET_RE.search(value):
        raise AuditLedgerError(f"{context} contains secret-like field: {field}")
    return value


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def validate_record(row: JsonObject, seen: set[str], index: int) -> None:
    context = f"ledger[{index}]"
    if require_string(row, "schema", context) != LEDGER_SCHEMA:
        raise AuditLedgerError(f"{context} unsupported schema")
    audit_id = require_string(row, "audit_id", context)
    if not AUDIT_RE.match(audit_id):
        raise AuditLedgerError(f"{context} invalid audit_id")
    if audit_id in seen:
        raise AuditLedgerError(f"{context} duplicate audit_id: {audit_id}")
    seen.add(audit_id)
    rollback_id = require_string(row, "rollback_id", context)
    snapshot_path = Path(require_string(row, "rollback_snapshot", context))
    transcript_path = Path(require_string(row, "transcript", context))
    snapshot_sha = require_string(row, "rollback_snapshot_sha256", context)
    transcript_sha = require_string(row, "transcript_sha256", context)
    if not snapshot_path.is_file() or not transcript_path.is_file():
        raise AuditLedgerError(f"{context} transcript/snapshot artifact missing")
    if sha256_file(snapshot_path) != snapshot_sha:
        raise AuditLedgerError(f"{context} rollback snapshot hash mismatch")
    if sha256_file(transcript_path) != transcript_sha:
        raise AuditLedgerError(f"{context} transcript hash mismatch")
    snapshot = load_object(snapshot_path)
    if require_string(snapshot, "schema", "snapshot") != SNAPSHOT_SCHEMA:
        raise AuditLedgerError("snapshot unsupported schema")
    if require_string(snapshot, "audit_id", "snapshot") != audit_id:
        raise AuditLedgerError("snapshot audit_id mismatch")
    if require_string(snapshot, "rollback_id", "snapshot") != rollback_id:
        raise AuditLedgerError("snapshot rollback_id mismatch")
    for field in ("state_before", "state_after", "ops_before", "ops_after", "enable_seq_before", "enable_seq_after"):
        require_string(snapshot, field, "snapshot")


def validate_ledger(path: Path) -> None:
    seen: set[str] = set()
    for index, row in enumerate(load_jsonl(path)):
        validate_record(row, seen, index)


def write_good(root: Path, audit_id: str = "AUD-20990101T000000Z-deadbee-abc123", rollback_id: str = "RB-demo") -> Path:
    root.mkdir(parents=True, exist_ok=True)
    snapshot = root / f"{audit_id}.rollback-snapshot.json"
    transcript = root / f"{audit_id}.rollback-transcript.txt"
    snapshot.write_text(json.dumps({"schema": SNAPSHOT_SCHEMA, "audit_id": audit_id, "rollback_id": rollback_id, "state_before": "enabled", "state_after": "disabled", "ops_before": "zigsched", "ops_after": "none", "enable_seq_before": "1", "enable_seq_after": "1"}, sort_keys=True) + "\n")
    transcript.write_text("rollback transcript\n")
    ledger = root / "audit-ledger.jsonl"
    ledger.write_text(json.dumps({"schema": LEDGER_SCHEMA, "audit_id": audit_id, "rollback_id": rollback_id, "action": "rollback-drill", "rollback_snapshot": str(snapshot), "rollback_snapshot_sha256": sha256_file(snapshot), "transcript": str(transcript), "transcript_sha256": sha256_file(transcript), "secret_redaction": "redacted"}, sort_keys=True) + "\n")
    return ledger


def reject(path: Path, label: str) -> None:
    try:
        validate_ledger(path)
    except AuditLedgerError as exc:
        print(f"PASS reject {label}: {exc}")
        return
    raise AuditLedgerError(f"expected rejection did not occur: {label}")


def self_test() -> None:
    root = Path("evidence/lab/audit-ledger-check-self-test")
    shutil.rmtree(root, ignore_errors=True)
    good = write_good(root / "good")
    validate_ledger(good)
    duplicate = root / "duplicate.jsonl"
    duplicate.write_text(good.read_text() + good.read_text())
    reject(duplicate, "duplicate audit id")
    mismatch = write_good(root / "mismatch")
    rows = [json.loads(line) for line in mismatch.read_text().splitlines()]
    rows[0]["rollback_id"] = "RB-other"
    mismatch.write_text(json.dumps(rows[0], sort_keys=True) + "\n")
    reject(mismatch, "mismatched rollback id")
    secret = write_good(root / "secret")
    rows = [json.loads(line) for line in secret.read_text().splitlines()]
    rows[0]["audit_id"] = "AUD-20990101T000000Z-deadbee-token1"
    secret.write_text(json.dumps(rows[0], sort_keys=True) + "\n")
    reject(secret, "secret-like id")
    changed = write_good(root / "changed")
    row = json.loads(changed.read_text())
    Path(row["transcript"]).write_text("changed\n")
    reject(changed, "changed transcript hash")
    shutil.rmtree(root)
    print("PASS audit ledger self-test: duplicates, mismatch, secrets, and hash drift rejected")


def run(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.self_test:
        self_test()
        return 0
    if args.ledger is None:
        raise AuditLedgerError("internal argument parser error")
    validate_ledger(args.ledger)
    print(f"PASS audit ledger: {args.ledger}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(run(sys.argv[1:]))
    except AuditLedgerError as exc:
        print(f"FAIL audit ledger: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
