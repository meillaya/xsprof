from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
import json
from pathlib import Path
from typing import TYPE_CHECKING, Final, NoReturn, Protocol, TypeAlias

JsonValue: TypeAlias = None | bool | int | float | str | list["JsonValue"] | dict[str, "JsonValue"]
JsonObject: TypeAlias = dict[str, JsonValue]

EVENT_SCHEMA: Final = "zig-scheduler/daemon-event/v1"


@dataclass(frozen=True, slots=True)
class Args:
    fixtures: Path
    schemas: Path
    docs: Path
    self_test: bool


class ContractPackError(Exception):
    pass


class JsonLoader(Protocol):
    def loads(self, text: str, *, parse_constant: Callable[[str], NoReturn]) -> JsonValue: ...


if TYPE_CHECKING:
    json_loader: JsonLoader
else:
    json_loader = json


def parse_json_value(text: str, context: str) -> JsonValue:
    def reject_constant(value: str) -> NoReturn:
        position = text.find(value)
        raise ContractPackError(f"invalid JSON in {context} at byte {max(position, 0)}: invalid constant {value}")

    try:
        return json_loader.loads(text, parse_constant=reject_constant)
    except json.JSONDecodeError as exc:
        raise ContractPackError(f"invalid JSON in {context} at byte {exc.pos}: {exc.msg}") from exc


def parse_json_object(text: str, context: str) -> JsonObject:
    value = parse_json_value(text, context)
    if not isinstance(value, dict):
        raise ContractPackError(f"{context} is not an object")
    return value
