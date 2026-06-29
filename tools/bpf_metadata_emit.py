#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
# ─── How to run ───
# python3 tools/bpf_metadata_emit.py --mode object --output zig-out/bpf/zigsched_minimal.bpf.meta.json
"""Emit canonical BPF object or SKIP metadata from sanitized environment facts."""

from __future__ import annotations

import argparse
import json
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Final, TypeAlias

JsonValue: TypeAlias = None | bool | int | float | str | list["JsonValue"] | dict[str, "JsonValue"]
JsonObject: TypeAlias = dict[str, JsonValue]

DEFINES: Final[JsonObject] = {
    "ZIGSCHED_ABI_VERSION": "1u",
    "ZIGSCHED_MINIMAL_NR_STATS": "8u",
    "ZIGSCHED_MINIMAL_NR_EVENTS": "4u",
    "ZIGSCHED_DSQ_FIFO": "0x5a195f1f0ULL",
    "ZIGSCHED_DSQ_VTIME": "0x5a195f1f1ULL",
    "ZIGSCHED_STARVATION_NS_MAX": "50000000ULL",
    "ZIGSCHED_POLICY_MODE_FIFO": "1ULL",
    "ZIGSCHED_POLICY_MODE_VTIME": "2ULL",
    "SCX_OPS_SWITCH_PARTIAL": "8ULL",
}
STATS: Final[list[JsonValue]] = [
    "ZIGSCHED_STAT_SELECT_CPU_CALLS",
    "ZIGSCHED_STAT_ENQUEUE_CALLS",
    "ZIGSCHED_STAT_DISPATCH_CALLS",
    "ZIGSCHED_STAT_LOCAL_DIRECT_INSERTS",
    "ZIGSCHED_STAT_FIFO_INSERTS",
    "ZIGSCHED_STAT_VTIME_INSERTS",
    "ZIGSCHED_STAT_FIFO_DISPATCHES",
    "ZIGSCHED_STAT_VTIME_DISPATCHES",
]
EVENTS: Final[list[JsonValue]] = [
    "ZIGSCHED_EVENT_SELECT_CPU_FALLBACK",
    "ZIGSCHED_EVENT_DISPATCH_EMPTY",
    "ZIGSCHED_EVENT_INIT_FIFO_DSQ_FAILED",
    "ZIGSCHED_EVENT_INIT_VTIME_DSQ_FAILED",
]
POLICY_FIELDS: Final[list[JsonValue]] = ["zigsched_u64 fifo_dsq", "zigsched_u64 vtime_dsq", "zigsched_u64 starvation_ns_max", "zigsched_u64 mode"]
PROGRAM_SECTIONS: Final[list[JsonValue]] = ["struct_ops.s/zigsched_minimal_init", "struct_ops/zigsched_minimal_enqueue", "struct_ops/zigsched_minimal_dispatch"]
MAP_LAYOUTS: Final[JsonObject] = {
    "zigsched_stats": {"type": "BPF_MAP_TYPE_ARRAY", "max_entries": "ZIGSCHED_MINIMAL_NR_STATS", "key": "u32", "value": "u64"},
    "zigsched_events": {"type": "BPF_MAP_TYPE_ARRAY", "max_entries": "ZIGSCHED_MINIMAL_NR_EVENTS", "key": "u32", "value": "u64"},
    "zigsched_policy_config": {"type": "BPF_MAP_TYPE_ARRAY", "max_entries": "1", "key": "u32", "value": "struct zigsched_policy_config"},
}


@dataclass(frozen=True, slots=True)
class Args:
    mode: str
    output: Path
    reason: str


class ParsedArgs(argparse.Namespace):
    mode: str
    output: Path
    reason: str

    def __init__(self) -> None:
        super().__init__()
        self.mode = ""
        self.output = Path()
        self.reason = ""


def parse_args() -> Args:
    parser = argparse.ArgumentParser(description="Emit zigsched BPF metadata JSON")
    _ = parser.add_argument("--mode", choices=("object", "skip"), required=True)
    _ = parser.add_argument("--output", required=True, type=Path)
    _ = parser.add_argument("--reason", default="")
    parsed = parser.parse_args(namespace=ParsedArgs())
    mode = parsed.mode
    reason = parsed.reason
    output = parsed.output
    if mode == "skip" and reason == "":
        raise SystemExit("--reason is required for --mode skip")
    return Args(mode=mode, output=output, reason=reason)


def env(name: str) -> str:
    value = os.environ.get(name, "")
    if value == "":
        raise SystemExit(f"missing environment field: {name}")
    return value


def abi_contract() -> JsonObject:
    return {
        "abi_version": 1,
        "header": env("HEADER_FILE"),
        "header_sha256": env("HEADER_SHA"),
        "source_sha256": env("SOURCE_SHA"),
        "defines": DEFINES,
        "stats_count": 8,
        "events_count": 4,
        "stats": STATS,
        "events": EVENTS,
        "policy_config_fields": POLICY_FIELDS,
        "struct_ops_used_fields": ["name", "flags", "init", "enqueue", "dispatch"],
        "map_layouts": MAP_LAYOUTS,
    }


def tuple_info() -> JsonObject:
    return {
        "target_arch": "bpf",
        "target_define": env("TARGET_DEFINE"),
        "host_arch": env("HOST_ARCH"),
        "host_kernel_release": env("HOST_KERNEL_RELEASE"),
        "vm_required_for_attach": True,
        "vm_contract": env("VM_CONTRACT"),
    }


def tool_versions() -> JsonObject:
    return {
        "clang": env("CLANG_VERSION"),
        "clang_path": env("CLANG_PATH"),
        "llvm_objdump": env("LLVM_OBJDUMP_VERSION"),
        "bpftool": env("BPFT_VERSION"),
        "file": env("FILE_VERSION"),
        "zig": env("ZIG_VERSION"),
    }


def struct_ops() -> JsonObject:
    policy_name = env("POLICY_NAME")
    return {
        "policy_name": policy_name,
        "object_name": env("POLICY_SYMBOL"),
        "scheduler_name": policy_name,
        "object_section": ".struct_ops",
        "program_sections": PROGRAM_SECTIONS,
        "expected_callbacks": ["init", "enqueue", "dispatch"],
        "expected_switch_mode": env("STRUCT_OPS_SWITCH_MODE"),
        "prohibited_switch_modes": ["SCX_OPS_SWITCH_ALL"],
    }


def common() -> JsonObject:
    return {
        "policy_name": env("POLICY_NAME"),
        "policy_symbol": env("POLICY_SYMBOL"),
        "abi_contract": abi_contract(),
        "source": env("SOURCE_FILE"),
        "source_hash": "sha256:" + env("SOURCE_SHA"),
        "source_sha256": env("SOURCE_SHA"),
        "tuple": tuple_info(),
        "tool_versions": tool_versions(),
        "target_arch": "bpf",
        "policy_mode": "minimal-partial-switch",
        "struct_ops": struct_ops(),
        "sched_ext_switch_mode": env("STRUCT_OPS_SWITCH_MODE"),
        "vm_only": True,
        "vm_marker_required": env("VM_MARKER"),
        "vm_contract": env("VM_CONTRACT"),
        "host_mutation": False,
        "host_attach_allowed": False,
        "verification_claimed": False,
    }


def object_metadata() -> JsonObject:
    data = common()
    object_sha = env("OBJECT_SHA")
    data.update({
        "schema": "zig-scheduler/bpf-object-metadata/v1",
        "status": "built",
        "artifact_kind": "sched_ext_struct_ops_policy_object",
        "object": env("OBJECT_FILE"),
        "object_hash": "sha256:" + object_sha,
        "object_sha256": object_sha,
        "clang_version": env("CLANG_VERSION"),
        "btf": "enabled",
        "expected_verifier_object": env("OBJECT_FILE"),
    })
    return data


def skip_metadata(reason: str) -> JsonObject:
    data = common()
    data.update({
        "schema": "zig-scheduler/bpf-build-skip/v1",
        "status": "SKIP",
        "artifact_kind": "sched_ext_struct_ops_policy_skip",
        "reason": reason,
        "object": None,
        "object_hash": None,
        "object_sha256": None,
        "btf": "unavailable-build-skipped",
        "expected_verifier_object": None,
        "skip_text_path": env("SKIP_FILE"),
        "release_eligible": False,
        "skip_is_release_eligible": False,
    })
    return data


def main() -> int:
    args = parse_args()
    data = skip_metadata(args.reason) if args.mode == "skip" else object_metadata()
    _ = args.output.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
