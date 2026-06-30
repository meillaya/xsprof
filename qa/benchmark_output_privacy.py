#!/usr/bin/env python3
"""Privacy, claim, and path safety helpers for benchmark output records."""
from __future__ import annotations

import math
import re
from pathlib import Path
from typing import Final

from qa.benchmark_output_model import (
    FORBIDDEN_CLAIM_TEXT_PATTERNS,
    FORBIDDEN_KEYS,
    FORBIDDEN_TEXT,
    BenchmarkOutputError,
    JsonValue,
    require,
)


CAMEL_BOUNDARY_RE: Final[re.Pattern[str]] = re.compile(r"(?<=[a-z0-9])(?=[A-Z])")
KEY_PART_RE: Final[re.Pattern[str]] = re.compile(r"[A-Za-z0-9]+")
FORBIDDEN_KEY_TOKENS: Final[frozenset[str]] = frozenset({
    "argv", "cmdline", "env", "environment", "password", "secret", "threshold", "thresholds", "token",
})
FORBIDDEN_KEY_SEQUENCES: Final[tuple[tuple[str, ...], ...]] = (
    ("access", "token"),
    ("api", "key"),
    ("command", "line"),
    ("raw", "debug"),
    ("production", "ready"),
    ("production", "capacity"),
    ("production", "claim"),
    ("release", "eligible"),
    ("release", "ready"),
    ("hard", "threshold"),
    ("threshold", "pass"),
    ("threshold", "fail"),
)
FORBIDDEN_COMPACT_KEY_CONCEPTS: Final[tuple[str, ...]] = (
    "accesstoken",
    "apikey",
    "commandline",
    "rawdebug",
    "productionready",
    "productioncapacity",
    "productionclaim",
    "releaseeligible",
    "releaseready",
    "hardthreshold",
    "thresholdpass",
    "thresholdfail",
)
ROOT_RECORD_CONTROL_KEYS: Final[frozenset[str]] = frozenset({
    "hard_thresholds_enforced",
    "production_capacity_claim",
    "release_eligible",
    "threshold_status",
})


def normalized_key_tokens(key: str) -> tuple[str, ...]:
    split_key = CAMEL_BOUNDARY_RE.sub("_", key)
    parts: list[str] = KEY_PART_RE.findall(split_key)
    return tuple(part.lower() for part in parts)


def compact_key(key: str) -> str:
    return "".join(part.lower() for part in KEY_PART_RE.findall(key))


def contains_sequence(tokens: tuple[str, ...], sequence: tuple[str, ...]) -> bool:
    width = len(sequence)
    return any(tokens[index : index + width] == sequence for index in range(len(tokens) - width + 1))


def forbidden_key(key: str, context: str) -> bool:
    if context == "record" and key in ROOT_RECORD_CONTROL_KEYS:
        return False
    lowered = key.lower().replace("-", "_")
    if lowered in FORBIDDEN_KEYS:
        return True
    tokens = normalized_key_tokens(key)
    compact = compact_key(key)
    if any(token in FORBIDDEN_KEY_TOKENS for token in tokens):
        return True
    if any(concept in compact for concept in FORBIDDEN_COMPACT_KEY_CONCEPTS):
        return True
    return any(contains_sequence(tokens, sequence) for sequence in FORBIDDEN_KEY_SEQUENCES)


def reject_private_leaks(value: JsonValue, context: str) -> None:
    if isinstance(value, bool) or value is None:
        return
    if isinstance(value, int | float):
        if not math.isfinite(value):
            raise BenchmarkOutputError(f"non-finite numeric value at {context}")
        return
    if isinstance(value, dict):
        for key, child in value.items():
            if forbidden_key(key, context):
                raise BenchmarkOutputError(f"forbidden private/claim key at {context}.{key}")
            reject_private_leaks(child, f"{context}.{key}")
        return
    if isinstance(value, list):
        for index, child in enumerate(value):
            reject_private_leaks(child, f"{context}[{index}]")
        return
    lowered = value.lower()
    for needle in FORBIDDEN_TEXT:
        if needle.lower() in lowered:
            raise BenchmarkOutputError(f"forbidden private/claim text at {context}")
    for pattern in FORBIDDEN_CLAIM_TEXT_PATTERNS:
        if pattern.search(value) is not None:
            raise BenchmarkOutputError(f"forbidden private/claim text at {context}")


def safe_relative(value: JsonValue, field: str) -> str:
    if not isinstance(value, str) or value == "":
        raise BenchmarkOutputError(f"{field} must be non-empty relative path")
    path = Path(value)
    require(not path.is_absolute(), f"{field} must be relative")
    require(".." not in path.parts, f"{field} must not traverse")
    reject_private_leaks(value, field)
    return value
