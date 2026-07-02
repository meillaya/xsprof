#!/usr/bin/env python3
# pyright: reportAny=false
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
# ─── How to run ───
# python3 qa/evidence_bundle_compare_check.py --self-test
"""Self-test fixtures for evidence_bundle_compare_check.py."""
from __future__ import annotations

import json
import shutil
import sys
from pathlib import Path
from typing import Final

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from qa.evidence_bundle_compare_check import BundleCompareError, CompareOptions, compare, file_sha, obj
from qa.evidence_manifest_check import JsonObject, JsonValue, load_json

DEFAULT_TUPLE: Final[str] = "linux-6.12.0-x86_64-sched_ext-bpf-bpf_jit-btf-vm_lab_only"


def write_json(path: Path, value: JsonObject) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    _ = path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def ref(root: Path, path: Path, role: str) -> JsonObject:
    return {"path": path.relative_to(root).as_posix(), "sha256": file_sha(path), "schema_role": role}


def write_bundle(root: Path, rows: tuple[str, ...] = ("live-backend", "workload-cpu-saturation"), bpf_hash: str = "0" * 64, tuple_value: str = DEFAULT_TUPLE) -> Path:
    write_json(root / "matrix.json", {"schema": "zig-scheduler/vm-harness-matrix-index/v1", "rows": [{"scenario_id": row} for row in rows], "host_mutation": False, "release_eligible": False})
    for role in ("matrix-row", "rollback-proof", "cleanup-proof", "host-refusal-proof", "privacy-scan"):
        write_json(root / f"{role}.json", {"schema": f"zig-scheduler/{role}/v1", "host_mutation": False, "release_eligible": False, "production_capacity_claim": False})
    write_json(root / "runner-substrate-proof.json", {"schema": "zig-scheduler/runner-substrate-proof/v1", "kernel_tuple": {"supported_tuple": tuple_value}, "host_mutation": False, "release_eligible": False, "production_capacity_claim": False})
    write_json(root / "runner-cleanliness-proof.json", {"schema": "zig-scheduler/runner-cleanliness-proof/v1", "host_mutation": False, "release_eligible": False, "production_capacity_claim": False})
    write_json(root / "protected-environment-review.json", {"schema": "zig-scheduler/protected-environment-review/v1", "head_sha": "f" * 40, "host_mutation": False, "release_eligible": False, "production_capacity_claim": False})
    write_json(root / "bpf.json", {"schema": "zig-scheduler/bpf-metadata/v1", "bpf_object_sha256": bpf_hash, "host_mutation": False, "release_eligible": False, "production_capacity_claim": False})
    _ = (root / "daemon.jsonl").write_text('{"host_mutation": false, "release_eligible": false, "production_capacity_claim": false}\n')
    manifest = root / "evidence-manifest.json"
    write_json(manifest, {"schema": "zig-scheduler/evidence-manifest/v1", "outcome": "PASS", "audit_id": "AUD-20990101T000000Z-compare", "rollback_id": "RB-compare", "vm_marker": {"path": "/run/zig-scheduler-vm-lab.marker", "present": True, "checked_by": "manual-vm-proof"}, "supported_tuple": tuple_value, "bpf_metadata_or_skip": ref(root, root / "bpf.json", "bpf-metadata"), "matrix_manifest": ref(root, root / "matrix.json", "matrix-manifest"), "daemon_events": ref(root, root / "daemon.jsonl", "daemon-events"), "runner_substrate": ref(root, root / "runner-substrate-proof.json", "runner-substrate-proof"), "runner_cleanliness": ref(root, root / "runner-cleanliness-proof.json", "runner-cleanliness-proof"), "artifacts": [ref(root, root / f"{role}.json", role) for role in ("protected-environment-review", "matrix-row", "rollback-proof", "cleanup-proof", "host-refusal-proof", "privacy-scan")], "benchmark_provenance": {"status": "not_applicable", "reason": "comparison self-test", "applies_to_outcomes": ["SKIP", "REFUSE", "BLOCKED"]}, "privacy_scan": {"status": "PASS", "private_fields_found": False, "artifact_paths": ["privacy-scan.json"]}, "attestation": {"status": "pending-post-run-github-attestation", "workflow_uses": "actions/attest-build-provenance@v2", "verify_command": "gh attestation verify bundle --repo owner/repo", "retention_days": 30}, "required_sources": ["qa/evidence_bundle_compare_check.py"], "host_mutation": False, "release_eligible": False, "production_capacity_claim": False})
    return manifest


def without_role(path: Path, role: str) -> Path:
    data = load_json(path)
    artifacts = data.get("artifacts")
    if isinstance(artifacts, list):
        data["artifacts"] = [item for item in artifacts if not (isinstance(item, dict) and item.get("schema_role") == role)]
    bad = path.parent / f"missing-{role}.json"
    write_json(bad, data)
    return bad


def mutated_manifest(path: Path, key: str, value: JsonValue, name: str) -> Path:
    data = load_json(path)
    data[key] = value
    bad = path.parent / name
    write_json(bad, data)
    return bad


def unsafe_path_manifest(path: Path) -> Path:
    data = load_json(path)
    matrix = obj(data.get("matrix_manifest"), "matrix_manifest")
    matrix["path"] = "../unsafe/matrix.json"
    bad = path.parent / "unsafe-path.json"
    write_json(bad, data)
    return bad


def expect_manifest_root_wins_ambiguous_artifact() -> None:
    root = Path("evidence/lab/evidence-bundle-compare-ambiguous-self-test")
    cwd_artifact = Path("matrix.json")
    original_cwd_text = cwd_artifact.read_text() if cwd_artifact.exists() else None
    shutil.rmtree(root, ignore_errors=True)
    try:
        left = write_bundle(root / "left")
        right = write_bundle(root / "right")
        _ = cwd_artifact.write_text('{"schema":"wrong-caller-cwd-artifact","host_mutation":false}\n')
        compare(left, right)
        print("PASS prefer bundle root over caller CWD for ambiguous artifact paths")
    finally:
        shutil.rmtree(root, ignore_errors=True)
        if original_cwd_text is None:
            cwd_artifact.unlink(missing_ok=True)
        else:
            _ = cwd_artifact.write_text(original_cwd_text)


def expect_reject(left: Path, right: Path, label: str) -> None:
    try:
        compare(left, right)
    except BundleCompareError as exc:
        print(f"PASS reject {label}: {exc}")
        return
    raise BundleCompareError(f"expected rejection did not occur: {label}")


def run_self_test() -> None:
    root = Path("evidence/lab/evidence-bundle-compare-self-test")
    shutil.rmtree(root, ignore_errors=True)
    try:
        left = write_bundle(root / "left")
        right = write_bundle(root / "right")
        compare(left.parent, right.parent)
        print("PASS accept comparable protected evidence bundle roots")
        expect_manifest_root_wins_ambiguous_artifact()
        expect_reject(left, without_role(right, "cleanup-proof"), "missing cleanup proof")
        expect_reject(left, write_bundle(root / "row-mismatch", ("live-backend",)), "row set mismatch")
        expect_reject(left, write_bundle(root / "bpf-mismatch", bpf_hash="1" * 64), "BPF hash mismatch")
        compare(left, write_bundle(root / "bpf-expected", bpf_hash="2" * 64), CompareOptions(expect_bpf_change=True))
        print("PASS accept expected BPF hash change")
        expect_reject(left, write_bundle(root / "tuple-mismatch", tuple_value="linux-6.13.0-x86_64-sched_ext-bpf-bpf_jit-btf-vm_lab_only"), "tuple mismatch")
        compare(left, write_bundle(root / "tuple-expected", tuple_value="linux-6.13.0-x86_64-sched_ext-bpf-bpf_jit-btf-vm_lab_only"), CompareOptions(expect_tuple_change=True))
        print("PASS accept expected tuple change")
        expect_reject(left, mutated_manifest(right, "production_capacity_claim", True, "production-claim.json"), "production claim")
        expect_reject(left, unsafe_path_manifest(right), "unsafe path")
    finally:
        shutil.rmtree(root, ignore_errors=True)
    print("PASS evidence bundle compare self-test")


if __name__ == "__main__":
    run_self_test()
