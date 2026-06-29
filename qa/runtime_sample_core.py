from __future__ import annotations

import json
from pathlib import Path
from typing import TYPE_CHECKING, Final, Protocol, TypeAlias

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
    if debug_dump["status"] == "present" and not (debug_value.startswith("sha256:") and ";bytes:" in debug_value):
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


def validate_policy_abi(row: JsonObject, context: str) -> None:
    abi = require_object(row, "policy_abi", context)
    for field in ("policy_name", "policy_version", "struct_ops", "object_sha256"):
        _ = require_string(abi, field, f"{context}.policy_abi")
    _ = require_bool(abi, "btf_required", f"{context}.policy_abi")
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
    validate_policy_abi(row, context)


def validate_file(path: Path) -> None:
    for index, row in enumerate(load_jsonl(path)):
        validate_sample(row, index)


def good_sample() -> JsonObject:
    digest = "a" * 64
    policy_abi: JsonObject = {"policy_name": "zigsched_minimal", "policy_version": "sched_ext_minimal_v1", "struct_ops": "zigsched_minimal_ops", "object_sha256": "unavailable", "btf_required": True}
    return {
        "schema": SAMPLE_SCHEMA,
        "sequence": 0,
        "state": {"status": "present", "value": "enabled"},
        "ops": {"status": "present", "value": "zigsched_minimal"},
        "enable_seq": {"status": "present", "value": "42"},
        "events": {"status": "present", "value": "nr_rejected: 0"},
        "events_hash": "ab12",
        "nr_rejected": {"status": "present", "value": "0"},
        "debug_dump": {"status": "missing", "value": ""},
        "root_ops": {"status": "present", "value": "zigsched_minimal"},
        "scheduler_events": {"status": "present", "value": "nr_rejected: 0"},
        "policy_counters": {"nr_rejected": 0, "dispatch_failed": 0, "fallback": 0, "fatal": 0},
        "sample_loss": {"lost_samples": 0, "backpressure_dropped": 0},
        "policy_abi": policy_abi,
        "cgroup_membership_digest": digest,
        "cgroup_membership_status": {"status": "present", "value": "present"},
        "workload": {"status": "present", "value": "alive"},
        "workload_alive": True,
        "private_command_lines_sampled": False,
    }


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
