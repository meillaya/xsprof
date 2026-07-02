#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
# ─── How to run ───
# python3 qa/evidence_manifest_check.py --self-test
"""Self-test fixtures for evidence_manifest_check.py."""
from __future__ import annotations

from pathlib import Path
import sys
import json
import shutil
from typing import Final, Literal

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from qa.evidence_manifest_check import JsonObject, JsonValue, ManifestError, file_sha, load_json, validate_manifest

SCHEMA: Final[str] = "zig-scheduler/evidence-manifest/v1"
VM_MARKER: Final[str] = "/run/zig-scheduler-vm-lab.marker"
Mutator = Literal["missing-hash", "absolute-path", "traversing-path", "missing-marker", "missing-rollback", "missing-cleanup", "missing-host-refusal", "missing-protected-review", "host-mutation", "release-eligible", "production-claim", "untracked-source", "missing-attestation", "pass-benchmark-not-applicable", "refuse-benchmark-missing-outcome", "missing-outcome"]


def write_json(path: Path, data: JsonObject) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    _ = path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")


def ref(path: Path, role: str) -> JsonObject:
    return {"path": path.as_posix(), "sha256": file_sha(path), "schema_role": role}


def write_artifacts(root: Path) -> tuple[Path, Path, Path, Path, Path, Path, Path]:
    rows = root / "rows" / "fixture-pass"
    for name in ("matrix-run", "rollback-proof", "cleanup-proof", "host-refusal", "privacy-scan", "benchmark", "runner-substrate-proof", "protected-environment-review"):
        write_json(rows / f"{name}.json", {"schema": f"zig-scheduler/{name}/v1", "host_mutation": False, "release_eligible": False, "production_capacity_claim": False})
    write_json(
        rows / "protected-environment-review.json",
        {
            "schema": "zig-scheduler/protected-environment-review/v1",
            "run_id": "28539973410",
            "run_url": "https://github.com/Meillaya/zig-scheduler/actions/runs/28539973410",
            "head_sha": "4891192518cda2b63f37ce20863b7fabfc4ceb7d",
            "environment_name": "vm-proof-manual",
            "environment_id": 17499459504,
            "reviewer_status": "approved",
            "reviewer_identity": "Meillaya",
            "reviewer_id": 105596849,
            "comment": "manual protected VM proof only; not release approval",
            "review_history_api_url": "https://api.github.com/repos/Meillaya/zig-scheduler/actions/runs/28539973410/approvals",
            "collected_at": "2026-07-01T18:45:49Z",
            "host_mutation": False,
            "release_eligible": False,
            "production_capacity_claim": False,
        },
    )
    write_json(
        rows / "runner-substrate-proof.json",
        {
            "schema": "zig-scheduler/runner-substrate-proof/v1",
            "host_mutation": False,
            "release_eligible": False,
            "production_capacity_claim": False,
            "protected_environment": {
                "name": "vm-proof-manual",
                "reviewer_gate": "required",
            },
        },
    )
    log = root / "static-logs" / "matrix.log"
    log.parent.mkdir(parents=True, exist_ok=True)
    _ = log.write_text("static verification logs\n")
    daemon = root / "daemon-events.jsonl"
    _ = daemon.write_text(json.dumps({"schema": "zig-scheduler/daemon-event/v1", "host_mutation": False}) + "\n")
    bpf = root / "bpf.skip.json"
    write_json(bpf, {"schema": "zig-scheduler/bpf-skip/v1", "host_mutation": False})
    manifest = root / "manifest.json"
    write_json(manifest, {"schema": "zig-scheduler/vm-harness-matrix-index/v1", "host_mutation": False, "release_eligible": False})
    return rows, log, daemon, bpf, manifest, rows / "runner-substrate-proof.json", rows / "protected-environment-review.json"


def good_manifest(root: Path, *, outcome: str = "PASS", benchmark_applicable: bool = True) -> Path:
    rows, log, daemon, bpf, manifest, runner, review = write_artifacts(root)
    out = root / "evidence-manifest.json"
    benchmark: JsonValue = [ref(rows / "benchmark.json", "benchmark-provenance")]
    if not benchmark_applicable:
        benchmark = {"status": "not_applicable", "reason": "live proof refused before benchmark artifacts were produced", "applies_to_outcomes": ["SKIP", "REFUSE", "BLOCKED"]}
    marker_present = outcome == "PASS"
    write_json(out, {"schema": SCHEMA, "outcome": outcome, "audit_id": "AUD-20990101T000000Z-deadbee-abc123", "rollback_id": "RB-demo", "vm_marker": {"path": VM_MARKER, "present": marker_present, "checked_by": "manual-vm-proof"}, "supported_tuple": "linux-6.12.0-x86_64-sched_ext-bpf-bpf_jit-btf-vm_lab_only", "bpf_metadata_or_skip": ref(bpf, "bpf-skip-json"), "matrix_manifest": ref(manifest, "matrix-manifest"), "daemon_events": ref(daemon, "daemon-events"), "runner_substrate": ref(runner, "runner-substrate-proof"), "artifacts": [ref(review, "protected-environment-review"), ref(rows / "matrix-run.json", "matrix-row"), ref(rows / "rollback-proof.json", "rollback-proof"), ref(rows / "cleanup-proof.json", "cleanup-proof"), ref(rows / "host-refusal.json", "host-refusal-proof"), ref(rows / "privacy-scan.json", "privacy-scan"), ref(log, "static-verification-log")], "benchmark_provenance": benchmark, "privacy_scan": {"status": "PASS", "private_fields_found": False, "artifact_paths": [(rows / "privacy-scan.json").as_posix()]}, "attestation": {"status": "pending-post-run-github-attestation", "workflow_uses": "actions/attest-build-provenance@v2", "verify_command": "gh attestation verify evidence/lab/manual-vm-proof/vm-proof-bundle.tar.zst --repo owner/repo", "retention_days": 30}, "required_sources": ["qa/manual_vm_proof_ci_check.py", ".github/workflows/manual-vm-proof.yml"], "host_mutation": False, "release_eligible": False, "production_capacity_claim": False})
    return out


def without_role(data: JsonObject, role: str) -> list[JsonValue]:
    artifacts = data.get("artifacts")
    if not isinstance(artifacts, list):
        return []
    return [item for item in artifacts if not (isinstance(item, dict) and item.get("schema_role") == role)]


def mutate(data: JsonObject, mutator: Mutator) -> None:
    matrix_manifest = data.get("matrix_manifest")
    match mutator:  # noqa: MATCH_OK -- Mutator Literal cases are exhaustively listed below.
        case "missing-hash":
            if isinstance(matrix_manifest, dict):
                del matrix_manifest["sha256"]
        case "absolute-path":
            if isinstance(matrix_manifest, dict):
                matrix_manifest["path"] = "/tmp/manifest.json"
        case "traversing-path":
            if isinstance(matrix_manifest, dict):
                matrix_manifest["path"] = "evidence/../manifest.json"
        case "missing-outcome":
            del data["outcome"]
        case "missing-marker":
            data["vm_marker"] = {"path": VM_MARKER, "present": False, "checked_by": "manual-vm-proof"}
        case "missing-rollback":
            data["artifacts"] = without_role(data, "rollback-proof")
        case "missing-cleanup":
            data["artifacts"] = without_role(data, "cleanup-proof")
        case "missing-host-refusal":
            data["artifacts"] = without_role(data, "host-refusal-proof")
        case "missing-protected-review":
            data["artifacts"] = without_role(data, "protected-environment-review")
        case "host-mutation":
            data["host_mutation"] = True
        case "release-eligible":
            data["release_eligible"] = True
        case "production-claim":
            data["production_capacity_claim"] = True
        case "untracked-source":
            data["required_sources"] = ["qa/not-tracked-required-source.py"]
        case "missing-attestation":
            data["attestation"] = {"status": "pending-post-run-github-attestation"}
        case "pass-benchmark-not-applicable":
            data["benchmark_provenance"] = {"status": "not_applicable", "reason": "PASS cannot skip benchmarks", "applies_to_outcomes": ["REFUSE"]}
        case "refuse-benchmark-missing-outcome":
            data["outcome"] = "REFUSE"
            data["benchmark_provenance"] = {"status": "not_applicable", "reason": "refused before benchmarks", "applies_to_outcomes": ["SKIP"]}


def expect_reject(path: Path, schema: Path, label: str, mutator: Mutator) -> None:
    data = load_json(path)
    mutate(data, mutator)
    bad = path.with_name(f"bad-{mutator}.json")
    write_json(bad, data)
    try:
        validate_manifest(bad, schema)
    except ManifestError as exc:
        print(f"PASS reject {label}: {exc}")
        return
    raise ManifestError(f"expected rejection did not occur: {label}")


def update_artifact_hash(data: JsonObject, role: str, path: Path) -> None:
    artifacts = data.get("artifacts")
    if not isinstance(artifacts, list):
        raise ManifestError("self-test fixture missing artifacts")
    for item in artifacts:
        if isinstance(item, dict) and item.get("schema_role") == role:
            item["sha256"] = file_sha(path)
            return
    raise ManifestError(f"self-test fixture missing artifact role: {role}")


def expect_privacy_key_reject(path: Path, schema: Path, key: str) -> None:
    data = load_json(path)
    privacy_artifact = path.parent / "rows" / "fixture-pass" / "privacy-scan.json"
    privacy_data = load_json(privacy_artifact)
    privacy_data[key] = "secret-token"
    write_json(privacy_artifact, privacy_data)
    update_artifact_hash(data, "privacy-scan", privacy_artifact)
    bad = path.with_name(f"bad-privacy-{key}.json")
    write_json(bad, data)
    try:
        validate_manifest(bad, schema)
    except ManifestError as exc:
        print(f"PASS reject privacy key {key}: {exc}")
        return
    raise ManifestError(f"expected rejection did not occur: privacy key {key}")


def expect_static_log_privacy_reject(path: Path, schema: Path) -> None:
    data = load_json(path)
    log = path.parent / "static-logs" / "matrix.log"
    _ = log.write_text("static verification logs\nPassword=leaked-secret\n")
    update_artifact_hash(data, "static-verification-log", log)
    bad = path.with_name("bad-static-log-secret.json")
    write_json(bad, data)
    try:
        validate_manifest(bad, schema)
    except ManifestError as exc:
        print(f"PASS reject static log secret: {exc}")
        return
    raise ManifestError("expected rejection did not occur: static log secret")


def expect_corrupt_protected_review_reject(path: Path, schema: Path) -> None:
    data = load_json(path)
    review_artifact = path.parent / "rows" / "fixture-pass" / "protected-environment-review.json"
    review_data = load_json(review_artifact)
    review_data["reviewer_status"] = "pending"
    write_json(review_artifact, review_data)
    update_artifact_hash(data, "protected-environment-review", review_artifact)
    bad = path.with_name("bad-protected-review-corrupt-hash-updated.json")
    write_json(bad, data)
    try:
        validate_manifest(bad, schema)
    except ManifestError as exc:
        print(f"PASS reject corrupt protected review with updated hash: {exc}")
        return
    raise ManifestError("expected rejection did not occur: corrupt protected review with updated hash")


def run_self_test(schema: Path) -> None:
    root = Path("evidence/lab/evidence-manifest-self-test")
    shutil.rmtree(root, ignore_errors=True)
    good = good_manifest(root)
    validate_manifest(good, schema)
    print("PASS accept complete evidence manifest")
    refuse = good_manifest(root / "refuse-na", outcome="REFUSE", benchmark_applicable=False)
    validate_manifest(refuse, schema)
    print("PASS accept REFUSE evidence manifest with benchmark_provenance not_applicable")
    cases: tuple[tuple[str, Mutator], ...] = (("missing hash", "missing-hash"), ("absolute path", "absolute-path"), ("traversing path", "traversing-path"), ("missing outcome", "missing-outcome"), ("missing VM marker", "missing-marker"), ("missing rollback proof", "missing-rollback"), ("missing cleanup proof", "missing-cleanup"), ("missing host refusal proof", "missing-host-refusal"), ("missing protected review proof", "missing-protected-review"), ("host_mutation=true", "host-mutation"), ("release_eligible=true", "release-eligible"), ("production_capacity_claim=true", "production-claim"), ("untracked required source", "untracked-source"), ("missing attestation/provenance fields", "missing-attestation"), ("PASS benchmark_provenance not_applicable", "pass-benchmark-not-applicable"), ("REFUSE benchmark_provenance missing outcome", "refuse-benchmark-missing-outcome"))
    for label, mutator in cases:
        expect_reject(good, schema, label, mutator)
    expect_corrupt_protected_review_reject(good_manifest(root / "protected-review-corrupt"), schema)
    privacy_cases: tuple[str, ...] = ("accessToken", "commandLine", "rawDebug", "githubAccessToken", "privateCommandLine", "Password=secret", "environment")
    for key in privacy_cases:
        expect_privacy_key_reject(good_manifest(root / f"privacy-{key}"), schema, key)
    expect_static_log_privacy_reject(good_manifest(root / "static-log-secret"), schema)
    shutil.rmtree(root, ignore_errors=True)
    print("PASS evidence manifest self-test: provenance, hashes, paths, VM marker, rollback, cleanup, host refusal, protected review normalization, compound privacy keys, case-variant text privacy, flags, tracked sources, and attestation rejected when unsafe")


def parse_args(argv: list[str]) -> Path:
    if len(argv) == 2 and argv[0] == "--schema":
        return Path(argv[1])
    if not argv:
        return Path("schemas/control/evidence-manifest.v1.schema.json")
    raise ManifestError("usage: evidence_manifest_selftest.py [--schema <path>]")


def main(argv: list[str]) -> int:
    try:
        run_self_test(parse_args(argv))
        return 0
    except ManifestError as exc:
        print(f"FAIL evidence manifest self-test: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
