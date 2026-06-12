from __future__ import annotations

from pathlib import Path
from typing import TypeAlias
import json
import sys

_ = sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from qa.audit_ledger_check import AuditLedgerError, validate_ledger
from qa.runtime_sample_check import RuntimeSampleError, validate_file

JsonValue: TypeAlias = None | bool | int | float | str | list["JsonValue"] | dict[str, "JsonValue"]
JsonObject: TypeAlias = dict[str, JsonValue]


class ObserveSummaryError(Exception):
    """Raised when observe lifecycle evidence is malformed."""


def load_object(path: Path) -> JsonObject:
    try:
        raw: JsonValue = json.loads(path.read_text())
    except FileNotFoundError as exc:
        raise ObserveSummaryError(f"missing JSON file: {path}") from exc
    except json.JSONDecodeError as exc:
        raise ObserveSummaryError(f"invalid JSON in {path}: {exc}") from exc
    if not isinstance(raw, dict):
        raise ObserveSummaryError(f"{path} must contain a JSON object")
    return raw


def require_string(data: JsonObject, field: str, context: str) -> str:
    value = data.get(field)
    if not isinstance(value, str) or value == "":
        raise ObserveSummaryError(f"{context} missing non-empty string field: {field}")
    return value


def require_bool(data: JsonObject, field: str, context: str) -> bool:
    value = data.get(field)
    if not isinstance(value, bool):
        raise ObserveSummaryError(f"{context} missing bool field: {field}")
    return value


def safe_path(summary: JsonObject, field: str) -> Path:
    value = Path(require_string(summary, field, "observe"))
    if value.is_absolute() or ".." in value.parts or not value.exists():
        raise ObserveSummaryError(f"observe path is unsafe or missing: {field}")
    return value


def validate_links(samples: Path, ledger: Path) -> None:
    try:
        validate_file(samples)
        validate_ledger(ledger)
    except (RuntimeSampleError, AuditLedgerError) as exc:
        raise ObserveSummaryError(str(exc)) from exc


def validate_observe(path: Path) -> None:
    summary = load_object(path)
    if require_string(summary, "schema", "observe") != "zig-scheduler/observe-partial-summary/v1":
        raise ObserveSummaryError("observe summary has unsupported schema")
    mode = require_string(summary, "evidence_mode", "observe")
    if mode not in {"fixture", "vm-live", "host-refusal"}:
        raise ObserveSummaryError(f"observe evidence_mode is invalid: {mode}")
    if mode != "vm-live" and require_bool(summary, "release_eligible_live_proof", "observe"):
        raise ObserveSummaryError("fixture/refusal observe evidence cannot be release-eligible live proof")
    samples = safe_path(summary, "runtime_samples")
    ledger = safe_path(summary, "audit_ledger")
    safe_path(summary, "transcript")
    validate_links(samples, ledger)
    snapshot = summary.get("scheduler_snapshot")
    if not isinstance(snapshot, dict):
        raise ObserveSummaryError("observe missing scheduler_snapshot")
    final_state = require_string(summary, "final_state", "observe")
    final_ops = require_string(summary, "final_ops", "observe")
    if not require_bool(summary, "final_state_disabled_or_rolled_back", "observe"):
        raise ObserveSummaryError("observe final state is not disabled or rolled back")
    if snapshot.get("state") != {"status": "present", "value": final_state}:
        raise ObserveSummaryError("observe scheduler_snapshot state conflicts with final_state")
    if snapshot.get("root_ops") != {"status": "present", "value": final_ops}:
        raise ObserveSummaryError("observe scheduler_snapshot root_ops conflicts with final_ops")
