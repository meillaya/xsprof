from __future__ import annotations

from dataclasses import dataclass
from typing import TypeAlias

JsonValue: TypeAlias = None | bool | int | float | str | list["JsonValue"] | dict[str, "JsonValue"]
JsonObject: TypeAlias = dict[str, JsonValue]


@dataclass(frozen=True, slots=True)
class EvidenceSafetyError(Exception):
    context: str
    reason: str

    def __str__(self) -> str:
        return f"{self.context}: {self.reason}"


def reject_contradictions(data: JsonObject, context: str) -> None:
    for field in ("dirty_worktree", "stale_state", "misleading_success_output"):
        if data.get(field) is True:
            raise EvidenceSafetyError(context=context, reason=f"{field} is true")
    cleanup = data.get("cleanup")
    if isinstance(cleanup, dict):
        for field in ("qemu_leftovers", "tmux_leftovers"):
            if cleanup.get(field) is True:
                raise EvidenceSafetyError(context=context, reason=f"cleanup.{field} is true")
