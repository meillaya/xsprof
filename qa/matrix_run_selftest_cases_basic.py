#!/usr/bin/env python3
"""Basic manifest self-test mutations for matrix-run checks."""
from __future__ import annotations

import json
from pathlib import Path

from qa.matrix_run_json import file_sha256, load_json, obj, text
from qa.matrix_run_model import MANIFEST_FILE, MatrixRunContractError
from qa.matrix_run_selftest_common import ManifestSelfTestContext, assert_invalid_manifest, write_json
from qa.matrix_run_selftest_pack import write_manifest_self_test_pack


def handle_basic_manifest_case(ctx: ManifestSelfTestContext) -> bool:
    match ctx.name:  # noqa: RUF100  # noqa: MATCH_OK - self-test case names are runtime strings; false means another group may own it.
        case "root-outside-matrix":
            assert_invalid_manifest(Path("evidence/lab/self-test-root") / MANIFEST_FILE, ctx.name)
        case "absolute-artifact-path":
            ctx.row["artifact_path"] = "/tmp/matrix-run.json"
            write_json(ctx.manifest_path, ctx.manifest)
            assert_invalid_manifest(ctx.manifest_path, ctx.name)
        case "artifact-outside-run-root":
            ctx.row["artifact_path"] = "fixtures/matrix-run/pass.json"
            write_json(ctx.manifest_path, ctx.manifest)
            assert_invalid_manifest(ctx.manifest_path, ctx.name)
        case "duplicate-scenario":
            ctx.rows.append(dict(ctx.row))
            ctx.manifest["row_count"] = 2
            write_json(ctx.manifest_path, ctx.manifest)
            assert_invalid_manifest(ctx.manifest_path, ctx.name)
        case "duplicate-artifact":
            second = dict(ctx.row)
            second["scenario_id"] = "fixture-pass-copy"
            ctx.rows.append(second)
            ctx.manifest["row_count"] = 2
            write_json(ctx.manifest_path, ctx.manifest)
            assert_invalid_manifest(ctx.manifest_path, ctx.name)
        case "row-count-mismatch":
            ctx.manifest["row_count"] = 2
            write_json(ctx.manifest_path, ctx.manifest)
            assert_invalid_manifest(ctx.manifest_path, ctx.name)
        case "manifest-out-dir-mismatch":
            ctx.manifest["out_dir"] = "evidence/lab/matrix/other-run"
            write_json(ctx.manifest_path, ctx.manifest)
            assert_invalid_manifest(ctx.manifest_path, ctx.name)
        case "manifest-run-id-basename-mismatch":
            ctx.manifest["matrix_run_id"] = "other-run"
            write_json(ctx.manifest_path, ctx.manifest)
            assert_invalid_manifest(ctx.manifest_path, ctx.name)
        case "row-run-id-manifest-mismatch":
            row_data = load_json(ctx.artifact_path)
            row_data["matrix_run_id"] = "other-run"
            write_json(ctx.artifact_path, row_data)
            assert_invalid_manifest(ctx.manifest_path, ctx.name)
        case "row-internal-path-outside-root":
            row_data = load_json(ctx.artifact_path)
            row_data["runtime_sample_path"] = "fixtures/matrix-run/pass.json"
            write_json(ctx.artifact_path, row_data)
            assert_invalid_manifest(ctx.manifest_path, ctx.name)
        case "missing-proof-artifact":
            row_data = load_json(ctx.artifact_path)
            Path(text(row_data.get("rollback_proof_path"), "manifest self-test rollback_proof_path")).unlink()
            assert_invalid_manifest(ctx.manifest_path, ctx.name, "missing JSON file")
        case "invalid-runtime-sample-artifact":
            row_data = load_json(ctx.artifact_path)
            runtime_path = Path(text(row_data.get("runtime_sample_path"), "manifest self-test runtime_sample_path"))
            _ = runtime_path.write_text(json.dumps({"schema": "zig-scheduler/runtime-sample/v1", "sequence": 0}) + "\n")
            assert_invalid_manifest(ctx.manifest_path, ctx.name, "invalid runtime sample artifact")
        case "host-safe-vm-live-claim":
            ctx.manifest["mode"] = "host-safe"
            ctx.manifest["fixture_mode"] = True
            write_json(ctx.manifest_path, ctx.manifest)
            assert_invalid_manifest(ctx.manifest_path, ctx.name, "fixture manifest must not claim")
        case "forged-pass-host-refusal-no-marker":
            row_data = load_json(ctx.artifact_path)
            row_data["evidence_mode"] = "host-refusal-only"
            marker = obj(row_data.get("vm_marker"), "manifest self-test vm_marker")
            marker["required"] = False
            marker["present"] = False
            marker["checked_by"] = "qa/vm/vm_harness_matrix.sh"
            write_json(ctx.artifact_path, row_data)
            assert_invalid_manifest(ctx.manifest_path, ctx.name, "PASS requires vm-live proof or explicit fixture evidence")
        case "forged-fixture-mode-false-fixture-pass":
            row_data = load_json(ctx.artifact_path)
            row_data["evidence_mode"] = "fixture"
            marker = obj(row_data.get("vm_marker"), "manifest self-test vm_marker")
            marker["required"] = False
            marker["present"] = False
            marker["checked_by"] = "qa/vm/vm_harness_matrix.sh"
            write_json(ctx.artifact_path, row_data)
            assert_invalid_manifest(ctx.manifest_path, ctx.name, "fixture evidence requires explicit fixture_mode=true")
        case "host-safe-fixture-mode-false-fixture-pass":
            ctx.manifest["mode"] = "host-safe"
            ctx.manifest["fixture_mode"] = False
            row_data = load_json(ctx.artifact_path)
            row_data["evidence_mode"] = "fixture"
            marker = obj(row_data.get("vm_marker"), "manifest self-test vm_marker")
            marker["required"] = False
            marker["present"] = False
            marker["checked_by"] = "qa/vm/vm_harness_matrix.sh"
            write_json(ctx.artifact_path, row_data)
            write_json(ctx.manifest_path, ctx.manifest)
            assert_invalid_manifest(ctx.manifest_path, ctx.name, "fixture evidence requires explicit fixture_mode=true")
        case "vm-live-missing-marker-proof":
            row_data = load_json(ctx.artifact_path)
            marker = obj(row_data.get("vm_marker"), "manifest self-test vm_marker")
            marker["checked_by"] = "qa/vm/vm_harness_matrix.sh"
            write_json(ctx.artifact_path, row_data)
            assert_invalid_manifest(ctx.manifest_path, ctx.name, "vm_marker.checked_by must stay under")
        case "vm-live-marker-proof-mismatch":
            row_data = load_json(ctx.artifact_path)
            marker = obj(row_data.get("vm_marker"), "manifest self-test vm_marker")
            marker_path = Path(text(marker.get("checked_by"), "manifest self-test vm_marker.checked_by"))
            proof = load_json(marker_path)
            proof["present"] = False
            write_json(marker_path, proof)
            assert_invalid_manifest(ctx.manifest_path, ctx.name, "present must match row marker")
        case "malicious-workload-spec-token":
            row_data = load_json(ctx.artifact_path)
            workload = obj(row_data.get("workload"), "manifest self-test workload")
            spec_path = Path(text(workload.get("spec_path"), "manifest self-test workload.spec_path"))
            spec_data = load_json(spec_path)
            spec_data["api_key"] = "must-not-persist"
            write_json(spec_path, spec_data)
            workload["spec_sha256"] = file_sha256(spec_path)
            write_json(ctx.artifact_path, row_data)
            assert_invalid_manifest(ctx.manifest_path, ctx.name)
        case "malicious-capability-token":
            row_data = load_json(ctx.artifact_path)
            workload = obj(row_data.get("workload"), "manifest self-test workload")
            spec_path = Path(text(workload.get("spec_path"), "manifest self-test workload.spec_path"))
            spec_data = load_json(spec_path)
            capability_path = Path(text(spec_data.get("capability_artifact_path"), "manifest self-test capability_artifact_path"))
            capability_data = load_json(capability_path)
            capability_data["environment"] = "api_key=must-not-persist"
            write_json(capability_path, capability_data)
            assert_invalid_manifest(ctx.manifest_path, ctx.name)
        case "false-private-fields-found":
            row_data = load_json(ctx.artifact_path)
            privacy = obj(row_data.get("privacy_scan"), "manifest self-test privacy_scan")
            privacy_path = Path(text(privacy.get("report_path"), "manifest self-test privacy_scan.report_path"))
            privacy_data = load_json(privacy_path)
            privacy_data["private_fields_found"] = False
            write_json(privacy_path, privacy_data)
            workload = obj(row_data.get("workload"), "manifest self-test workload")
            spec_path = Path(text(workload.get("spec_path"), "manifest self-test workload.spec_path"))
            spec_data = load_json(spec_path)
            spec_data["notes"] = "contains api_key while report claims clean"
            write_json(spec_path, spec_data)
            workload["spec_sha256"] = file_sha256(spec_path)
            write_json(ctx.artifact_path, row_data)
            assert_invalid_manifest(ctx.manifest_path, ctx.name)
        case "unsupported-bpf-abi-drift":
            row_data = load_json(ctx.artifact_path)
            row_data["bpf_abi_version"] = "zigsched-bpf-abi-v3"
            write_json(ctx.artifact_path, row_data)
            assert_invalid_manifest(ctx.manifest_path, ctx.name, "bpf_abi_version must be zigsched-bpf-abi-v1")
        case "workload-cgroup-semantic-label-mismatch":
            cgroup_manifest = write_manifest_self_test_pack(ctx.run_root, ctx.good, "workload-cgroup-weight-quota")
            cgroup_rows = load_json(cgroup_manifest).get("rows")
            if not isinstance(cgroup_rows, list):
                raise MatrixRunContractError("cgroup semantic self-test setup produced non-list rows")
            cgroup_artifact_path = Path(text(obj(cgroup_rows[0], "cgroup semantic manifest row").get("artifact_path"), "cgroup semantic artifact_path"))
            row_data = load_json(cgroup_artifact_path)
            workload = obj(row_data.get("workload"), "cgroup semantic workload")
            spec_path = Path(text(workload.get("spec_path"), "cgroup semantic workload.spec_path"))
            spec_data = load_json(spec_path)
            semantics = obj(spec_data.get("cgroup_semantics"), "cgroup semantic workload.spec.cgroup_semantics")
            semantics["cpu.weight"] = "honored"
            write_json(spec_path, spec_data)
            workload["spec_sha256"] = file_sha256(spec_path)
            write_json(cgroup_artifact_path, row_data)
            assert_invalid_manifest(cgroup_manifest, ctx.name, "cgroup_semantics.cpu.weight must be callback-observed")
        case "workload-cpu-hotplug-semantic-label-mismatch":
            hotplug_manifest = write_manifest_self_test_pack(ctx.run_root, ctx.good, "workload-cpu-hotplug")
            hotplug_rows = load_json(hotplug_manifest).get("rows")
            if not isinstance(hotplug_rows, list):
                raise MatrixRunContractError("hotplug semantic self-test setup produced non-list rows")
            hotplug_artifact_path = Path(text(obj(hotplug_rows[0], "hotplug semantic manifest row").get("artifact_path"), "hotplug semantic artifact_path"))
            row_data = load_json(hotplug_artifact_path)
            workload = obj(row_data.get("workload"), "hotplug semantic workload")
            spec_path = Path(text(workload.get("spec_path"), "hotplug semantic workload.spec_path"))
            spec_data = load_json(spec_path)
            semantics = obj(spec_data.get("cpu_hotplug_semantics"), "hotplug semantic workload.spec.cpu_hotplug_semantics")
            semantics["allowed-mask"] = "accepted"
            write_json(spec_path, spec_data)
            workload["spec_sha256"] = file_sha256(spec_path)
            write_json(hotplug_artifact_path, row_data)
            assert_invalid_manifest(hotplug_manifest, ctx.name, "cpu_hotplug_semantics.allowed-mask must be rejected")
        case _:
            return False
    return True
