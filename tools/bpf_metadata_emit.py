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
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Final, TypeAlias

if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from tools.bpf_metadata_cgroup import (
    CALLBACKS,
    CGROUP_EVIDENCE,
    CGROUP_KNOB_SEMANTICS,
    CGROUP_POLICY_FIELDS,
    MAP_LAYOUTS,
    PROGRAM_SECTIONS,
)

JsonValue: TypeAlias = None | bool | int | float | str | list["JsonValue"] | dict[str, "JsonValue"]
JsonObject: TypeAlias = dict[str, JsonValue]

DEFINES: Final[JsonObject] = {
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
STATS: Final[list[JsonValue]] = [
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
]
STATS_FIELDS: Final[list[JsonValue]] = [
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
]
EVENTS: Final[list[JsonValue]] = [
    "ZIGSCHED_EVENT_SELECT_CPU_FALLBACK",
    "ZIGSCHED_EVENT_DISPATCH_EMPTY",
    "ZIGSCHED_EVENT_INIT_FIFO_DSQ_FAILED",
    "ZIGSCHED_EVENT_INIT_VTIME_DSQ_FAILED",
    "ZIGSCHED_EVENT_CGROUP_MOVE_OBSERVED",
    "ZIGSCHED_EVENT_CGROUP_WEIGHT_OBSERVED",
]
POLICY_FIELDS: Final[list[JsonValue]] = ["zigsched_u64 fifo_dsq", "zigsched_u64 vtime_dsq", "zigsched_u64 starvation_ns_max", "zigsched_u64 mode", "zigsched_u64 cgroup_knob_support"]
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
        "abi_version": 3,
        "header": env("HEADER_FILE"),
        "header_sha256": env("HEADER_SHA"),
        "source_sha256": env("SOURCE_SHA"),
        "defines": DEFINES,
        "stats_count": 13,
        "events_count": 6,
        "stats": STATS,
        "events": EVENTS,
        "stats_fields": STATS_FIELDS,
        "policy_config_fields": POLICY_FIELDS,
        "cgroup_policy_fields": CGROUP_POLICY_FIELDS,
        "struct_ops_used_fields": ["name", "flags", "select_cpu", "init", "cgroup_init", "cgroup_exit", "cgroup_prep_move", "cgroup_move", "cgroup_cancel_move", "cgroup_set_weight", "enqueue", "dispatch"],
        "abi_v3_accepted_callbacks": CALLBACKS,
        "abi_v3_source_status": "implemented",
        "cgroup_knob_semantics": CGROUP_KNOB_SEMANTICS,
        "cgroup_evidence": CGROUP_EVIDENCE,
        "tuple_reference": "docs/releases/supported-kernel-tuples.md",
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
        "tuple_reference": "docs/releases/supported-kernel-tuples.md",
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
        "expected_callbacks": CALLBACKS,
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
