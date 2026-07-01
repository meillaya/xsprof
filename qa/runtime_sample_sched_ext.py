from __future__ import annotations

from typing import Final

from qa.runtime_sample_common import (
    JsonObject,
    RuntimeSampleError,
    optional_object,
    reject_private_leaks,
    require_object,
    require_string,
    validate_fact,
)
from qa.runtime_sample_digest import is_digest_summary
from qa.runtime_sample_policy_abi import SEMANTICS

SCHED_STATES: Final[frozenset[str]] = frozenset({"disabled", "enabled", "enabling", "disabling", "unknown", "unavailable"})
SCHED_EXT_PHASES: Final[frozenset[str]] = frozenset({"before_attach", "during_attach", "after_rollback"})
TASK_EXT_UNAVAILABLE_VALUES: Final[frozenset[str]] = frozenset({"", "unknown", "unavailable"})


def validate_sched_ext_facts(row: JsonObject, context: str) -> None:
    state = validate_fact(row, "state", context)
    state_value = str(state["value"]).strip()
    if state["status"] == "present" and state_value not in SCHED_STATES:
        raise RuntimeSampleError(f"{context}.state has unsupported sched_ext state: {state_value}")
    _ = validate_fact(row, "ops", context)
    _ = validate_fact(row, "enable_seq", context)
    enable_value = str(require_object(row, "enable_seq", context)["value"]).strip()
    if enable_value != "unavailable" and not enable_value.isdecimal():
        raise RuntimeSampleError(f"{context}.enable_seq must be numeric or unavailable")
    _ = validate_fact(row, "events", context)
    _ = validate_fact(row, "nr_rejected", context)
    debug_dump = validate_fact(row, "debug_dump", context)
    debug_value = str(debug_dump["value"])
    if debug_dump["status"] == "present" and not is_digest_summary(debug_value):
        raise RuntimeSampleError(f"{context}.debug_dump must be a redacted digest summary")
    for field in ("root_ops", "scheduler_events"):
        if field in row:
            _ = validate_fact(row, field, context)


def validate_task_ext_enabled(row: JsonObject, context: str) -> None:
    task_ext = optional_object(row, "task_ext_enabled", context)
    if task_ext is None:
        return
    fact = validate_fact(row, "task_ext_enabled", context)
    value = str(fact["value"])
    if fact["status"] == "present":
        if value not in {"true", "false"}:
            raise RuntimeSampleError(f"{context}.task_ext_enabled present evidence must be true or false")
        return
    if value not in TASK_EXT_UNAVAILABLE_VALUES:
        raise RuntimeSampleError(f"{context}.task_ext_enabled unavailable evidence must be explicit")


def validate_cgroup_semantic_labels(row: JsonObject, context: str) -> None:
    labels = optional_object(row, "cgroup_semantic_labels", context)
    if labels is None:
        return
    if set(labels) != set(SEMANTICS):
        raise RuntimeSampleError(f"{context}.cgroup_semantic_labels keys do not match ABI-v3 contract")
    for knob, expected in SEMANTICS.items():
        actual = labels.get(knob)
        if actual != expected:
            raise RuntimeSampleError(f"{context}.cgroup_semantic_labels.{knob} must be {expected}")


def validate_teardown_rollback(row: JsonObject, context: str) -> None:
    for field in ("teardown_state", "rollback_state"):
        if field in row:
            _ = validate_fact(row, field, context)


def validate_sched_ext_phase(row: JsonObject, context: str) -> None:
    if "sched_ext_phase" not in row:
        return
    phase = require_string(row, "sched_ext_phase", context)
    reject_private_leaks(phase, f"{context}.sched_ext_phase")
    if phase not in SCHED_EXT_PHASES:
        raise RuntimeSampleError(f"{context}.sched_ext_phase has unsupported value")
