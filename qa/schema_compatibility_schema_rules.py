from __future__ import annotations

from collections.abc import Sequence
from pathlib import Path
from typing import Final, TypeAlias

from qa.frontend_contract_pack_types import JsonObject, JsonValue, parse_json_object
from qa.schema_compatibility_runner_cleanliness_rules import (
    RUNNER_CLEANLINESS_ENUM_RULES,
    RUNNER_CLEANLINESS_PUBLIC_SCHEMA_RULES,
    RUNNER_CLEANLINESS_REQUIRED_RULES,
)

DRAFT_2020_12: Final = "https://json-schema.org/draft/2020-12/schema"
PublicSchemaRule: TypeAlias = tuple[str, str, tuple[str, ...]]
EnumRule: TypeAlias = tuple[str, tuple[str, ...], tuple[str, ...]]
RequiredRule: TypeAlias = tuple[str, tuple[str, ...], tuple[str, ...]]


class SchemaCompatibilityError(Exception):
    """Raised when public JSON schemas violate the v1 compatibility policy."""


PUBLIC_SCHEMA_RULES: Final[tuple[PublicSchemaRule, ...]] = (
    ("daemon-event.v1.schema.json", "zig-scheduler/daemon-event/v1", ("schema", "event", "status", "host_mutation")),
    ("operator-action.v1.schema.json", "zig-scheduler/operator-action/v1", ("action",)),
    (
        "runtime-sample.v1.schema.json",
        "zig-scheduler/runtime-sample/v1",
        (
            "schema", "sequence", "state", "ops", "enable_seq", "events", "events_hash", "nr_rejected",
            "debug_dump", "policy_abi", "cgroup_membership_digest", "workload_alive", "private_command_lines_sampled",
        ),
    ),
    (
        "matrix-run.v1.schema.json",
        "zig-scheduler/matrix-run/v1",
        (
            "schema", "matrix_run_id", "scenario_id", "outcome", "evidence_mode", "kernel_tuple",
            "supported_tuple_status", "vm_marker", "bpf_abi_version", "policy", "workload", "action_id",
            "audit_id", "rollback_id", "pre_scheduler_state", "post_scheduler_state", "pre_cgroup_state",
            "post_cgroup_state", "runtime_sample_path", "daemon_event_path", "incident_path", "rollback_proof_path",
            "cleanup_proof_path", "host_refusal_proof_path", "privacy_scan", "git", "release_eligible", "host_mutation",
        ),
    ),
    (
        "benchmark-output.v1.schema.json",
        "zig-scheduler/benchmark-output/v1",
        (
            "schema", "status", "tool", "command_family", "record_only", "output_path", "output_sha256", "vm_evidence",
            "parser_provenance", "metrics", "units", "sample_count", "run_count", "host_mutation", "release_eligible",
            "production_capacity_claim", "hard_thresholds_enforced", "threshold_status", "privacy_sanitized",
        ),
    ),
    (
        "evidence-manifest.v1.schema.json",
        "zig-scheduler/evidence-manifest/v1",
        (
            "schema", "audit_id", "rollback_id", "vm_marker", "supported_tuple", "bpf_metadata_or_skip",
            "matrix_manifest", "daemon_events", "artifacts", "benchmark_provenance", "privacy_scan", "outcome",
            "attestation", "required_sources", "host_mutation", "release_eligible", "production_capacity_claim",
        ),
    ),
    (
        "runner-substrate-proof.v1.schema.json",
        "zig-scheduler/runner-substrate-proof/v1",
        (
            "schema", "proof_outcome", "runner", "protected_environment", "protected_review", "qemu", "dev_kvm",
            "accel_mode", "kernel_tuple", "bpf_metadata", "attestation", "unavailable_reasons",
            "host_mutation", "release_eligible", "production_capacity_claim",
        ),
    ),
    (
        "protected-environment-review.v1.schema.json",
        "zig-scheduler/protected-environment-review/v1",
        (
            "schema", "run_id", "run_url", "head_sha", "environment_name", "environment_id",
            "reviewer_status", "reviewer_identity", "reviewer_id", "comment", "review_history_api_url",
            "collected_at", "host_mutation", "release_eligible", "production_capacity_claim",
        ),
    ),
) + RUNNER_CLEANLINESS_PUBLIC_SCHEMA_RULES

ENUM_RULES: Final[tuple[EnumRule, ...]] = (
    ("daemon-event.v1.schema.json", ("properties", "event"), ("boot", "marker", "verifier", "attach", "state_changed", "stage_started", "lab_run_active", "stage_finished", "journal_record", "microvm_boot", "vm_marker", "bpf_register", "runtime_sample", "rollback", "rollback_completed", "cleanup", "validation", "incident", "refusal")),
    ("operator-action.v1.schema.json", ("properties", "action"), ("preflight", "run_lab_host_safe", "run_lab_vm", "run_lab_microvm_live", "verifier_only", "partial_attach", "observe", "stop", "rollback", "stop_lab_run", "rollback_lab_run", "incident_drill")),
    ("runtime-sample.v1.schema.json", ("properties", "observation_source"), ("vm_guest_sched_ext", "vm_serial_sched_ext", "vm_fixture_sched_ext")),
    ("matrix-run.v1.schema.json", ("properties", "outcome"), ("PASS", "SKIP", "REFUSE", "INCIDENT", "FAIL")),
    ("matrix-run.v1.schema.json", ("properties", "evidence_mode"), ("vm-live", "host-refusal-only", "fixture")),
    ("matrix-run.v1.schema.json", ("properties", "supported_tuple_status"), ("supported", "unsupported", "unknown")),
    ("runner-substrate-proof.v1.schema.json", ("properties", "proof_outcome"), ("PASS", "SKIP", "REFUSE")),
    ("benchmark-output.v1.schema.json", ("properties", "status"), ("RECORDED", "UNSUPPORTED_DEFERRED")),
    ("benchmark-output.v1.schema.json", ("properties", "tool"), ("cyclictest", "fio", "perf", "rtla", "stress-ng")),
    ("benchmark-output.v1.schema.json", ("properties", "command_family"), ("cyclictest", "fio", "perf_bench_sched_messaging", "rtla", "perf_sched", "stress_ng")),
) + RUNNER_CLEANLINESS_ENUM_RULES

FROZEN_REQUIRED_RULES: Final[tuple[RequiredRule, ...]] = (
    ("benchmark-output.v1.schema.json", ("required",), ("schema", "status", "tool", "command_family", "record_only", "output_path", "output_sha256", "vm_evidence", "parser_provenance", "metrics", "units", "sample_count", "run_count", "host_mutation", "release_eligible", "production_capacity_claim", "hard_thresholds_enforced", "threshold_status", "privacy_sanitized")),
    ("benchmark-output.v1.schema.json", ("properties", "parser_provenance", "required"), ("parser", "parser_version", "parser_status")),
    ("daemon-event.v1.schema.json", ("required",), ("schema", "event", "status", "host_mutation")),
    ("evidence-manifest.v1.schema.json", ("required",), ("schema", "outcome", "audit_id", "rollback_id", "vm_marker", "supported_tuple", "bpf_metadata_or_skip", "matrix_manifest", "daemon_events", "runner_substrate", "runner_cleanliness", "artifacts", "benchmark_provenance", "privacy_scan", "attestation", "required_sources", "host_mutation", "release_eligible", "production_capacity_claim")),
    ("evidence-manifest.v1.schema.json", ("properties", "vm_marker", "required"), ("path", "present", "checked_by")),
    ("evidence-manifest.v1.schema.json", ("properties", "benchmark_provenance", "oneOf", "1", "required"), ("status", "reason", "applies_to_outcomes")),
    ("evidence-manifest.v1.schema.json", ("properties", "privacy_scan", "required"), ("status", "private_fields_found", "artifact_paths")),
    ("evidence-manifest.v1.schema.json", ("properties", "attestation", "required"), ("status", "workflow_uses", "verify_command", "retention_days")),
    ("evidence-manifest.v1.schema.json", ("$defs", "artifactRef", "required"), ("path", "sha256", "schema_role")),
    ("lab-evidence.v1.schema.json", ("required",), ("schema", "evidence_mode", "vm_marker_present", "vm_marker_path", "target_allowlisted", "audit_id", "rollback_id", "host_mutation", "mutation_evidence")),
    ("lab-evidence.v1.schema.json", ("properties", "mutation_evidence", "required"), ("cgroup.weight", "cpu.max", "uclamp", "topology.offline_cpu")),
    ("lab-evidence.v1.schema.json", ("$defs", "mutation", "required"), ("target", "pre_state", "post_state", "rollback_proof", "cleanup_proof")),
    ("matrix-run.v1.schema.json", ("required",), ("schema", "matrix_run_id", "scenario_id", "outcome", "evidence_mode", "kernel_tuple", "supported_tuple_status", "vm_marker", "bpf_abi_version", "policy", "workload", "action_id", "audit_id", "rollback_id", "pre_scheduler_state", "post_scheduler_state", "pre_cgroup_state", "post_cgroup_state", "runtime_sample_path", "daemon_event_path", "incident_path", "rollback_proof_path", "cleanup_proof_path", "host_refusal_proof_path", "privacy_scan", "git", "release_eligible", "host_mutation")),
    ("matrix-run.v1.schema.json", ("properties", "kernel_tuple", "required"), ("kernel_release", "arch", "btf", "kvm", "sched_ext")),
    ("matrix-run.v1.schema.json", ("properties", "vm_marker", "required"), ("required", "present", "path", "checked_by")),
    ("matrix-run.v1.schema.json", ("properties", "policy", "required"), ("name", "object_path", "object_sha256", "source_path", "source_sha256")),
    ("matrix-run.v1.schema.json", ("properties", "workload", "required"), ("name", "spec_path", "spec_sha256")),
    ("matrix-run.v1.schema.json", ("properties", "post_scheduler_state", "required"), ("sched_ext", "ops")),
    ("matrix-run.v1.schema.json", ("properties", "pre_scheduler_state", "required"), ("sched_ext", "ops")),
    ("matrix-run.v1.schema.json", ("properties", "privacy_scan", "required"), ("status", "private_fields_found", "report_path")),
    ("matrix-run.v1.schema.json", ("properties", "git", "required"), ("expected_sha", "actual_sha", "status", "dirty")),
    ("operator-action.v1.schema.json", ("required",), ("action",)),
    ("operator-action.v1.schema.json", ("allOf", "0", "if", "required"), ("action",)),
    ("operator-action.v1.schema.json", ("allOf", "0", "then", "required"), ("action_id", "target_id", "audit_id", "rollback_id")),
    ("operator-action.v1.schema.json", ("allOf", "1", "if", "required"), ("action",)),
    ("operator-action.v1.schema.json", ("allOf", "1", "then", "required"), ("audit_id", "rollback_id")),
    ("perf-calibration-evidence.v1.schema.json", ("required",), ("schema", "status", "evidence_mode", "source_bundle", "runtime_samples", "sample_count", "threshold_status", "hard_thresholds_enforced", "production_capacity_claim", "release_eligible", "host_mutation")),
    ("protected-environment-review.v1.schema.json", ("required",), ("schema", "run_id", "run_url", "head_sha", "environment_name", "environment_id", "reviewer_status", "reviewer_identity", "reviewer_id", "comment", "review_history_api_url", "collected_at", "host_mutation", "release_eligible", "production_capacity_claim")),
    ("rollback-result.v1.schema.json", ("required",), ("schema", "rollback_id", "result", "idempotent", "host_mutation")),
    ("runner-substrate-proof.v1.schema.json", ("required",), ("schema", "proof_outcome", "runner", "protected_environment", "protected_review", "qemu", "dev_kvm", "accel_mode", "kernel_tuple", "bpf_metadata", "attestation", "unavailable_reasons", "host_mutation", "release_eligible", "production_capacity_claim")),
    ("runner-substrate-proof.v1.schema.json", ("properties", "runner", "required"), ("class", "labels", "os", "arch")),
    ("runner-substrate-proof.v1.schema.json", ("properties", "protected_environment", "required"), ("name", "protected", "required_reviewers", "reviewer_status", "run_url")),
    ("runner-substrate-proof.v1.schema.json", ("properties", "kernel_tuple", "required"), ("supported_tuple", "release", "arch", "config_sha256", "btf_available", "sched_ext_available")),
    ("runner-substrate-proof.v1.schema.json", ("properties", "attestation", "required"), ("capability", "status", "workflow_uses", "verify_command")),
    ("runner-substrate-proof.v1.schema.json", ("$defs", "artifactRef", "required"), ("path", "sha256", "schema_role")),
    ("runner-substrate-proof.v1.schema.json", ("$defs", "protectedReviewRef", "required"), ("path", "sha256", "schema_role")),
    ("runner-substrate-proof.v1.schema.json", ("$defs", "statusPath", "required"), ("path", "status")),
    ("runner-substrate-proof.v1.schema.json", ("allOf", "0", "if", "required"), ("proof_outcome",)),
    ("runner-substrate-proof.v1.schema.json", ("allOf", "0", "then", "properties", "protected_environment", "required"), ("reviewer_identity",)),
    ("runner-substrate-proof.v1.schema.json", ("allOf", "0", "then", "properties", "qemu", "required"), ("version",)),
    ("runner-substrate-proof.v1.schema.json", ("allOf", "0", "then", "properties", "runner", "required"), ("group", "name")),
    ("runtime-sample.v1.schema.json", ("required",), ("schema", "sequence", "state", "ops", "enable_seq", "events", "events_hash", "nr_rejected", "debug_dump", "policy_abi", "cgroup_membership_digest", "workload_alive", "private_command_lines_sampled")),
    ("runtime-sample.v1.schema.json", ("$defs", "fact", "required"), ("status", "value")),
    ("runtime-sample.v1.schema.json", ("$defs", "digest_fact", "required"), ("status", "value")),
    ("runtime-sample.v1.schema.json", ("$defs", "policy_counters", "oneOf", "0", "required"), ("nr_rejected", "dispatch_failed", "fallback", "fatal")),
    ("runtime-sample.v1.schema.json", ("$defs", "sample_loss", "oneOf", "0", "required"), ("lost_samples", "backpressure_dropped")),
    ("runtime-sample.v1.schema.json", ("$defs", "policy_abi", "required"), ("policy_name", "policy_version", "struct_ops", "object_sha256", "btf_required")),
    ("runtime-sample.v1.schema.json", ("$defs", "cgroup_policy_semantics", "required"), ("cpu.weight", "cgroup.lifecycle", "cgroup.move", "cpuset.cpus", "cpuset.cpus.effective", "cpu.pressure", "cpu.max", "uclamp", "cgroup_set_idle")),
    ("runtime-sample.v1.schema.json", ("$defs", "dsq_depth", "oneOf", "0", "required"), ("global", "local", "shared")),
    ("runtime-sample.v1.schema.json", ("$defs", "queue_latency", "oneOf", "0", "required"), ("p50_us", "p95_us", "p99_us", "max_us")),
    ("runtime-sample.v1.schema.json", ("$defs", "fairness", "oneOf", "0", "required"), ("state", "starved_tasks", "max_wait_us")),
    ("runtime-sample.v1.schema.json", ("$defs", "task_counts", "required"), ("by_cgroup_digest", "by_class")),
    ("runtime-sample.v1.schema.json", ("$defs", "scheduler_counters", "oneOf", "0", "required"), ("context_switches", "wakeups", "migrations")),
    ("runtime-sample.v1.schema.json", ("$defs", "sched_ext_observation", "required"), ("dump", "tracepoints")),
    ("runtime-sample.v1.schema.json", ("$defs", "benchmark_histogram_ref", "required"), ("record_path", "record_sha256", "histogram_id", "record_only")),
    ("runtime-sample.v1.schema.json", ("$defs", "unavailable_fact", "required"), ("status", "value")),
    ("runtime-sample.v1.schema.json", ("$defs", "task_ext_enabled_fact", "required"), ("status", "value")),
) + RUNNER_CLEANLINESS_REQUIRED_RULES


def load_schema(path: Path) -> JsonObject:
    try:
        return parse_json_object(path.read_text(), str(path))
    except FileNotFoundError as exc:
        raise SchemaCompatibilityError(f"missing public schema: {path}") from exc


def string_list(value: JsonValue | None, context: str) -> tuple[str, ...]:
    if not isinstance(value, list):
        raise SchemaCompatibilityError(f"{context} must be a string list")
    out: list[str] = []
    for item in value:
        if not isinstance(item, str):
            raise SchemaCompatibilityError(f"{context} contains a non-string value")
        out.append(item)
    return tuple(out)


def nested_object(schema: JsonObject, path: Sequence[str], context: str) -> JsonObject:
    current = schema
    for name in path:
        value = current.get(name)
        if not isinstance(value, dict):
            raise SchemaCompatibilityError(f"{context}.{'.'.join(path)} missing")
        current = value
    return current


def require_string_field(schema: JsonObject, field: str, context: str) -> str:
    value = schema.get(field)
    if not isinstance(value, str) or value == "":
        raise SchemaCompatibilityError(f"{context}.{field} missing")
    return value


def schema_const(schema: JsonObject, context: str) -> str:
    schema_prop = schema_property(schema, context)
    value = schema_prop.get("const")
    if not isinstance(value, str) or value == "":
        raise SchemaCompatibilityError(f"{context}.properties.schema.const missing")
    return value


def schema_property(schema: JsonObject, context: str) -> JsonObject:
    props = schema.get("properties")
    if not isinstance(props, dict):
        raise SchemaCompatibilityError(f"{context}.properties missing")
    schema_prop = props.get("schema")
    if not isinstance(schema_prop, dict):
        raise SchemaCompatibilityError(f"{context}.properties.schema missing")
    return schema_prop


def validate_schema_identifier(schema: JsonObject, name: str) -> None:
    props = schema.get("properties")
    if not isinstance(props, dict) or "schema" not in props:
        return
    schema_prop = schema_property(schema, name)
    value = schema_prop.get("const")
    if isinstance(value, str) and value != "":
        return
    enum = schema_prop.get("enum")
    if isinstance(enum, list) and enum and all(isinstance(item, str) and item != "" for item in enum):
        return
    raise SchemaCompatibilityError(f"{name}.properties.schema const/enum missing")


def collect_required_paths(value: JsonValue, path: tuple[str, ...] = ()) -> tuple[tuple[tuple[str, ...], tuple[str, ...]], ...]:
    found: list[tuple[tuple[str, ...], tuple[str, ...]]] = []
    match value:  # noqa: MATCH_OK -- JsonValue cases are exhausted by the union definition.
        case dict():
            required = value.get("required")
            if isinstance(required, list):
                found.append((path + ("required",), string_list(required, ".".join(path + ("required",)))))
            for key, child in value.items():
                found.extend(collect_required_paths(child, path + (key,)))
        case list():
            for index, child in enumerate(value):
                found.extend(collect_required_paths(child, path + (str(index),)))
        case None | bool() | int() | float() | str():
            pass
    return tuple(found)


def expected_required_for(name: str) -> dict[tuple[str, ...], frozenset[str]]:
    return {path: frozenset(fields) for rule_name, path, fields in FROZEN_REQUIRED_RULES if rule_name == name}


def validate_required_freeze(name: str, schema: JsonObject) -> None:
    actual = {path: frozenset(fields) for path, fields in collect_required_paths(schema)}
    expected = expected_required_for(name)
    if actual != expected:
        changed = sorted(".".join(path) for path in actual.keys() ^ expected.keys())
        if changed:
            raise SchemaCompatibilityError(f"{name} required locations changed: {', '.join(changed)}")
        for path in sorted(actual):
            if actual[path] != expected[path]:
                raise SchemaCompatibilityError(f"{name}.{'.'.join(path)} required fields changed: {', '.join(sorted(actual[path]))}")


def validate_control_schema_metadata(schemas: Path, loaded: dict[str, JsonObject]) -> None:
    for path in sorted(schemas.glob("*.schema.json")):
        schema = loaded.setdefault(path.name, load_schema(path))
        if require_string_field(schema, "$schema", path.name) != DRAFT_2020_12:
            raise SchemaCompatibilityError(f"{path.name} uses unsupported JSON Schema draft")
        _ = require_string_field(schema, "$id", path.name)
        validate_schema_identifier(schema, path.name)
        validate_required_freeze(path.name, schema)


def validate_public_schemas(schemas: Path) -> None:
    loaded = {path.name: load_schema(path) for path in sorted(schemas.glob("*.schema.json"))}
    validate_control_schema_metadata(schemas, loaded)
    for name, expected_schema, _expected_required in PUBLIC_SCHEMA_RULES:
        schema = loaded.get(name)
        if schema is None:
            raise SchemaCompatibilityError(f"missing public schema: {schemas / name}")
        if schema_const(schema, name) != expected_schema:
            raise SchemaCompatibilityError(f"{name} schema const drifted")
    for name, path, expected in ENUM_RULES:
        schema = loaded.get(name)
        if schema is None:
            raise SchemaCompatibilityError(f"missing public schema: {schemas / name}")
        actual = string_list(nested_object(schema, path, name).get("enum"), f"{name}.{'.'.join(path)}.enum")
        if frozenset(actual) != frozenset(expected):
            raise SchemaCompatibilityError(f"{name}.{'.'.join(path)} enum changed")
