#!/usr/bin/env python3
"""File and JSON I/O helpers for benchmark-output/v1 validators."""
from __future__ import annotations

import hashlib
import json
from collections.abc import Callable
from pathlib import Path
from typing import TYPE_CHECKING, NoReturn, Protocol

from qa.benchmark_output_model import SCHEMA, BenchmarkOutputError, JsonObject, JsonValue
from qa.benchmark_output_privacy import reject_private_leaks


class JsonLoader(Protocol):
    def loads(self, text: str, *, parse_constant: Callable[[str], NoReturn]) -> JsonValue: ...


if TYPE_CHECKING:
    json_loader: JsonLoader
else:
    json_loader = json


def reject_constant(value: str) -> NoReturn:
    raise BenchmarkOutputError(f"invalid JSON constant: {value}")


def read_text(path: Path) -> str:
    try:
        data = path.read_text()
    except FileNotFoundError as exc:
        raise BenchmarkOutputError(f"missing benchmark output: {path}") from exc
    reject_private_leaks(data, path.as_posix())
    return data


def load_json(path: Path) -> JsonObject:
    try:
        raw = json_loader.loads(path.read_text(), parse_constant=reject_constant)
    except FileNotFoundError as exc:
        raise BenchmarkOutputError(f"missing benchmark output: {path}") from exc
    except json.JSONDecodeError as exc:
        raise BenchmarkOutputError(f"invalid JSON: {path}: {exc}") from exc
    if not isinstance(raw, dict):
        raise BenchmarkOutputError(f"JSON root must be object: {path}")
    context = "record" if raw.get("schema") == SCHEMA else path.as_posix()
    reject_private_leaks(raw, context)
    return raw


def load_schema(path: Path) -> JsonObject:
    try:
        raw = json_loader.loads(path.read_text(), parse_constant=reject_constant)
    except FileNotFoundError as exc:
        raise BenchmarkOutputError(f"missing schema: {path}") from exc
    except json.JSONDecodeError as exc:
        raise BenchmarkOutputError(f"invalid schema JSON: {path}: {exc}") from exc
    if not isinstance(raw, dict):
        raise BenchmarkOutputError(f"schema root must be object: {path}")
    return raw


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path: Path, data: JsonObject) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    _ = path.write_text(json.dumps(data, allow_nan=False, indent=2, sort_keys=True) + "\n")
