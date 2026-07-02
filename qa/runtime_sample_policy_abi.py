from __future__ import annotations

from typing import Final, TypeAlias

JsonValue: TypeAlias = None | bool | int | float | str | list["JsonValue"] | dict[str, "JsonValue"]
JsonObject: TypeAlias = dict[str, JsonValue]

POLICY_VERSION: Final = "sched_ext_cgroup_abi_v3"
ABI_LABEL: Final = "zigsched-bpf-abi-v3"
SEMANTICS: Final[dict[str, str]] = {
    "cpu.weight": "callback-observed",
    "cgroup.lifecycle": "observed",
    "cgroup.move": "observed",
    "cpuset.cpus": "observed-only",
    "cpuset.cpus.effective": "observed-only",
    "cpu.pressure": "observed-only",
    "cpu.max": "deferred",
    "uclamp": "deferred",
    "cgroup_set_idle": "refused",
}

CGROUP_POLICY_FIELDS: Final[tuple[str, ...]] = (
    "last_weight",
    "weight_generation",
    "move_generation",
    "callback_observed_knobs",
    "observed_knobs",
    "deferred_knobs",
)
CGROUP_CALLBACK_STATS: Final[tuple[str, ...]] = (
    "cgroup_init_calls",
    "cgroup_exit_calls",
    "cgroup_move_calls",
    "cgroup_set_weight_calls",
    "cgroup_weight_observed",
)
DSQ_COHERENCE_FIELDS: Final[tuple[str, ...]] = (
    "fifo_insert_dispatch_coherent",
    "vtime_insert_dispatch_coherent",
    "dispatch_empty_accounted",
)


def good_cgroup_policy_map(status: str = "present") -> JsonObject:
    if status == "unavailable":
        return {"status": "unavailable", "reason": "map unavailable before VM attach"}
    return {
        "status": "present",
        "map_name": "zigsched_cgroup_policy",
        "max_entries": 1,
        "key": "0",
        "fields": list(CGROUP_POLICY_FIELDS),
        "last_weight": 200,
        "weight_generation": 1,
        "move_generation": 1,
        "callback_observed_knobs": ["cpu.weight"],
        "observed_knobs": ["cpuset.cpus", "cpuset.cpus.effective", "cpu.pressure"],
        "deferred_knobs": ["cpu.max", "uclamp"],
    }


def good_cgroup_callback_stats(status: str = "present") -> JsonObject:
    if status == "unavailable":
        return {"status": "unavailable", "reason": "callback counters unavailable before VM attach"}
    return {
        "status": "present",
        "cgroup_init_calls": 1,
        "cgroup_exit_calls": 1,
        "cgroup_move_calls": 1,
        "cgroup_set_weight_calls": 1,
        "cgroup_weight_observed": 1,
        "cpu_weight_callback_observed": True,
    }


def good_dsq_counter_coherence(status: str = "present") -> JsonObject:
    if status == "unavailable":
        return {"status": "unavailable", "reason": "DSQ counters unavailable before VM attach"}
    return {
        "status": "present",
        "counter_source": "zigsched_stats+zigsched_events",
        "fifo_insert_dispatch_coherent": True,
        "vtime_insert_dispatch_coherent": True,
        "dispatch_empty_accounted": True,
    }


class PolicyAbiError(Exception):
    """Raised when runtime policy ABI metadata is malformed."""


def good_policy_abi(object_sha256: str = "unavailable") -> JsonObject:
    return {
        "policy_name": "zigsched_minimal",
        "policy_version": POLICY_VERSION,
        "struct_ops": "zigsched_minimal_ops",
        "object_sha256": object_sha256,
        "btf_required": True,
        "abi_version": 3,
        "abi_label": ABI_LABEL,
        "cgroup_semantics": dict(SEMANTICS),
        "vm_only": True,
        "host_mutation": False,
        "production_claim": False,
        "release_eligible": False,
        "cgroup_policy_map": good_cgroup_policy_map(),
        "cgroup_callback_stats": good_cgroup_callback_stats(),
        "dsq_counter_coherence": good_dsq_counter_coherence(),
    }


def require_string(data: JsonObject, field: str, context: str) -> str:
    value = data.get(field)
    if isinstance(value, str) and value != "":
        return value
    raise PolicyAbiError(f"{context} missing non-empty string field: {field}")


def require_bool(data: JsonObject, field: str, context: str) -> bool:
    value = data.get(field)
    if isinstance(value, bool):
        return value
    raise PolicyAbiError(f"{context} missing bool field: {field}")


def require_int(data: JsonObject, field: str, context: str) -> int:
    value = data.get(field)
    if isinstance(value, int):
        return value
    raise PolicyAbiError(f"{context} missing int field: {field}")


def require_object(data: JsonObject, field: str, context: str) -> JsonObject:
    value = data.get(field)
    if isinstance(value, dict):
        return value
    raise PolicyAbiError(f"{context} missing object field: {field}")


def require_string_list(data: JsonObject, field: str, context: str) -> list[str]:
    value = data.get(field)
    if not isinstance(value, list) or not all(isinstance(item, str) and item != "" for item in value):
        raise PolicyAbiError(f"{context} missing string list field: {field}")
    return [item for item in value if isinstance(item, str)]


def require_status(data: JsonObject, context: str) -> str:
    status = require_string(data, "status", context)
    if status not in {"present", "unavailable"}:
        raise PolicyAbiError(f"{context}.status must be present or unavailable")
    if status == "unavailable":
        _ = require_string(data, "reason", context)
    return status


def validate_cgroup_policy_map(evidence: JsonObject, context: str) -> None:
    if require_status(evidence, context) == "unavailable":
        return
    if require_string(evidence, "map_name", context) != "zigsched_cgroup_policy":
        raise PolicyAbiError(f"{context}.map_name must be zigsched_cgroup_policy")
    if require_int(evidence, "max_entries", context) != 1:
        raise PolicyAbiError(f"{context}.max_entries must be 1")
    if require_string(evidence, "key", context) != "0":
        raise PolicyAbiError(f"{context}.key must be 0")
    if tuple(require_string_list(evidence, "fields", context)) != CGROUP_POLICY_FIELDS:
        raise PolicyAbiError(f"{context}.fields must match ABI-v3 cgroup policy layout")
    for field in ("last_weight", "weight_generation", "move_generation"):
        if require_int(evidence, field, context) < 0:
            raise PolicyAbiError(f"{context}.{field} must be nonnegative")
    if "cpu.weight" not in require_string_list(evidence, "callback_observed_knobs", context):
        raise PolicyAbiError(f"{context}.callback_observed_knobs must include cpu.weight")
    observed = set(require_string_list(evidence, "observed_knobs", context))
    if not {"cpuset.cpus", "cpuset.cpus.effective", "cpu.pressure"}.issubset(observed):
        raise PolicyAbiError(f"{context}.observed_knobs must include observed-only cgroup knobs")
    deferred = set(require_string_list(evidence, "deferred_knobs", context))
    if not {"cpu.max", "uclamp"}.issubset(deferred):
        raise PolicyAbiError(f"{context}.deferred_knobs must keep cpu.max and uclamp deferred")


def validate_cgroup_callback_stats(evidence: JsonObject, context: str) -> None:
    if require_status(evidence, context) == "unavailable":
        return
    for field in CGROUP_CALLBACK_STATS:
        if require_int(evidence, field, context) < 0:
            raise PolicyAbiError(f"{context}.{field} must be nonnegative")
    if require_int(evidence, "cgroup_set_weight_calls", context) > 0 and not require_bool(evidence, "cpu_weight_callback_observed", context):
        raise PolicyAbiError(f"{context}.cpu_weight_callback_observed must be true when set-weight callbacks fired")
    if require_int(evidence, "cgroup_weight_observed", context) > require_int(evidence, "cgroup_set_weight_calls", context):
        raise PolicyAbiError(f"{context}.cgroup_weight_observed cannot exceed cgroup_set_weight_calls")


def validate_dsq_counter_coherence(evidence: JsonObject, context: str) -> None:
    if require_status(evidence, context) == "unavailable":
        return
    if require_string(evidence, "counter_source", context) != "zigsched_stats+zigsched_events":
        raise PolicyAbiError(f"{context}.counter_source must be zigsched_stats+zigsched_events")
    for field in DSQ_COHERENCE_FIELDS:
        if not require_bool(evidence, field, context):
            raise PolicyAbiError(f"{context}.{field} must be true")


def validate_v3_cgroup_evidence(abi: JsonObject, context: str) -> None:
    validate_cgroup_policy_map(require_object(abi, "cgroup_policy_map", context), f"{context}.cgroup_policy_map")
    validate_cgroup_callback_stats(require_object(abi, "cgroup_callback_stats", context), f"{context}.cgroup_callback_stats")
    validate_dsq_counter_coherence(require_object(abi, "dsq_counter_coherence", context), f"{context}.dsq_counter_coherence")


def validate_v3_policy_abi(abi: JsonObject, context: str) -> None:
    if require_string(abi, "policy_version", context) != POLICY_VERSION:
        raise PolicyAbiError(f"{context}.policy_version must be {POLICY_VERSION}")
    if require_int(abi, "abi_version", context) != 3:
        raise PolicyAbiError(f"{context}.abi_version must be 3")
    if require_string(abi, "abi_label", context) != ABI_LABEL:
        raise PolicyAbiError(f"{context}.abi_label must be {ABI_LABEL}")
    if not require_bool(abi, "vm_only", context):
        raise PolicyAbiError(f"{context}.vm_only must be true")
    if require_bool(abi, "host_mutation", context):
        raise PolicyAbiError(f"{context}.host_mutation must be false")
    if require_bool(abi, "production_claim", context):
        raise PolicyAbiError(f"{context}.production_claim must be false")
    if require_bool(abi, "release_eligible", context):
        raise PolicyAbiError(f"{context}.release_eligible must be false")
    semantics = require_object(abi, "cgroup_semantics", context)
    if set(semantics) != set(SEMANTICS):
        raise PolicyAbiError(f"{context}.cgroup_semantics keys do not match ABI-v3 contract")
    for knob, expected in SEMANTICS.items():
        actual = semantics.get(knob)
        if actual != expected:
            raise PolicyAbiError(f"{context}.cgroup_semantics.{knob} must be {expected}")
    validate_v3_cgroup_evidence(abi, context)


def validate_policy_abi_contract(abi: JsonObject, context: str) -> None:
    for field in ("policy_name", "policy_version", "struct_ops", "object_sha256"):
        _ = require_string(abi, field, context)
    _ = require_bool(abi, "btf_required", context)
    abi_version = abi.get("abi_version")
    if abi_version is None:
        return
    validate_v3_policy_abi(abi, context)
