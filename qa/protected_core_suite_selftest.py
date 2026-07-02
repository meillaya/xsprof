#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
# ─── How to run ───
# python3 qa/protected_core_suite_check.py --self-test
"""Self-test fixtures for protected-core matrix suite checks."""
from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
import json
import shutil
from pathlib import Path
from typing import Final

from qa.matrix_run_contract_check import JsonObject, JsonValue, write_manifest_self_test_pack
from qa.runtime_sample_common import load_jsonl

SELF_ROOT: Final[Path] = Path("evidence/lab/matrix/protected-core-suite-self-test")


@dataclass(frozen=True, slots=True)
class SuiteSelfTest:
    """Validator functions and error classes used by suite self-tests."""

    load_json: Callable[[Path], JsonObject]
    manifest_rows: Callable[[JsonObject, str], list[JsonObject]]
    obj: Callable[[JsonValue | None, str], JsonObject]
    safe_path: Callable[[JsonValue | None, str], Path]
    validate_manifest: Callable[[Path], None]
    expected_errors: tuple[type[BaseException], ...]

    def expect_reject(self, path: Path, label: str) -> None:
        try:
            self.validate_manifest(path)
        except self.expected_errors as exc:
            print(f"PASS reject {label}: {exc}")
            return
        raise AssertionError(f"expected rejection did not occur: {label}")


def mark_self_test_row_vm_captured(checks: SuiteSelfTest, row_path: Path) -> None:
    row = checks.load_json(row_path)
    row["evidence_mode"] = "vm-live"
    row["vm_marker"] = {"required": True, "present": True, "path": "/run/zig-scheduler-vm-lab.marker", "checked_by": (row_path.parent / "vm-marker-proof.json").as_posix()}
    sample_path = checks.safe_path(row.get("runtime_sample_path"), f"{row_path}.runtime_sample_path")
    samples = load_jsonl(sample_path)
    for index, sample in enumerate(samples):
        sample["observation_source"] = "vm_serial_sched_ext"
        sample["sample_source_event"] = ("before", "register", "unregister")[index] if index < 3 else f"vm-sample-{index}"
    _ = sample_path.write_text("".join(json.dumps(sample, sort_keys=True) + "\n" for sample in samples))
    _ = row_path.write_text(json.dumps(row, indent=2, sort_keys=True) + "\n")


def write_protected_manifest(checks: SuiteSelfTest, root: Path) -> Path:
    good = checks.load_json(Path("fixtures/matrix-run/pass.json"))
    scenarios = ("live-backend", "workload-cpu-saturation", "workload-cgroup-weight-quota", "workload-interactive-latency")
    row_refs: list[JsonValue] = []
    for scenario in scenarios:
        manifest_path = write_manifest_self_test_pack(root, good, scenario)
        manifest = checks.load_json(manifest_path)
        rows = checks.manifest_rows(manifest, manifest_path.as_posix())
        first = dict(rows[0])
        mark_self_test_row_vm_captured(checks, checks.safe_path(first.get("artifact_path"), f"{manifest_path}.rows[0].artifact_path"))
        row_refs.append(first)
    manifest = checks.load_json(root / "manifest.json")
    manifest["rows"] = row_refs
    manifest["row_count"] = len(row_refs)
    _ = (root / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    return root / "manifest.json"


def assert_shared_runtime_rejected(checks: SuiteSelfTest, root: Path) -> None:
    shared = write_protected_manifest(checks, root / "shared-artifact")
    manifest = checks.load_json(shared)
    rows = checks.manifest_rows(manifest, shared.as_posix())
    first = checks.obj(rows[0], "shared-artifact first row")
    second = checks.obj(rows[1], "shared-artifact second row")
    second_path = checks.safe_path(second.get("artifact_path"), "shared artifact second path")
    second_row = checks.load_json(second_path)
    first_row = checks.load_json(checks.safe_path(first.get("artifact_path"), "shared artifact first path"))
    second_row["runtime_sample_path"] = first_row["runtime_sample_path"]
    _ = second_path.write_text(json.dumps(second_row, indent=2, sort_keys=True) + "\n")
    checks.expect_reject(shared, "shared row runtime sample")


def assert_harness_runtime_rejected(checks: SuiteSelfTest, root: Path) -> None:
    harness_runtime = write_protected_manifest(checks, root / "harness-runtime")
    harness_manifest = checks.load_json(harness_runtime)
    harness_rows = checks.manifest_rows(harness_manifest, harness_runtime.as_posix())
    harness_first = checks.obj(harness_rows[0], "harness runtime first row")
    harness_artifact = checks.safe_path(harness_first.get("artifact_path"), "harness runtime artifact")
    harness_row = checks.load_json(harness_artifact)
    harness_sample_path = checks.safe_path(harness_row.get("runtime_sample_path"), "harness runtime sample path")
    harness_samples = load_jsonl(harness_sample_path)
    for sample in harness_samples:
        sample["observation_source"] = "vm_harness_matrix_row"
        sample["sample_source_event"] = "matrix-harness-generated-fallback"
    _ = harness_sample_path.write_text("".join(json.dumps(sample, sort_keys=True) + "\n" for sample in harness_samples))
    checks.expect_reject(harness_runtime, "harness-generated runtime sample backing PASS")


def assert_missing_abi_rejected(checks: SuiteSelfTest, root: Path) -> None:
    missing_abi = write_protected_manifest(checks, root / "missing-abi")
    cgroup_artifact = root / "missing-abi" / "rows" / "workload-cgroup-weight-quota" / "matrix-run.json"
    cgroup_row = checks.load_json(cgroup_artifact)
    sample_path = checks.safe_path(cgroup_row.get("runtime_sample_path"), "missing ABI runtime path")
    sample = load_jsonl(sample_path)[0]
    policy_abi = checks.obj(sample.get("policy_abi"), "missing ABI policy_abi")
    policy_abi["abi_version"] = 2
    _ = sample_path.write_text(json.dumps(sample, sort_keys=True) + "\n")
    checks.expect_reject(missing_abi, "missing ABI-v3 cgroup evidence")


def assert_missing_map_rejected(checks: SuiteSelfTest, root: Path) -> None:
    missing_map = write_protected_manifest(checks, root / "missing-cgroup-map")
    cgroup_artifact = root / "missing-cgroup-map" / "rows" / "workload-cgroup-weight-quota" / "matrix-run.json"
    cgroup_row = checks.load_json(cgroup_artifact)
    sample_path = checks.safe_path(cgroup_row.get("runtime_sample_path"), "missing cgroup map runtime path")
    sample = load_jsonl(sample_path)[0]
    policy_abi = checks.obj(sample.get("policy_abi"), "missing cgroup map policy_abi")
    policy_map = checks.obj(policy_abi.get("cgroup_policy_map"), "missing cgroup map policy_abi.cgroup_policy_map")
    policy_map["callback_observed_knobs"] = []
    _ = sample_path.write_text(json.dumps(sample, sort_keys=True) + "\n")
    checks.expect_reject(missing_map, "missing cgroup policy map callback evidence")


def assert_weight_only_cgroup_callback_accepted(checks: SuiteSelfTest, root: Path) -> None:
    weight_only = write_protected_manifest(checks, root / "weight-only-cgroup-callback")
    cgroup_artifact = root / "weight-only-cgroup-callback" / "rows" / "workload-cgroup-weight-quota" / "matrix-run.json"
    cgroup_row = checks.load_json(cgroup_artifact)
    sample_path = checks.safe_path(cgroup_row.get("runtime_sample_path"), "weight-only cgroup runtime path")
    samples = load_jsonl(sample_path)
    for sample in samples:
        policy_abi = checks.obj(sample.get("policy_abi"), "weight-only policy_abi")
        policy_map = checks.obj(policy_abi.get("cgroup_policy_map"), "weight-only policy_abi.cgroup_policy_map")
        callback_stats = checks.obj(policy_abi.get("cgroup_callback_stats"), "weight-only policy_abi.cgroup_callback_stats")
        policy_map["move_generation"] = 0
        callback_stats["cgroup_move_calls"] = 0
    _ = sample_path.write_text("".join(json.dumps(sample, sort_keys=True) + "\n" for sample in samples))
    checks.validate_manifest(weight_only)
    print("PASS accept cgroup weight callback evidence when move callbacks are unavailable")


def run_self_test(checks: SuiteSelfTest) -> None:
    shutil.rmtree(SELF_ROOT, ignore_errors=True)
    SELF_ROOT.mkdir(parents=True)
    try:
        good = write_protected_manifest(checks, SELF_ROOT)
        checks.validate_manifest(good)
        print("PASS accept protected-core suite manifest with row-local artifacts and ABI-v3 cgroup linkage")
        one_row = write_manifest_self_test_pack(SELF_ROOT / "one-row", checks.load_json(Path("fixtures/matrix-run/pass.json")), "workload-cpu-saturation")
        checks.expect_reject(one_row, "missing protected-core rows")
        assert_shared_runtime_rejected(checks, SELF_ROOT)
        assert_harness_runtime_rejected(checks, SELF_ROOT)
        assert_missing_abi_rejected(checks, SELF_ROOT)
        assert_missing_map_rejected(checks, SELF_ROOT)
        assert_weight_only_cgroup_callback_accepted(checks, SELF_ROOT)
    finally:
        shutil.rmtree(SELF_ROOT, ignore_errors=True)
    print("PASS protected-core suite self-test")
