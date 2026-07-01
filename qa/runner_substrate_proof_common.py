#!/usr/bin/env python3
# pyright: reportAny=false
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
# ─── How to run ───
# python3 -m py_compile qa/runner_substrate_proof_common.py
"""Shared types for runner substrate proof validation."""
from __future__ import annotations

from pathlib import Path
import json
from typing import TypeAlias

JsonValue: TypeAlias = None | bool | int | float | str | list["JsonValue"] | dict[str, "JsonValue"]
JsonObject: TypeAlias = dict[str, JsonValue]


class RunnerProofError(Exception):
    """Raised when runner substrate proof is malformed or unsafe."""


def load_json_object(path: Path) -> JsonObject:
    """Load a JSON file and require a top-level object."""
    try:
        raw: JsonValue = json.loads(path.read_text())
    except FileNotFoundError as exc:
        raise RunnerProofError(f"missing JSON file: {path}") from exc
    except json.JSONDecodeError as exc:
        raise RunnerProofError(f"invalid JSON in {path}: {exc}") from exc
    if not isinstance(raw, dict):
        raise RunnerProofError(f"{path} must contain a JSON object")
    return raw
