"""Shared BPF ABI freeze constants and JSON helpers."""

from __future__ import annotations

from dataclasses import dataclass
from hashlib import sha256
from pathlib import Path
from typing import Final, TypeAlias

from qa.bpf_abi_cgroup_model import (
    ABI_V3_ACCEPTED_CALLBACKS as ABI_V3_ACCEPTED_CALLBACKS,
    ABI_V3_PROGRAM_SECTIONS as ABI_V3_PROGRAM_SECTIONS,
    ABI_V3_STRUCT_OPS_USED_FIELDS as ABI_V3_STRUCT_OPS_USED_FIELDS,
    CGROUP_KNOB_SEMANTICS as CGROUP_KNOB_SEMANTICS,
    EXPECTED_CGROUP_EVIDENCE as EXPECTED_CGROUP_EVIDENCE,
    EXPECTED_CGROUP_POLICY_FIELDS as EXPECTED_CGROUP_POLICY_FIELDS,
)

JsonValue: TypeAlias = None | bool | int | float | str | list["JsonValue"] | dict[str, "JsonValue"]
JsonObject: TypeAlias = dict[str, JsonValue]

VM_MARKER: Final = "/run/zig-scheduler-vm-lab.marker"
VM_CONTRACT: Final = "qa/vm/execution_contract.json"
POLICY_NAME: Final = "zigsched_minimal"
POLICY_SYMBOL: Final = "zigsched_minimal_ops"
PARTIAL_SWITCH: Final = "SCX_OPS_SWITCH_PARTIAL"
ABI_VERSION: Final = 3
STATS_COUNT: Final = 13
EVENTS_COUNT: Final = 6
EXPECTED_DEFINES: Final[dict[str, str]] = {
    "ZIGSCHED_ABI_VERSION": "3u",
    "ZIGSCHED_MINIMAL_NR_STATS": "13u",
    "ZIGSCHED_MINIMAL_NR_EVENTS": "6u",
    "ZIGSCHED_DSQ_FIFO": "0x5a195f1f0ULL",
    "ZIGSCHED_DSQ_VTIME": "0x5a195f1f1ULL",
    "ZIGSCHED_STARVATION_NS_MAX": "50000000ULL",
    "ZIGSCHED_POLICY_MODE_FIFO": "1ULL",
    "ZIGSCHED_POLICY_MODE_VTIME": "2ULL",
    "ZIGSCHED_CGROUP_KNOB_WEIGHT_OBSERVED": "1ULL",
    "ZIGSCHED_CGROUP_KNOB_CPU_MAX_DEFERRED": "2ULL",
    "ZIGSCHED_CGROUP_KNOB_CPUSET_OBSERVED": "4ULL",
    "ZIGSCHED_CGROUP_KNOB_PRESSURE_OBSERVED": "8ULL",
    "ZIGSCHED_CGROUP_KNOB_UCLAMP_DEFERRED": "16ULL",
    "SCX_OPS_SWITCH_PARTIAL": "8ULL",
}
EXPECTED_STATS: Final = (
    "ZIGSCHED_STAT_SELECT_CPU_CALLS",
    "ZIGSCHED_STAT_ENQUEUE_CALLS",
    "ZIGSCHED_STAT_DISPATCH_CALLS",
    "ZIGSCHED_STAT_LOCAL_DIRECT_INSERTS",
    "ZIGSCHED_STAT_FIFO_INSERTS",
    "ZIGSCHED_STAT_VTIME_INSERTS",
    "ZIGSCHED_STAT_FIFO_DISPATCHES",
    "ZIGSCHED_STAT_VTIME_DISPATCHES",
    "ZIGSCHED_STAT_CGROUP_INIT_CALLS",
    "ZIGSCHED_STAT_CGROUP_EXIT_CALLS",
    "ZIGSCHED_STAT_CGROUP_MOVE_CALLS",
    "ZIGSCHED_STAT_CGROUP_SET_WEIGHT_CALLS",
    "ZIGSCHED_STAT_CGROUP_WEIGHT_OBSERVED",
)
EXPECTED_STATS_FIELDS: Final = (
    "zigsched_u64 select_cpu_calls",
    "zigsched_u64 enqueue_calls",
    "zigsched_u64 dispatch_calls",
    "zigsched_u64 local_direct_inserts",
    "zigsched_u64 fifo_inserts",
    "zigsched_u64 vtime_inserts",
    "zigsched_u64 fifo_dispatches",
    "zigsched_u64 vtime_dispatches",
    "zigsched_u64 cgroup_init_calls",
    "zigsched_u64 cgroup_exit_calls",
    "zigsched_u64 cgroup_move_calls",
    "zigsched_u64 cgroup_set_weight_calls",
    "zigsched_u64 cgroup_weight_observed",
)
EXPECTED_EVENTS: Final = (
    "ZIGSCHED_EVENT_SELECT_CPU_FALLBACK",
    "ZIGSCHED_EVENT_DISPATCH_EMPTY",
    "ZIGSCHED_EVENT_INIT_FIFO_DSQ_FAILED",
    "ZIGSCHED_EVENT_INIT_VTIME_DSQ_FAILED",
    "ZIGSCHED_EVENT_CGROUP_MOVE_OBSERVED",
    "ZIGSCHED_EVENT_CGROUP_WEIGHT_OBSERVED",
)
EXPECTED_POLICY_CONFIG_FIELDS: Final = (
    "zigsched_u64 fifo_dsq",
    "zigsched_u64 vtime_dsq",
    "zigsched_u64 starvation_ns_max",
    "zigsched_u64 mode",
    "zigsched_u64 cgroup_knob_support",
)
REQUIRED_HEADER_TEXT: Final = (
    "#define ZIGSCHED_ABI_VERSION 3u",
    "ZIGSCHED_DSQ_FIFO",
    "ZIGSCHED_DSQ_VTIME",
    "ZIGSCHED_STARVATION_NS_MAX",
    "ZIGSCHED_CGROUP_KNOB_WEIGHT_OBSERVED",
    "enum zigsched_stat_index",
    "enum zigsched_event_index",
    "struct zigsched_policy_config",
    "struct zigsched_cgroup_policy",
    "struct sched_ext_ops",
    "SCX_OPS_SWITCH_PARTIAL",
)
REQUIRED_ADR_TEXT: Final = (
    "Policy expansion is blocked",
    "v1 compatibility contract",
    "v2 compatibility contract",
    "v3 compatibility contract",
    "cpu.weight",
    "docs/releases/supported-kernel-tuples.md",
    "zigsched_minimal_ops",
    "SCX_OPS_SWITCH_PARTIAL",
    "SCX_OPS_SWITCH_ALL",
    "host_attach_allowed=false",
    "SKIP mode",
    "not a production-readiness claim",
)
PROGRAM_SECTIONS: Final = (
    "struct_ops.s/zigsched_minimal_init",
    "struct_ops/zigsched_minimal_enqueue",
    "struct_ops/zigsched_minimal_dispatch",
)
ABI_V2_PROGRAM_SECTIONS: Final = (
    "struct_ops/zigsched_minimal_select_cpu",
    "struct_ops.s/zigsched_minimal_init",
    "struct_ops/zigsched_minimal_enqueue",
    "struct_ops/zigsched_minimal_dispatch",
)
ABI_V2_STRUCT_OPS_USED_FIELDS: Final = ("name", "flags", "select_cpu", "init", "enqueue", "dispatch")
EXPECTED_MAP_LAYOUTS: Final[dict[str, dict[str, str]]] = {
    "zigsched_stats": {"type": "BPF_MAP_TYPE_ARRAY", "max_entries": "ZIGSCHED_MINIMAL_NR_STATS", "key": "u32", "value": "u64"},
    "zigsched_events": {"type": "BPF_MAP_TYPE_ARRAY", "max_entries": "ZIGSCHED_MINIMAL_NR_EVENTS", "key": "u32", "value": "u64"},
    "zigsched_policy_config": {"type": "BPF_MAP_TYPE_ARRAY", "max_entries": "1", "key": "u32", "value": "struct zigsched_policy_config"},
    "zigsched_cgroup_policy": {"type": "BPF_MAP_TYPE_ARRAY", "max_entries": "1", "key": "u32", "value": "struct zigsched_cgroup_policy"},
}


@dataclass(frozen=True, slots=True)
class Args:
    header: Path
    strategy: Path
    metadata: Path
    skip_json: Path | None
    self_test: bool


@dataclass(frozen=True, slots=True)
class AbiSnapshot:
    header_sha256: str
    defines: dict[str, str]
    stats: tuple[str, ...]
    events: tuple[str, ...]
    stats_fields: tuple[str, ...]
    policy_config_fields: tuple[str, ...]
    cgroup_policy_fields: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class SourceMapLayout:
    name: str
    map_type: str
    max_entries: str
    key_type: str
    value_type: str


@dataclass(frozen=True, slots=True)
class SourceAbi:
    source_sha256: str
    map_layouts: tuple[SourceMapLayout, ...]
    program_sections: tuple[str, ...]
    struct_ops_used_fields: tuple[str, ...]
    struct_ops_callbacks: tuple[str, ...]


class BpfAbiError(Exception):
    """Raised when BPF ABI freeze evidence is missing or unsafe."""


def obj(value: JsonValue | None, context: str) -> JsonObject:
    if not isinstance(value, dict):
        raise BpfAbiError(f"{context} must be an object")
    return value


def str_list(value: JsonValue | None, context: str) -> list[str]:
    if not isinstance(value, list):
        raise BpfAbiError(f"{context} must be a list")
    out: list[str] = []
    for item in value:
        if not isinstance(item, str):
            raise BpfAbiError(f"{context} contains a non-string")
        out.append(item)
    return out


def require(condition: bool, message: str) -> None:
    if not condition:
        raise BpfAbiError(message)


def sha256_file(path: Path) -> str:
    digest = sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_string(value: JsonValue | None, context: str) -> str:
    if not isinstance(value, str) or value == "":
        raise BpfAbiError(f"{context} must be a non-empty string")
    return value


def require_int(value: JsonValue | None, expected: int, context: str) -> None:
    require(value == expected, f"{context} changed without ABI acceptance: expected {expected}, got {value}")


def require_string_list(value: JsonValue | None, expected: tuple[str, ...], context: str) -> None:
    got = tuple(str_list(value, context))
    require(got == expected, f"{context} changed without ABI acceptance: expected {expected}, got {got}")
