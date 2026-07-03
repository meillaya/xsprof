#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
# ─── How to run ───
# python3 qa/runner_cleanliness_proof_check.py --proof fixtures/runner-cleanliness-proof/valid/protected-clean-runner.json
# python3 qa/runner_cleanliness_proof_check.py --self-test
"""Validate runner-cleanliness-proof/v1 companion artifacts."""
from __future__ import annotations

import hashlib
import json
import re
import shutil
import sys
from pathlib import Path
from dataclasses import dataclass
from typing import Callable, Final, Literal, TypeAlias

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from qa.runner_substrate_proof_common import JsonObject, JsonValue, RunnerProofError, load_json_object

SCHEMA: Final[str] = "zig-scheduler/runner-cleanliness-proof/v1"
SCHEMA_PATH: Final[Path] = Path("schemas/control/runner-cleanliness-proof.v1.schema.json")
DEFAULT_FIXTURES: Final[Path] = Path("fixtures/runner-cleanliness-proof")
Mode: TypeAlias = Literal["proof", "fixtures", "self-test"]
SAFE_PATH_RE: Final[re.Pattern[str]] = re.compile(r"^(?!/)(?!.*(?:^|/)\.\.(?:/|$)).+$")
SHA_RE: Final[re.Pattern[str]] = re.compile(r"^[0-9a-f]{64}$")
RUN_URL_RE: Final[re.Pattern[str]] = re.compile(r"^https://github\.com/.+/actions/runs/[0-9]+$")
ROOT_FIELDS: Final[frozenset[str]] = frozenset(("schema", "proof_outcome", "run_url", "runner_identity", "cleanliness_mode", "no_reuse_evidence", "removal_receipt", "ephemeral_registration", "protected_review", "runner_substrate", "host_mutation", "release_eligible", "production_capacity_claim"))
IDENTITY_FIELDS: Final[frozenset[str]] = frozenset(("name", "group", "labels"))
MODE_FIELDS: Final[frozenset[str]] = frozenset(("kind", "jit_config_sha256", "clean_machine_boot_id", "ephemeral_instance_id"))
NO_REUSE_FIELDS: Final[frozenset[str]] = frozenset(("status", "previous_runner_id", "current_runner_id", "evidence"))
REMOVAL_FIELDS: Final[frozenset[str]] = frozenset(("status", "removed_at", "receipt_path", "sha256"))
REF_FIELDS: Final[frozenset[str]] = frozenset(("path", "sha256", "schema_role"))
EPHEMERAL_REGISTRATION_FIELDS: Final[frozenset[str]] = frozenset(("schema", "runner_id", "runner_name", "runner_labels", "ephemeral_instance_id", "ephemeral_runner_configured", "no_reuse_evidence", "run_url", "source_basename", "source_sha256", "source_size_bytes", "host_mutation", "release_eligible", "production_capacity_claim"))
@dataclass(frozen=True, slots=True)
class Args:
    mode: Mode
    proof: Path | None
    fixtures: Path


class RunnerCleanlinessError(Exception):
    """Raised when runner-cleanliness proof is malformed or unsafe."""


def parse_args(argv: list[str]) -> Args:
    if argv == ["--self-test"]:
        return Args("self-test", None, DEFAULT_FIXTURES)
    proof: Path | None = None
    fixtures = DEFAULT_FIXTURES
    mode: Mode = "fixtures"
    index = 0
    while index < len(argv):
        arg = argv[index]
        if arg == "--proof":
            index += 1
            if index >= len(argv):
                raise RunnerCleanlinessError("--proof requires a path")
            proof = Path(argv[index])
            mode = "proof"
        elif arg == "--fixtures":
            index += 1
            if index >= len(argv):
                raise RunnerCleanlinessError("--fixtures requires a path")
            fixtures = Path(argv[index])
            mode = "fixtures"
        else:
            raise RunnerCleanlinessError("usage: runner_cleanliness_proof_check.py --self-test | --proof <path> | --fixtures <dir>")
        index += 1
    return Args(mode, proof, fixtures)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RunnerCleanlinessError(message)


def only_fields(data: JsonObject, allowed: frozenset[str], context: str) -> None:
    extra = sorted(set(data) - allowed)
    require(not extra, f"{context} has unexpected fields: {', '.join(extra)}")


def text(value: JsonValue | None, context: str) -> str:
    if not isinstance(value, str) or value == "":
        raise RunnerCleanlinessError(f"{context} must be non-empty text")
    return value


def obj(value: JsonValue | None, context: str) -> JsonObject:
    if not isinstance(value, dict):
        raise RunnerCleanlinessError(f"{context} must be an object")
    return value


def safe_path(value: JsonValue | None, context: str) -> Path:
    raw = text(value, context)
    require(SAFE_PATH_RE.fullmatch(raw) is not None, f"{context} must be relative and non-traversing: {raw}")
    return Path(raw)


def sha_file(path: Path) -> str:
    try:
        return hashlib.sha256(path.read_bytes()).hexdigest()
    except FileNotFoundError as exc:
        raise RunnerCleanlinessError(f"missing referenced file: {path}") from exc


def validate_schema_file() -> None:
    schema = load_json_object(SCHEMA_PATH)
    require(schema.get("$id") == SCHEMA, "runner cleanliness schema $id mismatch")


def validate_ref(value: JsonValue | None, role: str, context: str) -> Path:
    ref = obj(value, context)
    only_fields(ref, REF_FIELDS, context)
    path = safe_path(ref.get("path"), f"{context}.path")
    digest = text(ref.get("sha256"), f"{context}.sha256")
    require(SHA_RE.fullmatch(digest) is not None, f"{context}.sha256 must be sha256 hex")
    require(sha_file(path) == digest, f"{context}.sha256 does not match {path}")
    require(ref.get("schema_role") == role, f"{context}.schema_role must be {role}")
    return path


def validate_mode(value: JsonValue | None, outcome: str) -> None:
    mode = obj(value, "cleanliness_mode")
    only_fields(mode, MODE_FIELDS, "cleanliness_mode")
    kind = text(mode.get("kind"), "cleanliness_mode.kind")
    require(kind in {"jit", "ephemeral", "clean_machine"}, "cleanliness_mode.kind unsupported")
    if outcome == "PASS":
        if kind == "jit":
            require(SHA_RE.fullmatch(text(mode.get("jit_config_sha256"), "cleanliness_mode.jit_config_sha256")) is not None, "JIT PASS requires config hash")
        elif kind == "ephemeral":
            _ = text(mode.get("ephemeral_instance_id"), "cleanliness_mode.ephemeral_instance_id")
        elif kind == "clean_machine":
            _ = text(mode.get("clean_machine_boot_id"), "cleanliness_mode.clean_machine_boot_id")


def validate_identity(value: JsonValue | None) -> None:
    identity = obj(value, "runner_identity")
    only_fields(identity, IDENTITY_FIELDS, "runner_identity")
    _ = text(identity.get("name"), "runner_identity.name")
    _ = text(identity.get("group"), "runner_identity.group")
    labels = identity.get("labels")
    if not isinstance(labels, list) or not labels:
        raise RunnerCleanlinessError("runner_identity.labels must be a non-empty list")
    for index, item in enumerate(labels):
        _ = text(item, f"runner_identity.labels[{index}]")


def validate_no_reuse(value: JsonValue | None, outcome: str) -> None:
    evidence = obj(value, "no_reuse_evidence")
    only_fields(evidence, NO_REUSE_FIELDS, "no_reuse_evidence")
    status = text(evidence.get("status"), "no_reuse_evidence.status")
    require(status in {"PASS", "SKIP", "REFUSE"}, "no_reuse_evidence.status unsupported")
    if outcome == "PASS":
        require(status == "PASS", "PASS proof requires no-reuse evidence PASS")
        previous_id = text(evidence.get("previous_runner_id"), "no_reuse_evidence.previous_runner_id")
        current_id = text(evidence.get("current_runner_id"), "no_reuse_evidence.current_runner_id")
        require(previous_id != current_id, "PASS proof requires a non-reused runner identity")
    _ = text(evidence.get("evidence"), "no_reuse_evidence.evidence")


def validate_removal(value: JsonValue | None, outcome: str, ephemeral_mode: bool) -> str:
    receipt = obj(value, "removal_receipt")
    only_fields(receipt, REMOVAL_FIELDS, "removal_receipt")
    status = text(receipt.get("status"), "removal_receipt.status")
    require(status in {"removed", "not_applicable", "unavailable"}, "removal_receipt.status unsupported")
    if outcome == "PASS":
        require(status == "removed" or (ephemeral_mode and status == "not_applicable"), "PASS proof requires runner removal receipt or validator-enforced ephemeral registration proof")
    if status == "removed":
        _ = text(receipt.get("removed_at"), "removal_receipt.removed_at")
        receipt_path = safe_path(receipt.get("receipt_path"), "removal_receipt.receipt_path")
        digest = text(receipt.get("sha256"), "removal_receipt.sha256")
        require(SHA_RE.fullmatch(digest) is not None, "removal_receipt.sha256 must be sha256 hex")
        require(sha_file(receipt_path) == digest, f"removal_receipt.sha256 does not match {receipt_path}")
    return status


def validate_ephemeral_registration(value: JsonValue | None, data: JsonObject, removal_status: str) -> None:
    mode = obj(data.get("cleanliness_mode"), "cleanliness_mode")
    ephemeral_pass = data.get("proof_outcome") == "PASS" and mode.get("kind") == "ephemeral" and removal_status == "not_applicable"
    if not ephemeral_pass:
        require(value is None, "ephemeral_registration is only allowed for PASS ephemeral cleanup without an in-job removal receipt")
        return
    receipt_path = validate_ref(value, "ephemeral-runner-registration-receipt", "ephemeral_registration")
    receipt = load_json_object(receipt_path)
    only_fields(receipt, EPHEMERAL_REGISTRATION_FIELDS, "ephemeral_registration receipt")
    require(receipt.get("schema") == "zig-scheduler/ephemeral-runner-registration-receipt/v1", "ephemeral_registration receipt schema mismatch")
    identity = obj(data.get("runner_identity"), "runner_identity")
    no_reuse = obj(data.get("no_reuse_evidence"), "no_reuse_evidence")
    require(receipt.get("runner_id") == no_reuse.get("current_runner_id"), "ephemeral_registration runner_id must match current runner id")
    require(receipt.get("runner_name") == identity.get("name"), "ephemeral_registration runner_name must match runner identity")
    require(receipt.get("ephemeral_instance_id") == mode.get("ephemeral_instance_id"), "ephemeral_registration instance id must match cleanliness mode")
    require(receipt.get("ephemeral_runner_configured") is True, "ephemeral_registration must prove ephemeral runner configuration")
    require(receipt.get("run_url") == data.get("run_url"), "ephemeral_registration run_url must match proof run_url")
    labels = receipt.get("runner_labels")
    require(isinstance(labels, list) and labels == identity.get("labels"), "ephemeral_registration labels must match runner identity")
    require(receipt.get("no_reuse_evidence") == no_reuse.get("evidence"), "ephemeral_registration no-reuse evidence must match proof")
    require(text(receipt.get("source_basename"), "ephemeral_registration.source_basename") == "zigsched-runner-registration-receipt.txt", "ephemeral_registration source basename unsupported")
    require(SHA_RE.fullmatch(text(receipt.get("source_sha256"), "ephemeral_registration.source_sha256")) is not None, "ephemeral_registration.source_sha256 must be sha256 hex")
    size = receipt.get("source_size_bytes")
    require(isinstance(size, int) and 0 < size <= 8192, "ephemeral_registration source size must be 1..8192 bytes")
    require(receipt.get("host_mutation") is False, "ephemeral_registration host_mutation must be false")
    require(receipt.get("release_eligible") is False, "ephemeral_registration release_eligible must be false")
    require(receipt.get("production_capacity_claim") is False, "ephemeral_registration production_capacity_claim must be false")


def validate_proof(path: Path) -> None:
    validate_schema_file()
    data = load_json_object(path)
    only_fields(data, ROOT_FIELDS, str(path))
    require(data.get("schema") == SCHEMA, "unsupported runner cleanliness schema")
    outcome = text(data.get("proof_outcome"), "proof_outcome")
    require(outcome in {"PASS", "SKIP", "REFUSE"}, "proof_outcome unsupported")
    require(data.get("host_mutation") is False, "host_mutation must be false")
    require(data.get("release_eligible") is False, "release_eligible must be false")
    require(data.get("production_capacity_claim") is False, "production_capacity_claim must be false")
    run_url = text(data.get("run_url"), "run_url")
    require(outcome != "PASS" or RUN_URL_RE.fullmatch(run_url) is not None, "PASS proof requires GitHub Actions run URL")
    validate_identity(data.get("runner_identity"))
    mode = obj(data.get("cleanliness_mode"), "cleanliness_mode")
    validate_mode(mode, outcome)
    validate_no_reuse(data.get("no_reuse_evidence"), outcome)
    removal_status = validate_removal(data.get("removal_receipt"), outcome, mode.get("kind") == "ephemeral")
    validate_ephemeral_registration(data.get("ephemeral_registration"), data, removal_status)
    validate_ref(data.get("protected_review"), "protected-environment-review", "protected_review")
    validate_ref(data.get("runner_substrate"), "runner-substrate-proof", "runner_substrate")



def validate_fixtures(root: Path) -> None:
    valid_paths = sorted((root / "valid").glob("*.json"))
    require(bool(valid_paths), f"missing valid runner cleanliness fixtures under {root / 'valid'}")
    for valid in valid_paths:
        validate_proof(valid)
        print(f"PASS runner cleanliness fixture: {valid}")
    invalid_root = root / "invalid"
    invalid_paths = sorted(invalid_root.glob("*.json"))
    require(bool(invalid_paths), f"missing invalid runner cleanliness fixtures under {invalid_root}")
    for invalid in invalid_paths:
        try:
            validate_proof(invalid)
        except (RunnerCleanlinessError, RunnerProofError) as exc:
            print(f"PASS reject invalid runner cleanliness fixture {invalid.name}: {exc}")
            continue
        raise RunnerCleanlinessError(f"expected invalid runner cleanliness fixture rejection: {invalid}")

def write_json(path: Path, value: JsonObject) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    _ = path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def artifact_ref(path: Path, role: str) -> JsonObject:
    return {"path": path.as_posix(), "sha256": sha_file(path), "schema_role": role}


def good_proof(root: Path) -> Path:
    receipt = root / "removal-receipt.txt"
    write_json(root / "protected-review.json", {"schema": "zig-scheduler/protected-environment-review/v1", "host_mutation": False, "release_eligible": False, "production_capacity_claim": False})
    write_json(root / "runner-substrate.json", {"schema": "zig-scheduler/runner-substrate-proof/v1", "host_mutation": False, "release_eligible": False, "production_capacity_claim": False})
    _ = receipt.write_text("runner removed from protected pool\n")
    proof = root / "runner-cleanliness.json"
    write_json(proof, {"schema": SCHEMA, "proof_outcome": "PASS", "run_url": "https://github.com/Meillaya/zig-scheduler/actions/runs/28560605183", "runner_identity": {"name": "zigsched-proof-001", "group": "vm-proof", "labels": ["self-hosted", "zig-scheduler-vm-proof", "disposable-vm"]}, "cleanliness_mode": {"kind": "jit", "jit_config_sha256": "a" * 64}, "no_reuse_evidence": {"status": "PASS", "previous_runner_id": "none", "current_runner_id": "runner-28560605183", "evidence": "runner registered for this run only"}, "removal_receipt": {"status": "removed", "removed_at": "2026-07-02T00:00:00Z", "receipt_path": receipt.as_posix(), "sha256": sha_file(receipt)}, "protected_review": artifact_ref(root / "protected-review.json", "protected-environment-review"), "runner_substrate": artifact_ref(root / "runner-substrate.json", "runner-substrate-proof"), "host_mutation": False, "release_eligible": False, "production_capacity_claim": False})
    return proof


def set_ephemeral_cleanup_not_applicable(data: JsonObject) -> None:
    data["cleanliness_mode"] = {"kind": "ephemeral", "ephemeral_instance_id": "runner-cleanliness-self-test"}
    data["removal_receipt"] = {"status": "not_applicable"}


def remove_ephemeral_registration(data: JsonObject) -> None:
    _ = data.pop("ephemeral_registration", None)


def set_no_reuse_current_id(data: JsonObject) -> None:
    obj(data.get("no_reuse_evidence"), "no_reuse")["current_runner_id"] = "none"


def set_removal_unavailable(data: JsonObject) -> None:
    obj(data.get("removal_receipt"), "removal")["status"] = "unavailable"


def remove_jit_config_hash(data: JsonObject) -> None:
    _ = obj(data.get("cleanliness_mode"), "mode").pop("jit_config_sha256", None)


def set_release_claim(data: JsonObject) -> None:
    data["release_eligible"] = True


def expect_reject(path: Path, label: str) -> None:
    try:
        validate_proof(path)
    except (RunnerCleanlinessError, RunnerProofError) as exc:
        print(f"PASS reject {label}: {exc}")
        return
    raise RunnerCleanlinessError(f"expected rejection did not occur: {label}")


def self_test() -> None:
    validate_fixtures(DEFAULT_FIXTURES)
    root = Path("evidence/lab/runner-cleanliness-self-test")
    shutil.rmtree(root, ignore_errors=True)
    root.mkdir(parents=True)
    try:
        proof = good_proof(root)
        validate_proof(proof)
        print("PASS accept runner cleanliness proof")
        ephemeral = load_json_object(proof)
        set_ephemeral_cleanup_not_applicable(ephemeral)
        registration = root / "runner-ephemeral-registration-receipt.json"
        write_json(registration, {"schema": "zig-scheduler/ephemeral-runner-registration-receipt/v1", "runner_id": "runner-28560605183", "runner_name": "zigsched-proof-001", "runner_labels": ["self-hosted", "zig-scheduler-vm-proof", "disposable-vm"], "ephemeral_instance_id": "runner-cleanliness-self-test", "ephemeral_runner_configured": True, "no_reuse_evidence": "runner registered for this run only", "run_url": "https://github.com/Meillaya/zig-scheduler/actions/runs/28560605183", "source_basename": "zigsched-runner-registration-receipt.txt", "source_sha256": "b" * 64, "source_size_bytes": 128, "host_mutation": False, "release_eligible": False, "production_capacity_claim": False})
        ephemeral["ephemeral_registration"] = artifact_ref(registration, "ephemeral-runner-registration-receipt")
        ephemeral_path = root / "ephemeral-not-applicable.json"
        write_json(ephemeral_path, ephemeral)
        validate_proof(ephemeral_path)
        print("PASS accept ephemeral runner cleanliness proof with registration-bound in-job cleanup")
        missing_ephemeral = load_json_object(ephemeral_path)
        remove_ephemeral_registration(missing_ephemeral)
        missing_ephemeral_path = root / "bad-ephemeral-registration.json"
        write_json(missing_ephemeral_path, missing_ephemeral)
        expect_reject(missing_ephemeral_path, "missing-ephemeral-registration")
        mutations: tuple[tuple[str, Callable[[JsonObject], None]], ...] = (
            ("reused-runner", set_no_reuse_current_id),
            ("missing-removal", set_removal_unavailable),
            ("labels-only", remove_jit_config_hash),
            ("release-claim", set_release_claim),
        )
        for label, mutate in mutations:
            bad = load_json_object(proof)
            mutate(bad)
            bad_path = root / f"bad-{label}.json"
            write_json(bad_path, bad)
            expect_reject(bad_path, label)
    finally:
        shutil.rmtree(root, ignore_errors=True)
    print("PASS runner cleanliness proof self-test")


def main(argv: list[str]) -> int:
    try:
        args = parse_args(argv)
        if args.mode == "self-test":
            self_test()
            return 0
        if args.mode == "proof" and args.proof is not None:
            validate_proof(args.proof)
            print(f"PASS runner cleanliness proof: {args.proof}")
            return 0
        validate_fixtures(args.fixtures)
        return 0
    except (OSError, RunnerProofError, RunnerCleanlinessError) as exc:
        print(f"FAIL runner cleanliness proof: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
