from __future__ import annotations

import json
import shutil
from pathlib import Path
from typing import Final

from qa.live_lab_evidence_check import self_test as live_evidence_self_test
from qa.runtime_sample_common import JsonObject, JsonValue, RuntimeSampleError, json_loader, require_object
from qa.runtime_sample_core import good_sample, validate_alert_order, validate_file
from qa.runtime_sample_policy_abi import SEMANTICS, good_policy_abi

SELF_TEST_ROOT: Final = Path("evidence/lab/runtime-sample-check-self-test")
PUBLIC_SCHEMA_PATH: Final = Path("schemas/control/runtime-sample.v1.schema.json")
ENRICHED_FIELDS: Final[tuple[str, ...]] = ("sched_ext_phase", "task_ext_enabled", "teardown_state", "rollback_state", "cgroup_semantic_labels")
PRIVATE_FIELDS: Final[tuple[str, ...]] = ("command_line", "cmdline", "argv", "env", "environment", "secret", "api_key")


def reject(path: Path, label: str) -> None:
    try:
        validate_file(path)
    except RuntimeSampleError as exc:
        print(f"PASS reject {label}: {exc}")
        return
    raise RuntimeSampleError(f"expected rejection did not occur: {label}")


def write_sample(path: Path, sample: JsonObject) -> Path:
    _ = path.write_text(json.dumps(sample, sort_keys=True) + "\n")
    return path


def reject_rows(rows: list[JsonObject], label: str) -> None:
    try:
        validate_alert_order(rows, label)
    except RuntimeSampleError as exc:
        print(f"PASS reject {label}: {exc}")
        return
    raise RuntimeSampleError(f"expected rejection did not occur: {label}")


def runtime_alert_rows(reason_first: bool, reason: str) -> list[JsonObject]:
    sample: JsonObject = {"event": "runtime_sample", "nr_rejected": "3" if reason == "runtime_nr_rejected_nonzero" else "0", "workload_alive": reason != "runtime_workload_dead"}
    incident: JsonObject = {"event": "incident", "reason": reason}
    return [incident, sample] if reason_first else [sample, incident]


def bad_weight_policy_abi() -> JsonObject:
    policy = good_policy_abi()
    semantics = dict(policy["cgroup_semantics"] if isinstance(policy["cgroup_semantics"], dict) else {})
    semantics["cpu.weight"] = "observed-only"
    policy["cgroup_semantics"] = semantics
    return policy



def sched_ext_state_sample(sequence: int, phase: str, state: str, ops: str, enable_seq: str, task_ext: str = "unavailable") -> JsonObject:
    sample = good_sample()
    sample["sequence"] = sequence
    sample["sched_ext_phase"] = phase
    sample["state"] = {"status": "present", "value": state}
    sample["ops"] = {"status": "present", "value": ops}
    sample["enable_seq"] = {"status": "present", "value": enable_seq}
    sample["task_ext_enabled"] = {"status": "present", "value": task_ext} if task_ext in {"true", "false"} else {"status": "unknown", "value": task_ext}
    if phase in {"after_rollback", "after_scheduler_exit", "after_watchdog_disable", "after_forced_disable"}:
        sample["teardown_state"] = {"status": "present", "value": phase}
        sample["rollback_state"] = {"status": "present", "value": "scheduler_disabled"}
    return sample


def write_samples(path: Path, samples: list[JsonObject]) -> Path:
    _ = path.write_text("".join(json.dumps(sample, sort_keys=True) + "\n" for sample in samples))
    return path


def validate_public_schema_lockstep() -> None:
    schema: JsonValue = json_loader.loads(PUBLIC_SCHEMA_PATH.read_text())
    if not isinstance(schema, dict):
        raise RuntimeSampleError("public runtime sample schema must be an object")
    if schema.get("additionalProperties") is not False:
        raise RuntimeSampleError("public runtime sample schema must reject additional properties")
    properties: JsonValue = schema.get("properties")
    if not isinstance(properties, dict):
        raise RuntimeSampleError("public runtime sample schema must declare properties")
    sample_fields = set(good_sample())
    missing_sample_fields = sorted(sample_fields - set(properties))
    if missing_sample_fields:
        raise RuntimeSampleError(f"public schema missing sample fields: {missing_sample_fields}")
    missing_enriched_fields = sorted(field for field in ENRICHED_FIELDS if field not in properties)
    if missing_enriched_fields:
        raise RuntimeSampleError(f"public schema missing enriched fields: {missing_enriched_fields}")
    forbidden: JsonValue = schema.get("forbiddenProperties")
    if not isinstance(forbidden, list) or any(field not in forbidden for field in PRIVATE_FIELDS):
        raise RuntimeSampleError("public schema must document private field rejection")


def self_test() -> None:
    validate_public_schema_lockstep()
    shutil.rmtree(SELF_TEST_ROOT, ignore_errors=True)
    SELF_TEST_ROOT.mkdir(parents=True)
    _ = validate_file(write_sample(SELF_TEST_ROOT / "good.jsonl", good_sample()))
    _ = validate_file(write_samples(SELF_TEST_ROOT / "sched-ext-state-normal-rollback.jsonl", [
        sched_ext_state_sample(0, "before_attach", "disabled", "none", "41"),
        sched_ext_state_sample(1, "during_attach", "enabled", "zigsched_minimal", "42", "true"),
        sched_ext_state_sample(2, "after_attach", "enabled", "zigsched_minimal", "42", "true"),
        sched_ext_state_sample(3, "after_rollback", "disabled", "none", "42"),
        sched_ext_state_sample(4, "after_scheduler_exit", "disabled", "none", "42"),
        sched_ext_state_sample(5, "after_watchdog_disable", "disabled", "none", "43"),
        sched_ext_state_sample(6, "after_forced_disable", "unknown", "unknown", "43"),
    ]))

    accepted = good_sample()
    accepted["policy_abi"] = good_policy_abi("d" * 64)
    _ = validate_file(write_sample(SELF_TEST_ROOT / "abi-v3-cgroup-policy.jsonl", accepted))
    unavailable = good_sample()
    unavailable["task_ext_enabled"] = {"status": "unknown", "value": "unavailable"}
    _ = validate_file(write_sample(SELF_TEST_ROOT / "task-ext-unavailable.jsonl", unavailable))
    compound_key = good_sample()
    task_counts = require_object(compound_key, "task_counts", "runtime sample self-test")
    by_class = require_object(task_counts, "by_class", "runtime sample self-test.task_counts")
    by_class["githubAccessToken"] = 1
    reject(write_sample(SELF_TEST_ROOT / "compound-privacy-key.jsonl", compound_key), "compound privacy key")
    case_variant = good_sample()
    events = require_object(case_variant, "events", "runtime sample self-test")
    events["value"] = "Password=secret"
    reject(write_sample(SELF_TEST_ROOT / "case-variant-private-text.jsonl", case_variant), "case-variant private text")
    bad_policy_cases: tuple[tuple[str, JsonObject, str], ...] = (
        ("missing-abi-semantics.jsonl", {"policy_name": "zigsched_minimal", "policy_version": "sched_ext_cgroup_abi_v3", "struct_ops": "zigsched_minimal_ops", "object_sha256": "unavailable", "btf_required": True, "abi_version": 3}, "missing ABI-v3 cgroup semantics"),
        ("mismatched-policy-version.jsonl", {**good_policy_abi(), "policy_version": "sched_ext_minimal_v1"}, "mismatched policy version"),
        ("bad-weight-semantics.jsonl", bad_weight_policy_abi(), "bad cpu.weight semantics"),
        ("host-mutation-policy.jsonl", {**good_policy_abi(), "host_mutation": True}, "policy ABI host mutation claim"),
        ("production-policy-claim.jsonl", {**good_policy_abi(), "production_claim": True}, "policy ABI production claim"),
        ("release-policy-claim.jsonl", {**good_policy_abi(), "release_eligible": True}, "policy ABI release claim"),
    )
    for name, policy_abi, label in bad_policy_cases:
        sample = good_sample()
        sample["policy_abi"] = policy_abi
        reject(write_sample(SELF_TEST_ROOT / name, sample), label)
    for field, label in (("private_command_lines_sampled", "missing privacy flag"), ("events_hash", "missing events hash"), ("policy_abi", "missing policy ABI")):
        sample = good_sample()
        del sample[field]
        reject(write_sample(SELF_TEST_ROOT / f"{field}-missing.jsonl", sample), label)
    overrides: tuple[tuple[str, str, JsonValue, str], ...] = (
        ("schema", "unsupported-schema.jsonl", "zig-scheduler/runtime-sample/v2", "unsupported schema drift"),
        ("unexpected_future_field", "unknown-field-schema-drift.jsonl", "surprise", "unsupported field schema drift"),
        ("production_claim", "top-level-production-claim.jsonl", True, "top-level production claim"),
        ("release_eligible", "top-level-release-claim.jsonl", True, "top-level release claim"),
        ("command_line", "raw-command.jsonl", "/usr/bin/demo --token secret", "raw command line"),
        ("private_command_lines_sampled", "private-flag.jsonl", True, "private command lines flag"),
        ("enable_seq", "malformed-sched-ext-fact.jsonl", {"status": "present", "value": "not-a-number"}, "malformed sched_ext fact"),
        ("nr_rejected", "negative-nr-rejected.jsonl", {"status": "present", "value": "-1"}, "negative sched_ext counter fact"),
        ("debug_dump", "raw-debug-path.jsonl", {"status": "present", "value": "/sys/kernel/debug/sched_ext/dump"}, "raw debug dump path"),
        ("cgroup_membership_digest", "invalid-cgroup-digest.jsonl", "not-a-sha256", "invalid cgroup digest"),
        ("cgroup_membership_digest", "zero-cgroup-digest.jsonl", "0" * 64, "zero cgroup digest"),
        ("scheduler_counters", "negative-counter.jsonl", {"context_switches": -1, "wakeups": 0, "migrations": 0}, "negative counter"),
        ("sched_ext_observation", "raw-sched-ext-dump.jsonl", {"dump": {"status": "present", "value": "task /proc/1/cmdline"}, "tracepoints": {"sched_switch": 1}}, "unredacted debug dump"),
        ("sched_ext_observation", "quote-injection-dump.jsonl", {"dump": {"status": "present", "value": "sha256:" + ("a" * 64) + ";bytes:128\",\"host_mutation\":true,\"x\":\""}, "tracepoints": {"sched_switch": 1}}, "quote injection digest summary"),
        ("sched_ext_observation", "control-injection-dump.jsonl", {"dump": {"status": "present", "value": "sha256:" + ("a" * 64) + ";bytes:128\nx"}, "tracepoints": {"sched_switch": 1}}, "control injection digest summary"),
        ("cgroup_semantic_labels", "bad-cgroup-semantic-labels.jsonl", {"cpu.weight": "honored"}, "bad cgroup semantic labels"),
        ("task_ext_enabled", "bad-task-ext-enabled.jsonl", {"status": "present", "value": "maybe"}, "bad task ext.enabled evidence"),
        ("task_ext_enabled", "surrogate-task-ext-enabled.jsonl", {"status": "present", "value": "unknown"}, "surrogate task ext.enabled evidence"),
        ("cgroup_semantic_labels", "wrong-cgroup-semantic-value.jsonl", {**SEMANTICS, "cpu.max": "observed-only"}, "wrong cgroup semantic value"),
    )
    for field, name, value, label in overrides:
        sample = good_sample()
        sample[field] = value
        reject(write_sample(SELF_TEST_ROOT / name, sample), label)
    reject(write_samples(SELF_TEST_ROOT / "stale-enable-seq.jsonl", [
        sched_ext_state_sample(0, "during_attach", "enabled", "zigsched_minimal", "42", "true"),
        sched_ext_state_sample(1, "after_rollback", "disabled", "none", "41"),
    ]), "stale enable_seq semantics")
    reject(write_samples(SELF_TEST_ROOT / "after-rollback-live-ops.jsonl", [
        sched_ext_state_sample(0, "during_attach", "enabled", "zigsched_minimal", "42", "true"),
        sched_ext_state_sample(1, "after_rollback", "disabled", "zigsched_minimal", "42"),
    ]), "after rollback live root ops")
    reject(write_samples(SELF_TEST_ROOT / "before-attach-enabled.jsonl", [
        sched_ext_state_sample(0, "before_attach", "enabled", "zigsched_minimal", "42", "true"),
    ]), "before attach enabled state")
    reject_rows(runtime_alert_rows(True, "runtime_nr_rejected_nonzero"), "nr_rejected incident ordering")
    reject_rows(runtime_alert_rows(True, "runtime_workload_dead"), "workload dead incident ordering")
    validate_alert_order(runtime_alert_rows(False, "runtime_nr_rejected_nonzero"), "nr_rejected-good-order")
    validate_alert_order(runtime_alert_rows(False, "runtime_workload_dead"), "workload-dead-good-order")
    shutil.rmtree(SELF_TEST_ROOT)
    live_evidence_self_test()
    print("PASS runtime sample self-test: privacy-safe samples accepted and unsafe samples rejected")
