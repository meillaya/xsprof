from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
import json
from pathlib import Path
from typing import Final, Literal, TypeAlias, override

JsonValue: TypeAlias = None | bool | int | float | str | list["JsonValue"] | dict[str, "JsonValue"]
JsonObject: TypeAlias = dict[str, JsonValue]
JsonArtifactSuffix: TypeAlias = Literal[".json", ".jsonl"]
JSON_SUFFIXES: Final = (".json", ".jsonl")
LOAD_JSON: Callable[[str], JsonValue] = json.loads


@dataclass(frozen=True, slots=True)
class JsonBoundaryError(Exception):
    detail: str

    @override
    def __str__(self) -> str:
        return self.detail


def json_artifact_suffix(path: Path) -> JsonArtifactSuffix | None:
    if path.suffix == ".json":
        return ".json"
    if path.suffix == ".jsonl":
        return ".jsonl"
    return None


def parse_json_value_text(text: str, source: str) -> JsonValue:
    try:
        return LOAD_JSON(text)
    except json.JSONDecodeError as exc:
        raise JsonBoundaryError(f"invalid JSON: {source}: {exc}") from exc


def parse_json_object_text(text: str, source: str) -> JsonObject:
    value = parse_json_value_text(text, source)
    if not isinstance(value, dict):
        raise JsonBoundaryError(f"JSON root must be object: {source}")
    return value


def load_json_value(path: Path) -> JsonValue:
    try:
        return parse_json_value_text(path.read_text(encoding="utf-8"), path.as_posix())
    except FileNotFoundError as exc:
        raise JsonBoundaryError(f"missing JSON artifact: {path}") from exc


def load_json_object(path: Path) -> JsonObject:
    value = load_json_value(path)
    if not isinstance(value, dict):
        raise JsonBoundaryError(f"JSON artifact is not an object: {path}")
    return value


def read_jsonl_objects(path: Path) -> list[JsonObject]:
    rows: list[JsonObject] = []
    for line_no, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        if not line.strip():
            continue
        value = parse_json_value_text(line, f"{path.as_posix()}:{line_no}")
        if not isinstance(value, dict):
            raise JsonBoundaryError(f"non-object JSONL row: {path}:{line_no}")
        rows.append(value)
    if not rows:
        raise JsonBoundaryError(f"empty JSONL artifact: {path}")
    return rows


def json_text_field(data: JsonObject, field: str, fallback: str) -> str:
    value = data.get(field)
    if isinstance(value, str) and value:
        return value
    return fallback


def rewrite_json_strings(value: JsonValue, old_prefix: str, new_prefix: str) -> JsonValue:
    if isinstance(value, str):
        return value.replace(old_prefix, new_prefix)
    if isinstance(value, list):
        return [rewrite_json_strings(item, old_prefix, new_prefix) for item in value]
    if isinstance(value, dict):
        return {key: rewrite_json_strings(child, old_prefix, new_prefix) for key, child in value.items()}
    return value
