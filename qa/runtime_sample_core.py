from __future__ import annotations

from pathlib import Path
from typing import Final

from qa.runtime_sample_digest import is_digest_summary
from qa.runtime_sample_common import (
    JsonObject,
    JsonValue,
    RuntimeSampleError,
    optional_object,
    reject_private_leaks,
    require_bool,
    require_int,
    require_object,
    require_string,
    load_jsonl,
    validate_fact,
)
from qa.runtime_sample_fields import ROOT_FIELDS
from qa.runtime_sample_fixtures import good_sample as good_sample
from qa.runtime_sample_policy_abi import PolicyAbiError, validate_policy_abi_contract
from qa.runtime_sample_sched_ext import (
    validate_cgroup_semantic_labels,
    validate_sched_ext_facts,
    validate_sched_ext_phase,
    validate_sched_ext_sequence,
    validate_task_ext_enabled,
    validate_teardown_rollback,
)

SAMPLE_SCHEMA: Final[str] = "zig-scheduler/runtime-sample/v1"
__all__: Final[tuple[str, ...]] = ("JsonObject", "JsonValue", "RuntimeSampleError", "good_sample", "validate_alert_order", "validate_file")
COUNTERS: Final[tuple[str, ...]] = ("nr_rejected", "dispatch_failed", "fallback", "fatal")
DSQ_DEPTH_FIELDS: Final[tuple[str, ...]] = ("global", "local", "shared")
LATENCY_FIELDS: Final[tuple[str, ...]] = ("p50_us", "p95_us", "p99_us", "max_us")
SCHEDULER_COUNTER_FIELDS: Final[tuple[str, ...]] = ("context_switches", "wakeups", "migrations")
FAIRNESS_STATES: Final[frozenset[str]] = frozenset({"ok", "watch", "starved", "unknown"})
SHA256_ZERO: Final[str] = "0" * 64
UNAVAILABLE_STATUSES: Final[frozenset[str]] = frozenset({"missing", "unreadable", "unknown"})
UNAVAILABLE_VALUES: Final[frozenset[str]] = frozenset({"", "missing", "none", "null", "unavailable", "unknown"})


def validate_nonnegative_fields(data: JsonObject, fields: tuple[str, ...], context: str) -> None:
    for field in fields:
        if require_int(data, field, context) < 0:
            raise RuntimeSampleError(f"{context}.{field} must be nonnegative")


def validate_optional_counter_sets(row: JsonObject, context: str) -> None:
    counters = optional_object(row, "policy_counters", context)
    if counters is not None:
        if is_unavailable_object(counters):
            pass
        else:
            validate_nonnegative_fields(counters, COUNTERS, f"{context}.policy_counters")
    loss = optional_object(row, "sample_loss", context)
    if loss is not None:
        if is_unavailable_object(loss):
            return
        validate_nonnegative_fields(loss, ("lost_samples", "backpressure_dropped"), f"{context}.sample_loss")
        for field in ("ring_buffer_overruns", "reader_lag_events"):
            if field in loss and require_int(loss, field, f"{context}.sample_loss") < 0:
                raise RuntimeSampleError(f"{context}.sample_loss.{field} must be nonnegative")


def is_unavailable_object(data: JsonObject) -> bool:
    status = data.get("status")
    value = data.get("value")
    return isinstance(status, str) and status in UNAVAILABLE_STATUSES and isinstance(value, str) and value.casefold() in UNAVAILABLE_VALUES


def validate_metric_object(data: JsonObject, fields: tuple[str, ...], context: str) -> None:
    if is_unavailable_object(data):
        return
    validate_nonnegative_fields(data, fields, context)


def validate_counter_map(data: JsonObject, context: str) -> None:
    if not data:
        raise RuntimeSampleError(f"{context} must not be empty")
    for key, value in data.items():
        if key.startswith("/") or ".." in key or key == "":
            raise RuntimeSampleError(f"{context}.{key} is not a stable redacted key")
        reject_private_leaks(key, f"{context}.{key}")
        if not isinstance(value, int) or value < 0:
            raise RuntimeSampleError(f"{context}.{key} must be a nonnegative integer")


def validate_benchmark_refs(row: JsonObject, context: str) -> None:
    refs = row.get("benchmark_histograms")
    if refs is None:
        return
    if not isinstance(refs, list):
        raise RuntimeSampleError(f"{context}.benchmark_histograms must be a list")
    for index, item in enumerate(refs):
        if not isinstance(item, dict):
            raise RuntimeSampleError(f"{context}.benchmark_histograms[{index}] must be an object")
        ref_context = f"{context}.benchmark_histograms[{index}]"
        path = require_string(item, "record_path", ref_context)
        if path.startswith("/") or ".." in Path(path).parts:
            raise RuntimeSampleError(f"{ref_context}.record_path must be repo-relative")
        validate_digest(require_string(item, "record_sha256", ref_context), f"{ref_context}.record_sha256")
        _ = require_string(item, "histogram_id", ref_context)
        if require_bool(item, "record_only", ref_context) is not True:
            raise RuntimeSampleError(f"{ref_context}.record_only must be true")



def validate_root_fields(row: JsonObject, context: str) -> None:
    for field in row:
        if field not in ROOT_FIELDS:
            raise RuntimeSampleError(f"{context} has unsupported runtime sample field: {field}")


def validate_scheduler_telemetry(row: JsonObject, context: str) -> None:
    for field, fields in (("dsq_depth", DSQ_DEPTH_FIELDS), ("queue_latency", LATENCY_FIELDS), ("scheduler_counters", SCHEDULER_COUNTER_FIELDS)):
        counters = optional_object(row, field, context)
        if counters is not None:
            validate_metric_object(counters, fields, f"{context}.{field}")
    fairness = optional_object(row, "fairness", context)
    if fairness is not None:
        if not is_unavailable_object(fairness):
            state = require_string(fairness, "state", f"{context}.fairness")
            if state not in FAIRNESS_STATES:
                raise RuntimeSampleError(f"{context}.fairness.state has unsupported value")
            validate_nonnegative_fields(fairness, ("starved_tasks", "max_wait_us"), f"{context}.fairness")
    task_counts = optional_object(row, "task_counts", context)
    if task_counts is not None:
        validate_counter_map(require_object(task_counts, "by_cgroup_digest", f"{context}.task_counts"), f"{context}.task_counts.by_cgroup_digest")
        validate_counter_map(require_object(task_counts, "by_class", f"{context}.task_counts"), f"{context}.task_counts.by_class")
    sched_ext = optional_object(row, "sched_ext_observation", context)
    if sched_ext is not None:
        dump = validate_fact(sched_ext, "dump", f"{context}.sched_ext_observation")
        if dump["status"] == "present" and not is_digest_summary(str(dump["value"])):
            raise RuntimeSampleError(f"{context}.sched_ext_observation.dump must be a redacted digest summary")
        tracepoints = require_object(sched_ext, "tracepoints", f"{context}.sched_ext_observation")
        validate_counter_map(tracepoints, f"{context}.sched_ext_observation.tracepoints")
    validate_benchmark_refs(row, context)


def validate_policy_abi(row: JsonObject, context: str) -> None:
    abi = require_object(row, "policy_abi", context)
    try:
        validate_policy_abi_contract(abi, f"{context}.policy_abi")
    except PolicyAbiError as exc:
        raise RuntimeSampleError(str(exc)) from exc
    reject_private_leaks(abi, f"{context}.policy_abi")


def validate_digest(value: str, context: str) -> None:
    if len(value) != 64 or value == SHA256_ZERO or any(char not in "0123456789abcdef" for char in value):
        raise RuntimeSampleError(f"{context} must be a lowercase nonzero sha256 digest")


def validate_sample(row: JsonObject, index: int) -> None:
    context = f"sample[{index}]"
    reject_private_leaks(row, context)
    validate_root_fields(row, context)
    if require_string(row, "schema", context) != SAMPLE_SCHEMA:
        raise RuntimeSampleError(f"{context} has unsupported schema")
    _ = require_int(row, "sequence", context)
    validate_sched_ext_facts(row, context)
    validate_sched_ext_phase(row, context)
    _ = require_string(row, "events_hash", context)
    digest = require_string(row, "cgroup_membership_digest", context)
    validate_digest(digest, f"{context}.cgroup_membership_digest")
    for field in ("cgroup_membership_status", "workload"):
        if field in row:
            _ = validate_fact(row, field, context)
    _ = require_bool(row, "workload_alive", context)
    if require_bool(row, "private_command_lines_sampled", context):
        raise RuntimeSampleError(f"{context} sampled private command lines")
    validate_optional_counter_sets(row, context)
    validate_task_ext_enabled(row, context)
    validate_cgroup_semantic_labels(row, context)
    validate_teardown_rollback(row, context)
    validate_scheduler_telemetry(row, context)
    validate_policy_abi(row, context)


def validate_file(path: Path) -> None:
    rows = load_jsonl(path)
    for index, row in enumerate(rows):
        validate_sample(row, index)
    validate_sched_ext_sequence(rows)


def validate_alert_order(rows: list[JsonObject], label: str) -> None:
    rejected_seen = False
    dead_seen = False
    for index, row in enumerate(rows):
        event = row.get("event")
        reason = row.get("reason")
        if event == "runtime_sample":
            rejected = row.get("nr_rejected")
            if (isinstance(rejected, int) and rejected > 0) or (isinstance(rejected, str) and rejected.isdecimal() and int(rejected) > 0):
                rejected_seen = True
            if row.get("workload_alive") is False:
                dead_seen = True
        if reason == "runtime_nr_rejected_nonzero" and not rejected_seen:
            raise RuntimeSampleError(f"{label} incident precedes nonzero nr_rejected sample at row {index}")
        if reason == "runtime_workload_dead" and not dead_seen:
            raise RuntimeSampleError(f"{label} incident precedes workload-dead sample at row {index}")
