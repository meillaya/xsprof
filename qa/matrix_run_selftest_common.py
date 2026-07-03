#!/usr/bin/env python3
"""Shared self-test I/O and mutation helpers for matrix-run checks."""
from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

from qa.matrix_run_json import file_sha256, json_loader, obj, reject_constant, require
from qa.matrix_run_manifest_validate import validate_manifest
from qa.matrix_run_model import (
    REQUIRED_FIXTURES,
    VM_MARKER,
    JsonObject,
    JsonValue,
    MatrixRunContractError,
)



@dataclass(frozen=True, slots=True)
class ManifestSelfTestContext:
    good: JsonObject
    name: str
    run_root: Path
    manifest_path: Path
    manifest: JsonObject
    rows: list[JsonValue]
    row: JsonObject
    artifact_path: Path

def write_json(path: Path, value: JsonObject) -> None:
    _ = path.write_text(json.dumps(value, sort_keys=True))

def write_json_digest(path: Path, value: JsonObject) -> str:
    write_json(path, value)
    return file_sha256(path)

def without_field(row: JsonObject, field: str) -> JsonObject:
    copy = dict(row)
    del copy[field]
    return copy

def invalid_self_test_rows(good: JsonObject) -> dict[str, JsonObject | str]:
    host_mutation = dict(good)
    host_mutation["host_mutation"] = True
    release_eligible = dict(good)
    release_eligible["release_eligible"] = True
    invalid_outcome = dict(good)
    invalid_outcome["outcome"] = "SUCCESS"
    stale_git = dict(good)
    stale_git["git"] = {"expected_sha": "302cead", "actual_sha": "deadbee", "status": "stale", "dirty": False}
    dirty_git = dict(good)
    dirty_git["git"] = {"expected_sha": "302cead", "actual_sha": "302cead", "status": "current", "dirty": True}
    missing_marker = dict(good)
    missing_marker["vm_marker"] = {"required": True, "present": False, "path": VM_MARKER, "checked_by": "self-test"}
    absolute_path = dict(good)
    absolute_path["runtime_sample_path"] = "/tmp/runtime-sample.jsonl"
    traversal_path = dict(good)
    traversal_path["incident_path"] = "evidence/../incident.json"
    privacy_failed = dict(good)
    privacy_failed["privacy_scan"] = {"status": "PASS", "private_fields_found": True, "report_path": "evidence/lab/privacy.json"}
    skip_without_cleanup = dict(good)
    skip_without_cleanup["outcome"] = "SKIP"
    skip_without_cleanup["supported_tuple_status"] = "unsupported"
    refuse_without_cleanup = dict(good)
    refuse_without_cleanup["outcome"] = "REFUSE"
    refuse_without_cleanup["evidence_mode"] = "host-refusal-only"
    refuse_without_cleanup["vm_marker"] = {"required": False, "present": False, "path": VM_MARKER, "checked_by": "self-test"}
    extra_property = dict(good)
    extra_property["unexpected_field_not_in_schema"] = "must be rejected"
    missing_sched_state = clone_object(good)
    del obj(missing_sched_state["pre_scheduler_state"], "self-test missing pre_scheduler_state")["sched_ext"]
    stale_enable_seq = clone_object(good)
    obj(stale_enable_seq["pre_scheduler_state"], "self-test stale pre_scheduler_state")["enable_seq"] = "42"
    obj(stale_enable_seq["post_scheduler_state"], "self-test stale post_scheduler_state")["enable_seq"] = "41"
    private_debug_dump = clone_object(good)
    obj(private_debug_dump["post_scheduler_state"], "self-test private post_scheduler_state")["ops"] = "/sys/kernel/debug/sched_ext/root"
    return {
        "host-mutation-true.json": host_mutation,
        "release-eligible-true.json": release_eligible,
        "invalid-outcome.json": invalid_outcome,
        "stale-git.json": stale_git,
        "dirty-git.json": dirty_git,
        "missing-vm-marker.json": missing_marker,
        "unsafe-absolute-path.json": absolute_path,
        "unsafe-traversal-path.json": traversal_path,
        "missing-rollback-proof.json": without_field(good, "rollback_proof_path"),
        "missing-cleanup-proof.json": without_field(good, "cleanup_proof_path"),
        "missing-cleanup-proof-on-skip.json": without_field(skip_without_cleanup, "cleanup_proof_path"),
        "missing-cleanup-proof-on-refuse.json": without_field(refuse_without_cleanup, "cleanup_proof_path"),
        "missing-host-refusal-proof.json": without_field(good, "host_refusal_proof_path"),
        "privacy-failed.json": privacy_failed,
        "unsupported-bpf-abi-version.json": dict(good, bpf_abi_version="zigsched-bpf-abi-v3"),
        "malformed.json": '{ "schema": "zig-scheduler/matrix-run/v1",',
        "extra-property.json": extra_property,
        "missing-sched-ext-state.json": missing_sched_state,
        "stale-enable-seq.json": stale_enable_seq,
        "private-debug-dump.json": private_debug_dump,
    }

def write_self_test_pack(fixtures: Path, invalid: Path, good: JsonObject) -> None:
    for name in REQUIRED_FIXTURES:
        write_json(fixtures / name, good)
    for name, row in invalid_self_test_rows(good).items():
        if isinstance(row, str):
            _ = (invalid / name).write_text(row)
        else:
            write_json(invalid / name, row)

def clone_object(value: JsonObject) -> JsonObject:
    return obj(json_loader.loads(json.dumps(value), parse_constant=reject_constant), "cloned JSON object")

def assert_invalid_manifest(manifest_path: Path, name: str, expected_error: str | None = None) -> None:
    try:
        _ = validate_manifest(manifest_path)
    except MatrixRunContractError as exc:
        if expected_error is not None:
            require(expected_error in str(exc), f"self-test {name} failed on wrong rule: expected {expected_error!r}, got {exc}")
        print(f"PASS self-test rejects malformed manifest {name}: {exc}")
        return
    raise MatrixRunContractError(f"self-test failed to reject malformed manifest: {name}")
