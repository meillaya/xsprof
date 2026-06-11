#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
# ─── How to run ───
# 1. Install uv (if not installed):
#      curl -LsSf https://astral.sh/uv/install.sh | sh
# 2. Pipe JSON and require fields:
#      zig build run -- sched-ext preflight --json | uv run qa/json_field_check.py --require sched_ext.state
# 3. Or with system Python (no dependencies):
#      python3 qa/json_field_check.py --require sched_ext.state < report.json
# ──────────────────
from __future__ import annotations

import json
import sys
from dataclasses import dataclass
from typing import TypeAlias

JsonValue: TypeAlias = None | bool | int | float | str | list["JsonValue"] | dict[str, "JsonValue"]
JsonObject: TypeAlias = dict[str, JsonValue]


@dataclass(frozen=True, slots=True)
class Args:
    required: tuple[str, ...]


class JsonFieldError(Exception):
    """Raised when required JSON fields are missing."""


def parse_args(argv: list[str]) -> Args:
    required: list[str] = []
    index = 0
    while index < len(argv):
        if argv[index] != "--require" or index + 1 >= len(argv):
            raise JsonFieldError("usage: json_field_check.py --require dotted.path [--require dotted.path ...]")
        required.append(argv[index + 1])
        index += 2
    if not required:
        raise JsonFieldError("at least one --require is needed")
    return Args(required=tuple(required))


def parse_stdin() -> JsonObject:
    try:
        raw: JsonValue = json.loads(sys.stdin.read())
    except json.JSONDecodeError as exc:
        raise JsonFieldError(f"invalid JSON: {exc}") from exc
    if not isinstance(raw, dict):
        raise JsonFieldError("input JSON must be an object")
    return raw


def has_path(root: JsonObject, dotted: str) -> bool:
    current: JsonValue = root
    for segment in dotted.split("."):
        if not isinstance(current, dict) or segment not in current:
            return False
        current = current[segment]
    return True


def run(argv: list[str]) -> int:
    args = parse_args(argv)
    root = parse_stdin()
    missing = [path for path in args.required if not has_path(root, path)]
    if missing:
        raise JsonFieldError("missing required fields: " + ",".join(missing))
    print("PASS json fields: " + ",".join(args.required))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(run(sys.argv[1:]))
    except JsonFieldError as exc:
        print(f"FAIL json fields: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
