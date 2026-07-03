#!/usr/bin/env python3
"""JSON, privacy, path, and scheduler-state primitives for matrix-run checks."""
from __future__ import annotations

import hashlib
import json
import re
from collections.abc import Callable
from pathlib import Path
from typing import TYPE_CHECKING, NoReturn, Protocol

from qa.matrix_run_model import (
    CLAIM_TEXT_RE,
    MANIFEST_FILE,
    MATRIX_BASE,
    PRIVATE_NEEDLES,
    PRIVATE_PATH_RE,
    RUN_ID_MAX,
    RUN_ID_RE,
    SCHED_DISABLE_REASONS,
    SCHED_STATE_FIELDS,
    SCHED_STATES,
    SHA256_RE,
    WORKLOAD_PRIVATE_NEEDLES,
    JsonObject,
    JsonValue,
    MatrixRunContractError,
)


class JsonLoader(Protocol):
    def loads(self, text: str, *, parse_constant: Callable[[str], NoReturn]) -> JsonValue: ...


if TYPE_CHECKING:
    json_loader: JsonLoader
else:
    json_loader = json

def reject_constant(value: str) -> NoReturn:
    raise MatrixRunContractError(f"invalid JSON constant: {value}")

def load_json(path: Path) -> JsonObject:
    try:
        raw = json_loader.loads(path.read_text(), parse_constant=reject_constant)
    except FileNotFoundError as exc:
        raise MatrixRunContractError(f"missing JSON file: {path}") from exc
    except json.JSONDecodeError as exc:
        raise MatrixRunContractError(f"invalid JSON in {path} at byte {exc.pos}: {exc.msg}") from exc
    return obj(raw, str(path))

def obj(value: JsonValue | None, context: str) -> JsonObject:
    if not isinstance(value, dict):
        raise MatrixRunContractError(f"{context} must be an object")
    return value

def text(value: JsonValue | None, context: str) -> str:
    if not isinstance(value, str) or value == "":
        raise MatrixRunContractError(f"{context} must be non-empty text")
    return value

def bool_field(value: JsonValue | None, context: str) -> bool:
    if not isinstance(value, bool):
        raise MatrixRunContractError(f"{context} must be a boolean")
    return value

def require(condition: bool, message: str) -> None:
    if not condition:
        raise MatrixRunContractError(message)

def require_only_fields(row: JsonObject, allowed: frozenset[str], context: str) -> None:
    extra = sorted(set(row) - allowed)
    require(not extra, f"{context} has unexpected field(s): {', '.join(extra)}")

def reject_private(value: JsonValue, context: str) -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            lowered = key.lower()
            require(not any(needle in lowered for needle in PRIVATE_NEEDLES), f"privacy-unsafe key in {context}.{key}")
            reject_private(child, f"{context}.{key}")
        return
    if isinstance(value, list):
        for index, child in enumerate(value):
            reject_private(child, f"{context}[{index}]")
        return
    if isinstance(value, str):
        lowered = value.lower()
        require(not any(needle in lowered for needle in PRIVATE_NEEDLES), f"privacy-unsafe text in {context}")
        require(PRIVATE_PATH_RE.search(value) is None, f"privacy-unsafe path in {context}")
        require(CLAIM_TEXT_RE.search(value) is None, f"claim-unsafe text in {context}")
        return
    return

def reject_workload_artifact_private(value: JsonValue, context: str) -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            lowered = key.lower()
            require(not any(needle in lowered for needle in WORKLOAD_PRIVATE_NEEDLES), f"privacy-unsafe workload key in {context}.{key}")
            reject_workload_artifact_private(child, f"{context}.{key}")
        return
    if isinstance(value, list):
        for index, child in enumerate(value):
            reject_workload_artifact_private(child, f"{context}[{index}]")
        return
    if isinstance(value, str):
        lowered = value.lower()
        require(not any(needle in lowered for needle in WORKLOAD_PRIVATE_NEEDLES), f"privacy-unsafe workload text in {context}")
        require(CLAIM_TEXT_RE.search(value) is None, f"claim-unsafe workload text in {context}")
        require(PRIVATE_PATH_RE.search(value) is None, f"privacy-unsafe workload path in {context}")
        return
    return

def require_sched_enable_seq(value: JsonValue | None, context: str) -> int | None:
    raw = text(value, context)
    if raw == "unavailable":
        return None
    require(raw.isdecimal(), f"{context} must be a nonnegative integer string or unavailable")
    return int(raw)

def validate_scheduler_state(state: JsonObject, context: str) -> int | None:
    require_only_fields(state, SCHED_STATE_FIELDS, context)
    require({"sched_ext", "ops"}.issubset(state), f"{context} missing sched_ext/ops state")
    sched_ext = text(state.get("sched_ext"), f"{context}.sched_ext")
    require(sched_ext in SCHED_STATES, f"{context}.sched_ext invalid")
    ops = text(state.get("ops"), f"{context}.ops")
    reject_private(ops, f"{context}.ops")
    enable_seq = require_sched_enable_seq(state.get("enable_seq", "unavailable"), f"{context}.enable_seq")
    if "task_ext_enabled" in state:
        task_ext = text(state.get("task_ext_enabled"), f"{context}.task_ext_enabled")
        require(task_ext in {"true", "false", "unknown", "unavailable"}, f"{context}.task_ext_enabled invalid")
    if "disable_reason" in state:
        reason = text(state.get("disable_reason"), f"{context}.disable_reason")
        require(reason in SCHED_DISABLE_REASONS, f"{context}.disable_reason invalid")
    reject_private(state, context)
    return enable_seq

def require_safe_path(value: JsonValue | None, context: str) -> str:
    raw = text(value, context)
    path = Path(raw)
    require(not path.is_absolute() and ".." not in path.parts, f"{context} must be relative and non-traversing: {raw}")
    return raw

def require_manifest_root(manifest_path: Path) -> Path:
    require(not manifest_path.is_absolute() and ".." not in manifest_path.parts, "--manifest must be relative and non-traversing")
    parts = manifest_path.parts
    require(len(parts) == 5 and parts[:3] == MATRIX_BASE.parts and parts[4] == MANIFEST_FILE, f"--manifest must be {MATRIX_BASE}/<run-id>/{MANIFEST_FILE}: {manifest_path}")
    require(RUN_ID_RE.fullmatch(parts[3]) is not None, f"--manifest run id must be 1-{RUN_ID_MAX} safe characters: {parts[3]}")
    return Path(*parts[:4])

def require_descendant(path: Path, root: Path, context: str) -> None:
    require(path == root or path.parts[: len(root.parts)] == root.parts, f"{context} must stay under {root}: {path}")

def require_identifier(row: JsonObject, field: str, pattern: re.Pattern[str], context: str) -> None:
    raw = text(row.get(field), f"{context}.{field}")
    require(pattern.fullmatch(raw) is not None, f"{context}.{field} is not a stable identifier")

def require_sha(row: JsonObject, field: str, context: str) -> None:
    raw = text(row.get(field), f"{context}.{field}")
    require(SHA256_RE.fullmatch(raw) is not None, f"{context}.{field} must be sha256 hex")

def file_sha256(path: Path) -> str:
    try:
        return hashlib.sha256(path.read_bytes()).hexdigest()
    except FileNotFoundError as exc:
        raise MatrixRunContractError(f"missing referenced artifact: {path}") from exc

def text_list(value: JsonValue | None, context: str) -> list[str]:
    if not isinstance(value, list):
        raise MatrixRunContractError(f"{context} must be a list")
    items: list[str] = []
    for index, item in enumerate(value):
        items.append(text(item, f"{context}[{index}]"))
    return items
