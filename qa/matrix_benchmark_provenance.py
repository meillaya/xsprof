#!/usr/bin/env python3
"""Matrix workload benchmark provenance reference validation."""
from __future__ import annotations

import hashlib
import json
from collections.abc import Callable
from pathlib import Path
from typing import TYPE_CHECKING, Final, NoReturn, Protocol, TypeAlias

from qa.benchmark_output_model import BenchmarkOutputError
from qa.benchmark_output_validate import validate_record as validate_benchmark_output_record

JsonValue: TypeAlias = None | bool | int | float | str | list["JsonValue"] | dict[str, "JsonValue"]
JsonObject: TypeAlias = dict[str, JsonValue]
BENCHMARK_PROVENANCE_FIELDS: Final = frozenset(("record_path", "record_sha256", "record_only"))
SHA256_HEX: Final = frozenset("0123456789abcdef")


class MatrixBenchmarkProvenanceError(Exception):
    """Raised when matrix benchmark provenance is malformed or unsafe."""


class JsonLoader(Protocol):
    def loads(self, text: str, *, parse_constant: Callable[[str], NoReturn]) -> JsonValue: ...


if TYPE_CHECKING:
    json_loader: JsonLoader
else:
    json_loader = json


def reject_constant(value: str) -> NoReturn:
    raise MatrixBenchmarkProvenanceError(f"invalid JSON constant: {value}")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise MatrixBenchmarkProvenanceError(message)


def load_json(path: Path) -> JsonObject:
    try:
        raw = json_loader.loads(path.read_text(), parse_constant=reject_constant)
    except FileNotFoundError as exc:
        raise MatrixBenchmarkProvenanceError(f"missing JSON file: {path}") from exc
    except json.JSONDecodeError as exc:
        raise MatrixBenchmarkProvenanceError(f"invalid JSON in {path} at byte {exc.pos}: {exc.msg}") from exc
    return obj(raw, str(path))


def obj(value: JsonValue | None, context: str) -> JsonObject:
    if not isinstance(value, dict):
        raise MatrixBenchmarkProvenanceError(f"{context} must be an object")
    return value


def text(value: JsonValue | None, context: str) -> str:
    if not isinstance(value, str) or value == "":
        raise MatrixBenchmarkProvenanceError(f"{context} must be non-empty text")
    return value


def require_only_fields(data: JsonObject, allowed: frozenset[str], context: str) -> None:
    extra = sorted(set(data) - allowed)
    require(not extra, f"{context} has unexpected fields: {', '.join(extra)}")


def require_safe_path(value: JsonValue | None, context: str) -> str:
    raw = text(value, context)
    path = Path(raw)
    require(not path.is_absolute(), f"{context} must be relative")
    require(".." not in path.parts, f"{context} must not traverse")
    return raw


def require_descendant(path: Path, root: Path, context: str) -> None:
    try:
        _ = path.resolve().relative_to(root.resolve())
    except ValueError as exc:
        raise MatrixBenchmarkProvenanceError(f"{context} must stay under matrix run root: {root}") from exc


def file_sha256(path: Path) -> str:
    try:
        return hashlib.sha256(path.read_bytes()).hexdigest()
    except FileNotFoundError as exc:
        raise MatrixBenchmarkProvenanceError(f"missing referenced artifact: {path}") from exc


def require_sha256(value: str, context: str) -> None:
    require(len(value) == 64 and all(char in SHA256_HEX for char in value), f"{context} must be sha256 hex")


def validate_entries(value: JsonValue | None, manifest_root: Path | None, context: str) -> None:
    if value is None:
        return
    if not isinstance(value, list):
        raise MatrixBenchmarkProvenanceError(f"{context} must be a list")
    require(bool(value), f"{context} must not be empty when present")
    seen: set[str] = set()
    for index, item in enumerate(value):
        entry = obj(item, f"{context}[{index}]")
        require_only_fields(entry, BENCHMARK_PROVENANCE_FIELDS, f"{context}[{index}]")
        require(entry.get("record_only") is True, f"{context}[{index}].record_only must be true")
        record_path = Path(require_safe_path(entry.get("record_path"), f"{context}[{index}].record_path"))
        record_key = record_path.as_posix()
        require(record_key not in seen, f"{context}[{index}].record_path duplicates an earlier benchmark record")
        seen.add(record_key)
        if manifest_root is not None:
            require_descendant(record_path, manifest_root, f"{context}[{index}].record_path")
        record_sha = text(entry.get("record_sha256"), f"{context}[{index}].record_sha256")
        require_sha256(record_sha, f"{context}[{index}].record_sha256")
        require(file_sha256(record_path) == record_sha, f"{context}[{index}].record_sha256 does not match referenced benchmark record")
        record = load_json(record_path)
        try:
            validate_benchmark_output_record(record)
        except BenchmarkOutputError as exc:
            raise MatrixBenchmarkProvenanceError(f"{context}[{index}].record_path invalid benchmark provenance: {exc}") from exc
        if manifest_root is not None:
            validate_record_references(record, manifest_root, f"{context}[{index}].record")


def validate_record_references(record: JsonObject, manifest_root: Path, context: str) -> None:
    raw_output_path = Path(require_safe_path(record.get("output_path"), f"{context}.output_path"))
    require_descendant(raw_output_path, manifest_root, f"{context}.output_path")
    require(file_sha256(raw_output_path) == text(record.get("output_sha256"), f"{context}.output_sha256"), f"{context}.output_sha256 does not match referenced raw benchmark output")
    vm_evidence_path = Path(require_safe_path(record.get("vm_evidence"), f"{context}.vm_evidence"))
    require_descendant(vm_evidence_path, manifest_root, f"{context}.vm_evidence")
