"""ABI-v3 cgroup metadata accepted by the BPF ABI freeze gate."""

from __future__ import annotations

from typing import Final, TypeAlias

JsonValue: TypeAlias = str | int | list[str]
JsonObject: TypeAlias = dict[str, JsonValue]

EXPECTED_CGROUP_POLICY_FIELDS: Final = (
    "zigsched_u64 last_weight",
    "zigsched_u64 weight_generation",
    "zigsched_u64 move_generation",
    "zigsched_u64 callback_observed_knobs",
    "zigsched_u64 observed_knobs",
    "zigsched_u64 deferred_knobs",
)
ABI_V3_ACCEPTED_CALLBACKS: Final = (
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
)
CGROUP_KNOB_SEMANTICS: Final[dict[str, str]] = {
    "cpu.weight": "callback-observed",
    "cpu.max": "deferred",
    "cpuset.cpus": "observed-only",
    "cpuset.cpus.effective": "observed-only",
    "cpu.pressure": "observed-only",
    "uclamp": "deferred",
}
EXPECTED_CGROUP_EVIDENCE: Final[JsonObject] = {
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
ABI_V3_PROGRAM_SECTIONS: Final = (
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
)
ABI_V3_STRUCT_OPS_USED_FIELDS: Final = (
    "name",
    "flags",
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
)
