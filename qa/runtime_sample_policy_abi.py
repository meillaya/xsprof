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


def validate_policy_abi_contract(abi: JsonObject, context: str) -> None:
    for field in ("policy_name", "policy_version", "struct_ops", "object_sha256"):
        _ = require_string(abi, field, context)
    _ = require_bool(abi, "btf_required", context)
    abi_version = abi.get("abi_version")
    if abi_version is None:
        return
    validate_v3_policy_abi(abi, context)
