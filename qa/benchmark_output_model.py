#!/usr/bin/env python3
"""Shared model and constants for benchmark-output/v1 validation."""
from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path
from typing import Final, Literal, TypeAlias

JsonValue: TypeAlias = None | bool | int | float | str | list["JsonValue"] | dict[str, "JsonValue"]
JsonObject: TypeAlias = dict[str, JsonValue]
CommandFamily: TypeAlias = Literal["cyclictest", "fio", "perf_bench_sched_messaging", "rtla", "perf_sched"]
Status: TypeAlias = Literal["RECORDED", "UNSUPPORTED_DEFERRED"]

SCHEMA: Final = "zig-scheduler/benchmark-output/v1"
SUPPORTED: Final[frozenset[str]] = frozenset({"cyclictest", "fio", "perf_bench_sched_messaging"})
UNSUPPORTED: Final[frozenset[str]] = frozenset({"rtla", "perf_sched"})
REQUIRED: Final[tuple[str, ...]] = (
    "schema", "status", "tool", "command_family", "output_path", "output_sha256", "vm_evidence", "metrics", "units",
    "sample_count", "run_count", "host_mutation", "release_eligible", "production_capacity_claim", "hard_thresholds_enforced",
    "threshold_status", "privacy_sanitized",
)
FORBIDDEN_KEYS: Final[frozenset[str]] = frozenset({
    "access_token", "command_line", "cmdline", "argv", "args", "environment", "env", "secret", "token", "api_key",
    "password", "threshold", "thresholds", "pass", "fail", "passed", "failed", "production_claim", "production_ready",
})
FORBIDDEN_TEXT: Final[tuple[str, ...]] = (
    "--token", "api_key=", "AWS_SECRET", "BEGIN PRIVATE KEY", "password=", "Bearer ", "/proc/", "/sys/",
)
FORBIDDEN_CLAIM_TEXT_PATTERNS: Final[tuple[re.Pattern[str], ...]] = (
    re.compile(r"\bproduction[\s_-]+ready\b", re.IGNORECASE),
    re.compile(r"\bproduction[\s_-]+capacity\b", re.IGNORECASE),
    re.compile(r"\brelease[\s_-]+eligible\b", re.IGNORECASE),
    re.compile(r"\bthreshold[\s_-]+pass\b", re.IGNORECASE),
    re.compile(r"\bthreshold[\s_-]+fail\b", re.IGNORECASE),
)
SHA256_RE: Final = re.compile(r"^[0-9a-f]{64}$")
CYCLIC_LINE_RE: Final = re.compile(r"C:\s*(?P<cycles>\d+).*?Min:\s*(?P<min>\d+(?:\.\d+)?).*?Avg:\s*(?P<avg>\d+(?:\.\d+)?).*?Max:\s*(?P<max>\d+(?:\.\d+)?)")
PERF_TIME_RE: Final = re.compile(r"Total time:\s*(?P<seconds>\d+(?:\.\d+)?)\s*\[sec\]")
PERF_GROUPS_RE: Final = re.compile(r"#\s*(?P<groups>\d+)\s+groups")
PERF_PROCS_RE: Final = re.compile(r"==\s*(?P<processes>\d+)\s+processes")


@dataclass(frozen=True, slots=True)
class Args:
    mode: Literal["self-test", "fixtures", "parse"]
    fixtures: Path | None = None
    schema: Path | None = None
    tool: CommandFamily | None = None
    input_path: Path | None = None
    output_path: str | None = None
    vm_evidence: str | None = None
    out: Path | None = None


class BenchmarkOutputError(Exception):
    """Raised when benchmark output evidence is unsafe or malformed."""


def family(value: str) -> CommandFamily:
    match value:  # noqa: MATCH_OK — open CLI/schema string boundary; default raises typed rejection for unknown families.
        case "cyclictest" | "fio" | "perf_bench_sched_messaging" | "rtla" | "perf_sched":
            return value
        case _:
            raise BenchmarkOutputError(f"unsupported command family: {value}")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise BenchmarkOutputError(message)
