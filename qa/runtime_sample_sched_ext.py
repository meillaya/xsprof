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
SCHED_EXT_PHASES: Final[frozenset[str]] = frozenset({"before_attach", "during_attach", "after_attach", "after_rollback", "after_scheduler_exit", "after_watchdog_disable", "after_forced_disable"})
TASK_EXT_UNAVAILABLE_VALUES: Final[frozenset[str]] = frozenset({"", "unknown", "unavailable"})


def validate_nonnegative_fact_value(fact: JsonObject, field: str, context: str) -> None:
    value = str(fact["value"]).strip()
    if value == "unavailable":
        return
    if not value.isdecimal():
        raise RuntimeSampleError(f"{context}.{field} must be a nonnegative integer or unavailable")


def numeric_fact_value(row: JsonObject, field: str) -> int | None:
    value = str(require_object(row, field, "runtime sample")["value"]).strip()
    return int(value) if value.isdecimal() else None


def validate_sched_ext_facts(row: JsonObject, context: str) -> None:
    state = validate_fact(row, "state", context)
    state_value = str(state["value"]).strip()
    if state["status"] == "present" and state_value not in SCHED_STATES:
        raise RuntimeSampleError(f"{context}.state has unsupported sched_ext state: {state_value}")
    _ = validate_fact(row, "ops", context)
    enable_seq = validate_fact(row, "enable_seq", context)
    validate_nonnegative_fact_value(enable_seq, "enable_seq", context)
    _ = validate_fact(row, "events", context)
    nr_rejected = validate_fact(row, "nr_rejected", context)
    validate_nonnegative_fact_value(nr_rejected, "nr_rejected", context)
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


def validate_sched_ext_sequence(rows: list[JsonObject]) -> None:
    last_sequence: int | None = None
    last_enable_seq: int | None = None
    for index, row in enumerate(rows):
        context = f"sample[{index}]"
        sequence = row.get("sequence")
        if isinstance(sequence, int):
            if last_sequence is not None and sequence <= last_sequence:
                raise RuntimeSampleError(f"{context}.sequence must increase monotonically")
            last_sequence = sequence
        enable_seq = numeric_fact_value(row, "enable_seq")
        if enable_seq is not None:
            if last_enable_seq is not None and enable_seq < last_enable_seq:
                raise RuntimeSampleError(f"{context}.enable_seq is stale relative to earlier sched_ext state")
            last_enable_seq = enable_seq
        phase = row.get("sched_ext_phase")
        state_obj = row.get("state")
        state_value = str(state_obj.get("value", "")) if isinstance(state_obj, dict) else ""
        ops_obj = row.get("ops")
        ops_value = str(ops_obj.get("value", "")) if isinstance(ops_obj, dict) else ""
        if phase == "before_attach" and state_value == "enabled":
            raise RuntimeSampleError(f"{context}.sched_ext_phase before_attach cannot report enabled state")
        if phase in {"after_rollback", "after_scheduler_exit", "after_watchdog_disable", "after_forced_disable"}:
            if state_value not in {"disabled", "unknown", "unavailable"}:
                raise RuntimeSampleError(f"{context}.{phase} must report disabled/unknown/unavailable state")
            if state_value == "disabled" and ops_value not in {"none", "unavailable", "unknown"}:
                raise RuntimeSampleError(f"{context}.{phase} disabled state must not report live root ops")
