from __future__ import annotations

import json
from pathlib import Path
from typing import TYPE_CHECKING, Final, Protocol, TypeAlias

JsonValue: TypeAlias = None | bool | int | float | str | list["JsonValue"] | dict[str, "JsonValue"]
JsonObject: TypeAlias = dict[str, JsonValue]


class JsonLoader(Protocol):
    def loads(self, text: str) -> JsonValue: ...


if TYPE_CHECKING:
    json_loader: JsonLoader
else:
    json_loader = json

FORBIDDEN_KEYS: Final[frozenset[str]] = frozenset({"command_line", "cmdline", "argv", "args", "environment", "env", "secret", "token", "api_key"})
CLAIM_KEYS: Final[frozenset[str]] = frozenset({"production_claim", "production_capacity_claim", "release_eligible", "release_eligible_live_proof"})
FORBIDDEN_TEXT: Final[tuple[str, ...]] = ("--token", "api_key=", "AWS_SECRET", "BEGIN PRIVATE KEY", "password=", "/proc/", "/sys/")
FACT_STATUSES: Final[frozenset[str]] = frozenset({"present", "missing", "unreadable", "unknown"})


class RuntimeSampleError(Exception):
    pass


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
            raw = json_loader.loads(line)
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
    if isinstance(value, str) and value != "":
        return value
    raise RuntimeSampleError(f"{context} missing non-empty string field: {field}")


def require_bool(data: JsonObject, field: str, context: str) -> bool:
    value = data.get(field)
    if isinstance(value, bool):
        return value
    raise RuntimeSampleError(f"{context} missing bool field: {field}")


def require_int(data: JsonObject, field: str, context: str) -> int:
    value = data.get(field)
    if isinstance(value, int):
        return value
    raise RuntimeSampleError(f"{context} missing int field: {field}")


def require_object(data: JsonObject, field: str, context: str) -> JsonObject:
    value = data.get(field)
    if isinstance(value, dict):
        return value
    raise RuntimeSampleError(f"{context} missing object field: {field}")


def optional_object(data: JsonObject, field: str, context: str) -> JsonObject | None:
    value = data.get(field)
    if value is None:
        return None
    if isinstance(value, dict):
        return value
    raise RuntimeSampleError(f"{context} field must be an object when present: {field}")


def validate_fact(data: JsonObject, field: str, context: str) -> JsonObject:
    fact = require_object(data, field, context)
    status = require_string(fact, "status", f"{context}.{field}")
    if status not in FACT_STATUSES:
        raise RuntimeSampleError(f"{context}.{field} has unsupported status: {status}")
    value = fact.get("value")
    if not isinstance(value, str) or (status == "present" and value == ""):
        raise RuntimeSampleError(f"{context}.{field} has invalid value")
    reject_private_leaks(value, f"{context}.{field}.value")
    return fact


def reject_private_leaks(value: JsonValue, context: str) -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            lowered = key.lower()
            if lowered in FORBIDDEN_KEYS:
                raise RuntimeSampleError(f"privacy-unsafe key in runtime sample: {context}.{key}")
            if lowered in CLAIM_KEYS and child is True:
                raise RuntimeSampleError(f"claim-unsafe flag in runtime sample: {context}.{key}")
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
