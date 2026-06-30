from __future__ import annotations

import json
from pathlib import Path
from typing import TYPE_CHECKING, Final, Protocol, TypeAlias

from qa.runtime_sample_digest import is_digest_summary
from qa.runtime_sample_fixtures import good_sample as good_sample
from qa.runtime_sample_policy_abi import PolicyAbiError, validate_policy_abi_contract

JsonValue: TypeAlias = None | bool | int | float | str | list["JsonValue"] | dict[str, "JsonValue"]
JsonObject: TypeAlias = dict[str, JsonValue]


class JsonLoader(Protocol):
    def loads(self, text: str) -> JsonValue: ...


if TYPE_CHECKING:
    json_loader: JsonLoader
else:
    json_loader = json

SAMPLE_SCHEMA: Final[str] = "zig-scheduler/runtime-sample/v1"
FORBIDDEN_KEYS: Final[frozenset[str]] = frozenset({"command_line", "cmdline", "argv", "args", "environment", "env", "secret", "token", "api_key"})
FORBIDDEN_TEXT: Final[tuple[str, ...]] = ("--token", "api_key=", "AWS_SECRET", "BEGIN PRIVATE KEY", "password=", "/proc/", "/sys/")
FACT_STATUSES: Final[frozenset[str]] = frozenset({"present", "missing", "unreadable", "unknown"})
SCHED_STATES: Final[frozenset[str]] = frozenset({"disabled", "enabled", "enabling", "disabling", "unknown", "unavailable"})
COUNTERS: Final[tuple[str, ...]] = ("nr_rejected", "dispatch_failed", "fallback", "fatal")
DSQ_DEPTH_FIELDS: Final[tuple[str, ...]] = ("global", "local", "shared")
LATENCY_FIELDS: Final[tuple[str, ...]] = ("p50_us", "p95_us", "p99_us", "max_us")
SCHEDULER_COUNTER_FIELDS: Final[tuple[str, ...]] = ("context_switches", "wakeups", "migrations")
FAIRNESS_STATES: Final[frozenset[str]] = frozenset({"ok", "watch", "starved", "unknown"})
SHA256_ZERO: Final[str] = "0" * 64


class RuntimeSampleError(Exception):
    pass


def load_jsonl(path: Path) -> list[JsonObject]:
    rows: list[JsonObject] = []
    try:
        lines = path.read_text().splitlines()
    except FileNotFoundError as exc:
        raise RuntimeSampleError(f"missing JSONL file: {path}") from exc
    for index, line in enumerate(lines, start=1):
        if line.strip() == "":
            continue
        try:
            raw = json_loader.loads(line)
        except json.JSONDecodeError as exc:
            raise RuntimeSampleError(f"invalid JSON on line {index}: {exc}") from exc
        if not isinstance(raw, dict):
            raise RuntimeSampleError(f"line {index} must contain a JSON object")
        rows.append(raw)
    if not rows:
        raise RuntimeSampleError("runtime sample JSONL is empty")
    return rows


def require_string(data: JsonObject, field: str, context: str) -> str:
    value = data.get(field)
    if isinstance(value, str) and value != "":
        return value
    raise RuntimeSampleError(f"{context} missing non-empty string field: {field}")


def require_bool(data: JsonObject, field: str, context: str) -> bool:
    value = data.get(field)
    if isinstance(value, bool):
        return value
    raise RuntimeSampleError(f"{context} missing bool field: {field}")


def require_int(data: JsonObject, field: str, context: str) -> int:
    value = data.get(field)
    if isinstance(value, int):
        return value
    raise RuntimeSampleError(f"{context} missing int field: {field}")


def require_object(data: JsonObject, field: str, context: str) -> JsonObject:
    value = data.get(field)
    if isinstance(value, dict):
        return value
    raise RuntimeSampleError(f"{context} missing object field: {field}")


def optional_object(data: JsonObject, field: str, context: str) -> JsonObject | None:
    value = data.get(field)
    if value is None:
        return None
    if isinstance(value, dict):
        return value
    raise RuntimeSampleError(f"{context} field must be an object when present: {field}")


def validate_fact(data: JsonObject, field: str, context: str) -> JsonObject:
    fact = require_object(data, field, context)
    status = require_string(fact, "status", f"{context}.{field}")
    if status not in FACT_STATUSES:
        raise RuntimeSampleError(f"{context}.{field} has unsupported status: {status}")
    value = fact.get("value")
    if not isinstance(value, str) or (status == "present" and value == ""):
        raise RuntimeSampleError(f"{context}.{field} has invalid value")
    reject_private_leaks(value, f"{context}.{field}.value")
    return fact


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

def validate_nonnegative_fields(data: JsonObject, fields: tuple[str, ...], context: str) -> None:
    for field in fields:
        if require_int(data, field, context) < 0:
            raise RuntimeSampleError(f"{context}.{field} must be nonnegative")


def validate_optional_counter_sets(row: JsonObject, context: str) -> None:
    counters = optional_object(row, "policy_counters", context)
    if counters is not None:
        validate_nonnegative_fields(counters, COUNTERS, f"{context}.policy_counters")
    loss = optional_object(row, "sample_loss", context)
    if loss is not None:
        validate_nonnegative_fields(loss, ("lost_samples", "backpressure_dropped"), f"{context}.sample_loss")
        for field in ("ring_buffer_overruns", "reader_lag_events"):
            if field in loss and require_int(loss, field, f"{context}.sample_loss") < 0:
                raise RuntimeSampleError(f"{context}.sample_loss.{field} must be nonnegative")


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


def validate_scheduler_telemetry(row: JsonObject, context: str) -> None:
    for field, fields in (("dsq_depth", DSQ_DEPTH_FIELDS), ("queue_latency", LATENCY_FIELDS), ("scheduler_counters", SCHEDULER_COUNTER_FIELDS)):
        counters = optional_object(row, field, context)
        if counters is not None:
            validate_nonnegative_fields(counters, fields, f"{context}.{field}")
    fairness = optional_object(row, "fairness", context)
    if fairness is not None:
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


def reject_private_leaks(value: JsonValue, context: str) -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            lowered = key.lower()
            if lowered in FORBIDDEN_KEYS:
                raise RuntimeSampleError(f"privacy-unsafe key in runtime sample: {context}.{key}")
            reject_private_leaks(child, f"{context}.{key}")
        return
    if isinstance(value, list):
        for index, child in enumerate(value):
            reject_private_leaks(child, f"{context}[{index}]")
        return
    if isinstance(value, str):
        for needle in FORBIDDEN_TEXT:
            if needle in value:
                raise RuntimeSampleError(f"privacy-unsafe text in runtime sample: {context}")


def validate_sample(row: JsonObject, index: int) -> None:
    context = f"sample[{index}]"
    reject_private_leaks(row, context)
    if require_string(row, "schema", context) != SAMPLE_SCHEMA:
        raise RuntimeSampleError(f"{context} has unsupported schema")
    _ = require_int(row, "sequence", context)
    validate_sched_ext_facts(row, context)
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
    validate_scheduler_telemetry(row, context)
    validate_policy_abi(row, context)


def validate_file(path: Path) -> None:
    for index, row in enumerate(load_jsonl(path)):
        validate_sample(row, index)



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
