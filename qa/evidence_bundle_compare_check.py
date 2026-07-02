#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
# ─── How to run ───
# python3 qa/evidence_bundle_compare_check.py --left evidence/a/evidence-manifest.json --right evidence/b/evidence-manifest.json
# python3 qa/evidence_bundle_compare_check.py --self-test
"""Compare protected evidence bundle manifests without performance judgments."""
from __future__ import annotations

import hashlib
import json
import shutil
import sys
from pathlib import Path
from typing import Final

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from qa.evidence_manifest_check import JsonObject, JsonValue, ManifestError, load_json

REF_FIELDS: Final[frozenset[str]] = frozenset(("path", "sha256", "schema_role"))
REQUIRED_ROLES: Final[frozenset[str]] = frozenset(("matrix-manifest", "matrix-row", "rollback-proof", "cleanup-proof", "host-refusal-proof", "privacy-scan", "runner-substrate-proof", "runner-cleanliness-proof", "protected-environment-review"))


class BundleCompareError(Exception):
    """Raised when protected evidence bundles are not comparable."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise BundleCompareError(message)


def text(value: JsonValue | None, context: str) -> str:
    if not isinstance(value, str) or value == "":
        raise BundleCompareError(f"{context} must be non-empty text")
    return value


def obj(value: JsonValue | None, context: str) -> JsonObject:
    if not isinstance(value, dict):
        raise BundleCompareError(f"{context} must be an object")
    return value


def safe_path(value: JsonValue | None, context: str) -> Path:
    raw = text(value, context)
    path = Path(raw)
    require(not path.is_absolute() and ".." not in path.parts, f"{context} must be relative and non-traversing: {raw}")
    return path


def file_sha(path: Path) -> str:
    try:
        return hashlib.sha256(path.read_bytes()).hexdigest()
    except FileNotFoundError as exc:
        raise BundleCompareError(f"missing referenced artifact: {path}") from exc


def refs_from_manifest(manifest: JsonObject) -> list[JsonObject]:
    refs: list[JsonObject] = []
    for field in ("matrix_manifest", "daemon_events", "bpf_metadata_or_skip", "runner_substrate", "runner_cleanliness"):
        refs.append(obj(manifest.get(field), field))
    artifacts = manifest.get("artifacts")
    if not isinstance(artifacts, list):
        raise BundleCompareError("artifacts must be a list")
    for index, item in enumerate(artifacts):
        refs.append(obj(item, f"artifacts[{index}]"))
    benchmark = manifest.get("benchmark_provenance")
    if isinstance(benchmark, list):
        for index, item in enumerate(benchmark):
            refs.append(obj(item, f"benchmark_provenance[{index}]"))
    return refs


def validate_ref(ref: JsonObject, context: str) -> tuple[str, Path, str]:
    extra = sorted(set(ref) - REF_FIELDS)
    require(not extra, f"{context} has unexpected fields: {', '.join(extra)}")
    path = safe_path(ref.get("path"), f"{context}.path")
    digest = text(ref.get("sha256"), f"{context}.sha256")
    require(file_sha(path) == digest, f"{context}.sha256 does not match {path}")
    return text(ref.get("schema_role"), f"{context}.schema_role"), path, digest


def roles_and_paths(manifest: JsonObject, label: str) -> tuple[set[str], dict[str, tuple[Path, str]]]:
    roles: set[str] = set()
    by_role: dict[str, tuple[Path, str]] = {}
    for index, ref in enumerate(refs_from_manifest(manifest)):
        role, path, digest = validate_ref(ref, f"{label}.ref[{index}]")
        roles.add(role)
        _ = by_role.setdefault(role, (path, digest))
    missing = sorted(REQUIRED_ROLES - roles)
    require(not missing, f"{label} missing required role(s): {', '.join(missing)}")
    return roles, by_role


def reject_bundle_claims(manifest: JsonObject, label: str) -> None:
    require(manifest.get("host_mutation") is False, f"{label}.host_mutation must be false")
    require(manifest.get("release_eligible") is False, f"{label}.release_eligible must be false")
    require(manifest.get("production_capacity_claim") is False, f"{label}.production_capacity_claim must be false")


def row_set(matrix_path: Path, label: str) -> frozenset[str]:
    matrix = load_json(matrix_path)
    rows = matrix.get("rows")
    if not isinstance(rows, list):
        raise BundleCompareError(f"{label}.rows must be a list")
    scenarios: set[str] = set()
    for index, row in enumerate(rows):
        scenarios.add(text(obj(row, f"{label}.rows[{index}]").get("scenario_id"), f"{label}.rows[{index}].scenario_id"))
    return frozenset(scenarios)


def compare(left_path: Path, right_path: Path, *, allow_tuple_change: bool = False, allow_bpf_change: bool = False) -> None:
    left = load_json(left_path)
    right = load_json(right_path)
    reject_bundle_claims(left, "left")
    reject_bundle_claims(right, "right")
    left_roles, left_refs = roles_and_paths(left, "left")
    right_roles, right_refs = roles_and_paths(right, "right")
    require(left_roles == right_roles, "bundle role sets differ")
    left_tuple = text(left.get("supported_tuple"), "left.supported_tuple")
    right_tuple = text(right.get("supported_tuple"), "right.supported_tuple")
    require(allow_tuple_change or left_tuple == right_tuple, "supported_tuple changed without expected-change flag")
    left_bpf = left_refs.get("bpf-metadata") or left_refs.get("bpf-skip-json")
    right_bpf = right_refs.get("bpf-metadata") or right_refs.get("bpf-skip-json")
    if left_bpf is None or right_bpf is None:
        raise BundleCompareError("both bundles require BPF metadata or skip roles")
    require(allow_bpf_change or left_bpf[1] == right_bpf[1], "BPF artifact hash changed without expected-change flag")
    left_matrix = left_refs.get("matrix-manifest")
    right_matrix = right_refs.get("matrix-manifest")
    if left_matrix is None or right_matrix is None:
        raise BundleCompareError("both bundles require matrix-manifest role")
    require(row_set(left_matrix[0], "left.matrix") == row_set(right_matrix[0], "right.matrix"), "matrix row sets differ")


def write_json(path: Path, value: JsonObject) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    _ = path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def ref(path: Path, role: str) -> JsonObject:
    return {"path": path.as_posix(), "sha256": file_sha(path), "schema_role": role}


def write_bundle(root: Path, rows: tuple[str, ...] = ("live-backend", "workload-cpu-saturation"), bpf_text: str = "bpf") -> Path:
    write_json(root / "matrix.json", {"schema": "zig-scheduler/vm-harness-matrix-index/v1", "rows": [{"scenario_id": row} for row in rows], "host_mutation": False, "release_eligible": False})
    for role in ("matrix-row", "rollback-proof", "cleanup-proof", "host-refusal-proof", "privacy-scan", "runner-substrate-proof", "runner-cleanliness-proof", "protected-environment-review"):
        write_json(root / f"{role}.json", {"schema": f"zig-scheduler/{role}/v1", "host_mutation": False, "release_eligible": False, "production_capacity_claim": False})
    _ = (root / "bpf.json").write_text(bpf_text + "\n")
    _ = (root / "daemon.jsonl").write_text('{"host_mutation": false}\n')
    manifest = root / "evidence-manifest.json"
    write_json(manifest, {"schema": "zig-scheduler/evidence-manifest/v1", "outcome": "PASS", "audit_id": "AUD-20990101T000000Z-compare", "rollback_id": "RB-compare", "vm_marker": {"path": "/run/zig-scheduler-vm-lab.marker", "present": True, "checked_by": "manual-vm-proof"}, "supported_tuple": "linux-6.12.0-x86_64-sched_ext-bpf-bpf_jit-btf-vm_lab_only", "bpf_metadata_or_skip": ref(root / "bpf.json", "bpf-metadata"), "matrix_manifest": ref(root / "matrix.json", "matrix-manifest"), "daemon_events": ref(root / "daemon.jsonl", "daemon-events"), "runner_substrate": ref(root / "runner-substrate-proof.json", "runner-substrate-proof"), "runner_cleanliness": ref(root / "runner-cleanliness-proof.json", "runner-cleanliness-proof"), "artifacts": [ref(root / f"{role}.json", role) for role in ("protected-environment-review", "matrix-row", "rollback-proof", "cleanup-proof", "host-refusal-proof", "privacy-scan")], "benchmark_provenance": {"status": "not_applicable", "reason": "comparison self-test", "applies_to_outcomes": ["SKIP", "REFUSE", "BLOCKED"]}, "privacy_scan": {"status": "PASS", "private_fields_found": False, "artifact_paths": [(root / "privacy-scan.json").as_posix()]}, "attestation": {"status": "pending-post-run-github-attestation", "workflow_uses": "actions/attest-build-provenance@v2", "verify_command": "gh attestation verify bundle --repo owner/repo", "retention_days": 30}, "required_sources": ["qa/evidence_bundle_compare_check.py"], "host_mutation": False, "release_eligible": False, "production_capacity_claim": False})
    return manifest


def expect_reject(left: Path, right: Path, label: str) -> None:
    try:
        compare(left, right)
    except BundleCompareError as exc:
        print(f"PASS reject {label}: {exc}")
        return
    raise BundleCompareError(f"expected rejection did not occur: {label}")


def self_test() -> None:
    root = Path("evidence/lab/evidence-bundle-compare-self-test")
    shutil.rmtree(root, ignore_errors=True)
    try:
        left = write_bundle(root / "left")
        right = write_bundle(root / "right")
        compare(left, right)
        print("PASS accept comparable protected evidence bundles")
        expect_reject(left, write_bundle(root / "row-mismatch", ("live-backend",)), "row set mismatch")
        expect_reject(left, write_bundle(root / "bpf-mismatch", bpf_text="changed-bpf"), "BPF hash mismatch")
        bad_claim = load_json(right)
        bad_claim["production_capacity_claim"] = True
        claim_path = root / "claim" / "evidence-manifest.json"
        write_json(claim_path, bad_claim)
        expect_reject(left, claim_path, "production claim")
    finally:
        shutil.rmtree(root, ignore_errors=True)
    print("PASS evidence bundle compare self-test")


def main(argv: list[str]) -> int:
    try:
        if argv == ["--self-test"]:
            self_test()
            return 0
        allow_tuple = "--allow-tuple-change" in argv
        allow_bpf = "--allow-bpf-change" in argv
        args = [arg for arg in argv if arg not in {"--allow-tuple-change", "--allow-bpf-change"}]
        if len(args) == 4 and args[0] == "--left" and args[2] == "--right":
            compare(Path(args[1]), Path(args[3]), allow_tuple_change=allow_tuple, allow_bpf_change=allow_bpf)
            print(f"PASS evidence bundle compare: {args[1]} {args[3]}")
            return 0
        raise BundleCompareError("usage: evidence_bundle_compare_check.py --self-test | --left <manifest> --right <manifest> [--allow-tuple-change] [--allow-bpf-change]")
    except (OSError, ManifestError, BundleCompareError) as exc:
        print(f"FAIL evidence bundle compare: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
