#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
# ─── How to run ───
# python3 qa/protected_core_suite_check.py --manifest evidence/lab/matrix/<run-id>/manifest.json
# python3 qa/protected_core_suite_check.py --self-test
"""Validate protected-core matrix suite shape and row-local proof links."""
from __future__ import annotations

import json
import shutil
import sys
from pathlib import Path
from typing import Final

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from qa.matrix_run_contract_check import JsonObject, JsonValue, load_json, write_manifest_self_test_pack
from qa.runtime_sample_common import RuntimeSampleError, load_jsonl

PROTECTED_REQUIRED_ROWS: Final[frozenset[str]] = frozenset(("live-backend", "workload-cpu-saturation", "workload-cgroup-weight-quota"))
LATENCY_ROWS: Final[frozenset[str]] = frozenset(("workload-interactive-latency", "workload-scheduler-affinity-churn"))
ROW_LOCAL_FIELDS: Final[tuple[str, ...]] = ("runtime_sample_path", "incident_path", "rollback_proof_path", "cleanup_proof_path", "host_refusal_proof_path")
ABI_V3_LABEL: Final[str] = "zigsched-bpf-abi-v3"
REQUIRED_CALLBACK_STATS: Final[tuple[str, ...]] = ("cgroup_init_calls", "cgroup_exit_calls", "cgroup_move_calls", "cgroup_set_weight_calls", "cgroup_weight_observed")


class ProtectedCoreSuiteError(Exception):
    """Raised when a protected-core matrix suite contract is not satisfied."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ProtectedCoreSuiteError(message)


def text(value: JsonValue | None, context: str) -> str:
    if not isinstance(value, str) or value == "":
        raise ProtectedCoreSuiteError(f"{context} must be non-empty text")
    return value


def obj(value: JsonValue | None, context: str) -> JsonObject:
    if not isinstance(value, dict):
        raise ProtectedCoreSuiteError(f"{context} must be an object")
    return value


def safe_path(value: JsonValue | None, context: str) -> Path:
    raw = text(value, context)
    path = Path(raw)
    require(not path.is_absolute() and ".." not in path.parts, f"{context} must be relative and non-traversing: {raw}")
    return path


def require_descendant(path: Path, root: Path, context: str) -> None:
    require(path == root or path.parts[: len(root.parts)] == root.parts, f"{context} must stay under {root}: {path}")


def manifest_rows(manifest: JsonObject, context: str) -> list[JsonObject]:
    rows = manifest.get("rows")
    if not isinstance(rows, list):
        raise ProtectedCoreSuiteError(f"{context}.rows must be a list")
    parsed: list[JsonObject] = []
    for index, row in enumerate(rows):
        parsed.append(obj(row, f"{context}.rows[{index}]"))
    return parsed


def validate_suite_shape(rows: list[JsonObject], context: str) -> dict[str, JsonObject]:
    by_scenario: dict[str, JsonObject] = {}
    for index, row_ref in enumerate(rows):
        scenario = text(row_ref.get("scenario_id"), f"{context}.rows[{index}].scenario_id")
        require(scenario not in by_scenario, f"{context} duplicate scenario: {scenario}")
        by_scenario[scenario] = row_ref
    scenarios = frozenset(by_scenario)
    missing = sorted(PROTECTED_REQUIRED_ROWS - scenarios)
    require(not missing, f"{context} missing protected-core row(s): {', '.join(missing)}")
    selected_latency = sorted(scenarios & LATENCY_ROWS)
    require(len(selected_latency) == 1, f"{context} requires exactly one latency/churn row, found {len(selected_latency)}")
    expected = set(PROTECTED_REQUIRED_ROWS)
    expected.add(selected_latency[0])
    extra = sorted(scenarios - expected)
    require(not extra, f"{context} has non-protected-core row(s): {', '.join(extra)}")
    for scenario in sorted(expected):
        outcome = text(by_scenario[scenario].get("outcome"), f"{context}.{scenario}.outcome")
        require(outcome == "PASS", f"{context}.{scenario} must PASS for protected-core PASS proof")
    return by_scenario


def validate_row_local_artifacts(row: JsonObject, row_path: Path, run_root: Path, context: str) -> None:
    row_dir = row_path.parent
    for field in ROW_LOCAL_FIELDS:
        artifact = safe_path(row.get(field), f"{context}.{field}")
        require_descendant(artifact, row_dir, f"{context}.{field}")
    workload = obj(row.get("workload"), f"{context}.workload")
    policy = obj(row.get("policy"), f"{context}.policy")
    privacy = obj(row.get("privacy_scan"), f"{context}.privacy_scan")
    for path, label in (
        (safe_path(workload.get("spec_path"), f"{context}.workload.spec_path"), "workload.spec_path"),
        (safe_path(policy.get("object_path"), f"{context}.policy.object_path"), "policy.object_path"),
        (safe_path(privacy.get("report_path"), f"{context}.privacy_scan.report_path"), "privacy_scan.report_path"),
    ):
        require_descendant(path, row_dir, f"{context}.{label}")
    daemon = safe_path(row.get("daemon_event_path"), f"{context}.daemon_event_path")
    require_descendant(daemon, run_root, f"{context}.daemon_event_path")


def nonnegative_int(value: JsonValue | None, context: str) -> int:
    if not isinstance(value, int) or value < 0:
        raise ProtectedCoreSuiteError(f"{context} must be a nonnegative integer")
    return value


def string_list(value: JsonValue | None, context: str) -> list[str]:
    if not isinstance(value, list) or not all(isinstance(item, str) and item != "" for item in value):
        raise ProtectedCoreSuiteError(f"{context} must be a string list")
    return value


def validate_present_cgroup_evidence(policy_abi: JsonObject, context: str) -> bool:
    policy_map = obj(policy_abi.get("cgroup_policy_map"), f"{context}.cgroup_policy_map")
    stats = obj(policy_abi.get("cgroup_callback_stats"), f"{context}.cgroup_callback_stats")
    coherence = obj(policy_abi.get("dsq_counter_coherence"), f"{context}.dsq_counter_coherence")
    if policy_map.get("status") != "present" or stats.get("status") != "present" or coherence.get("status") != "present":
        return False
    require(policy_map.get("map_name") == "zigsched_cgroup_policy", f"{context}.cgroup_policy_map.map_name must be zigsched_cgroup_policy")
    require("cpu.weight" in string_list(policy_map.get("callback_observed_knobs"), f"{context}.cgroup_policy_map.callback_observed_knobs"), f"{context} missing cpu.weight callback-observed map evidence")
    require("cpu.max" in string_list(policy_map.get("deferred_knobs"), f"{context}.cgroup_policy_map.deferred_knobs"), f"{context} must keep cpu.max deferred in policy map")
    require("uclamp" in string_list(policy_map.get("deferred_knobs"), f"{context}.cgroup_policy_map.deferred_knobs"), f"{context} must keep uclamp deferred in policy map")
    require(nonnegative_int(policy_map.get("last_weight"), f"{context}.cgroup_policy_map.last_weight") > 0, f"{context} requires observed cpu.weight value")
    require(nonnegative_int(policy_map.get("weight_generation"), f"{context}.cgroup_policy_map.weight_generation") > 0, f"{context} requires cpu.weight generation evidence")
    require(nonnegative_int(policy_map.get("move_generation"), f"{context}.cgroup_policy_map.move_generation") > 0, f"{context} requires cgroup move generation evidence")
    for field in REQUIRED_CALLBACK_STATS:
        _ = nonnegative_int(stats.get(field), f"{context}.cgroup_callback_stats.{field}")
    require(nonnegative_int(stats.get("cgroup_init_calls"), f"{context}.cgroup_callback_stats.cgroup_init_calls") > 0, f"{context} requires cgroup init callback evidence")
    require(nonnegative_int(stats.get("cgroup_move_calls"), f"{context}.cgroup_callback_stats.cgroup_move_calls") > 0, f"{context} requires cgroup move callback evidence")
    require(nonnegative_int(stats.get("cgroup_set_weight_calls"), f"{context}.cgroup_callback_stats.cgroup_set_weight_calls") > 0, f"{context} requires cgroup set-weight callback evidence")
    require(nonnegative_int(stats.get("cgroup_weight_observed"), f"{context}.cgroup_callback_stats.cgroup_weight_observed") > 0, f"{context} requires observed cpu.weight callback counter")
    require(stats.get("cpu_weight_callback_observed") is True, f"{context}.cgroup_callback_stats.cpu_weight_callback_observed must be true")
    for field in ("fifo_insert_dispatch_coherent", "vtime_insert_dispatch_coherent", "dispatch_empty_accounted"):
        require(coherence.get(field) is True, f"{context}.dsq_counter_coherence.{field} must be true")
    return True


def validate_cgroup_abi_linkage(row: JsonObject, context: str) -> None:
    sample_path = safe_path(row.get("runtime_sample_path"), f"{context}.runtime_sample_path")
    samples = load_jsonl(sample_path)
    has_v3 = False
    has_present_cgroup_evidence = False
    for index, sample in enumerate(samples):
        policy_abi = sample.get("policy_abi")
        if not isinstance(policy_abi, dict):
            continue
        if policy_abi.get("abi_version") == 3:
            has_v3 = True
            sample_context = f"{context}.runtime_sample[{index}].policy_abi"
            require(policy_abi.get("abi_label") == ABI_V3_LABEL, f"{sample_context}.abi_label must be {ABI_V3_LABEL}")
            semantics = obj(policy_abi.get("cgroup_semantics"), f"{sample_context}.cgroup_semantics")
            require(semantics.get("cpu.weight") == "callback-observed", f"{context} missing cpu.weight callback observation")
            require(semantics.get("cpu.max") == "deferred", f"{context} must keep cpu.max deferred/observe-only")
            require(semantics.get("uclamp") == "deferred", f"{context} must keep uclamp deferred/observe-only")
            has_present_cgroup_evidence = validate_present_cgroup_evidence(policy_abi, sample_context) or has_present_cgroup_evidence
    require(has_v3, f"{context} requires ABI-v3 cgroup runtime sample evidence")
    require(has_present_cgroup_evidence, f"{context} requires present cgroup policy map/callback/DSQ evidence")


def validate_manifest(path: Path) -> None:
    manifest = load_json(path)
    run_root = path.parent
    rows = manifest_rows(manifest, str(path))
    by_scenario = validate_suite_shape(rows, str(path))
    for scenario, row_ref in by_scenario.items():
        artifact_path = safe_path(row_ref.get("artifact_path"), f"{path}.{scenario}.artifact_path")
        require_descendant(artifact_path, run_root, f"{path}.{scenario}.artifact_path")
        row = load_json(artifact_path)
        validate_row_local_artifacts(row, artifact_path, run_root, artifact_path.as_posix())
        if scenario == "workload-cgroup-weight-quota":
            validate_cgroup_abi_linkage(row, artifact_path.as_posix())


def write_protected_manifest(root: Path) -> Path:
    good = load_json(Path("fixtures/matrix-run/pass.json"))
    scenarios = ("live-backend", "workload-cpu-saturation", "workload-cgroup-weight-quota", "workload-interactive-latency")
    row_refs: list[JsonValue] = []
    for scenario in scenarios:
        manifest_path = write_manifest_self_test_pack(root, good, scenario)
        manifest = load_json(manifest_path)
        rows = manifest_rows(manifest, manifest_path.as_posix())
        row_refs.append(dict(rows[0]))
    manifest = load_json(root / "manifest.json")
    manifest["rows"] = row_refs
    manifest["row_count"] = len(row_refs)
    _ = (root / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    return root / "manifest.json"


def expect_reject(path: Path, label: str) -> None:
    try:
        validate_manifest(path)
    except ProtectedCoreSuiteError as exc:
        print(f"PASS reject {label}: {exc}")
        return
    raise ProtectedCoreSuiteError(f"expected rejection did not occur: {label}")


def self_test() -> None:
    root = Path("evidence/lab/matrix/protected-core-suite-self-test")
    shutil.rmtree(root, ignore_errors=True)
    root.mkdir(parents=True)
    try:
        good = write_protected_manifest(root)
        validate_manifest(good)
        print("PASS accept protected-core suite manifest with row-local artifacts and ABI-v3 cgroup linkage")
        one_row = write_manifest_self_test_pack(root / "one-row", load_json(Path("fixtures/matrix-run/pass.json")), "workload-cpu-saturation")
        expect_reject(one_row, "missing protected-core rows")
        shared = write_protected_manifest(root / "shared-artifact")
        manifest = load_json(shared)
        rows = manifest_rows(manifest, shared.as_posix())
        first = obj(rows[0], "shared-artifact first row")
        second = obj(rows[1], "shared-artifact second row")
        second_row = load_json(safe_path(second.get("artifact_path"), "shared artifact second path"))
        first_row = load_json(safe_path(first.get("artifact_path"), "shared artifact first path"))
        second_row["runtime_sample_path"] = first_row["runtime_sample_path"]
        _ = safe_path(second.get("artifact_path"), "shared artifact second path").write_text(json.dumps(second_row, indent=2, sort_keys=True) + "\n")
        expect_reject(shared, "shared row runtime sample")
        missing_abi = write_protected_manifest(root / "missing-abi")
        cgroup_artifact = root / "missing-abi" / "rows" / "workload-cgroup-weight-quota" / "matrix-run.json"
        cgroup_row = load_json(cgroup_artifact)
        sample_path = safe_path(cgroup_row.get("runtime_sample_path"), "missing ABI runtime path")
        sample = load_jsonl(sample_path)[0]
        policy_abi = obj(sample.get("policy_abi"), "missing ABI policy_abi")
        policy_abi["abi_version"] = 2
        _ = sample_path.write_text(json.dumps(sample, sort_keys=True) + "\n")
        expect_reject(missing_abi, "missing ABI-v3 cgroup evidence")
        missing_map = write_protected_manifest(root / "missing-cgroup-map")
        cgroup_artifact = root / "missing-cgroup-map" / "rows" / "workload-cgroup-weight-quota" / "matrix-run.json"
        cgroup_row = load_json(cgroup_artifact)
        sample_path = safe_path(cgroup_row.get("runtime_sample_path"), "missing cgroup map runtime path")
        sample = load_jsonl(sample_path)[0]
        policy_abi = obj(sample.get("policy_abi"), "missing cgroup map policy_abi")
        policy_map = obj(policy_abi.get("cgroup_policy_map"), "missing cgroup map policy_abi.cgroup_policy_map")
        policy_map["callback_observed_knobs"] = []
        _ = sample_path.write_text(json.dumps(sample, sort_keys=True) + "\n")
        expect_reject(missing_map, "missing cgroup policy map callback evidence")
    finally:
        shutil.rmtree(root, ignore_errors=True)
    print("PASS protected-core suite self-test")


def main(argv: list[str]) -> int:
    try:
        if argv == ["--self-test"]:
            self_test()
            return 0
        if len(argv) == 2 and argv[0] == "--manifest":
            validate_manifest(Path(argv[1]))
            print(f"PASS protected-core suite: {argv[1]}")
            return 0
        raise ProtectedCoreSuiteError("usage: protected_core_suite_check.py --self-test | --manifest <path>")
    except (OSError, RuntimeSampleError, ProtectedCoreSuiteError) as exc:
        print(f"FAIL protected-core suite: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
