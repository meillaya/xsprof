#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
# ─── How to run ───
# python3 -m py_compile tools/bpf_metadata_cgroup.py
"""ABI-v3 cgroup metadata fragments for BPF metadata emission."""

from __future__ import annotations

from typing import Final, TypeAlias

JsonValue: TypeAlias = None | bool | int | float | str | list["JsonValue"] | dict[str, "JsonValue"]
JsonObject: TypeAlias = dict[str, JsonValue]

CGROUP_POLICY_FIELDS: Final[list[JsonValue]] = [
    "zigsched_u64 last_weight",
    "zigsched_u64 weight_generation",
    "zigsched_u64 move_generation",
    "zigsched_u64 callback_observed_knobs",
    "zigsched_u64 observed_knobs",
    "zigsched_u64 deferred_knobs",
]
PROGRAM_SECTIONS: Final[list[JsonValue]] = [
    "struct_ops/zigsched_minimal_select_cpu",
    "struct_ops.s/zigsched_minimal_init",
    "struct_ops/zigsched_minimal_cgroup_init",
    "struct_ops/zigsched_minimal_cgroup_exit",
    "struct_ops/zigsched_minimal_cgroup_prep_move",
    "struct_ops/zigsched_minimal_cgroup_move",
    "struct_ops/zigsched_minimal_cgroup_cancel_move",
    "struct_ops/zigsched_minimal_cgroup_set_weight",
    "struct_ops/zigsched_minimal_enqueue",
    "struct_ops/zigsched_minimal_dispatch",
]
CALLBACKS: Final[list[JsonValue]] = [
    "select_cpu",
    "init",
    "cgroup_init",
    "cgroup_exit",
    "cgroup_prep_move",
    "cgroup_move",
    "cgroup_cancel_move",
    "cgroup_set_weight",
    "enqueue",
    "dispatch",
]
MAP_LAYOUTS: Final[JsonObject] = {
    "zigsched_stats": {"type": "BPF_MAP_TYPE_ARRAY", "max_entries": "ZIGSCHED_MINIMAL_NR_STATS", "key": "u32", "value": "u64"},
    "zigsched_events": {"type": "BPF_MAP_TYPE_ARRAY", "max_entries": "ZIGSCHED_MINIMAL_NR_EVENTS", "key": "u32", "value": "u64"},
    "zigsched_policy_config": {"type": "BPF_MAP_TYPE_ARRAY", "max_entries": "1", "key": "u32", "value": "struct zigsched_policy_config"},
    "zigsched_cgroup_policy": {"type": "BPF_MAP_TYPE_ARRAY", "max_entries": "1", "key": "u32", "value": "struct zigsched_cgroup_policy"},
}
CGROUP_KNOB_SEMANTICS: Final[JsonObject] = {
    "cpu.weight": "callback-observed",
    "cpu.max": "deferred",
    "cpuset.cpus": "observed-only",
    "cpuset.cpus.effective": "observed-only",
    "cpu.pressure": "observed-only",
    "uclamp": "deferred",
}
CGROUP_EVIDENCE: Final[JsonObject] = {
    "policy_map": "zigsched_cgroup_policy",
    "policy_map_max_entries": 1,
    "callback_stats": [
        "cgroup_init_calls",
        "cgroup_exit_calls",
        "cgroup_move_calls",
        "cgroup_set_weight_calls",
        "cgroup_weight_observed",
    ],
    "cpu_weight": "callback-observed",
    "cpu_max": "deferred",
    "uclamp": "deferred",
    "dsq_counter_coherence": "required",
}
