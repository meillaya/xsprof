#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
# ─── How to run ───
# python3 qa/runner_substrate_proof_check.py --proof fixtures/runner-substrate-proof/valid/protected-runner.json --schema schemas/control/runner-substrate-proof.v1.schema.json
# python3 qa/runner_substrate_proof_check.py --fixtures fixtures/runner-substrate-proof --schema schemas/control/runner-substrate-proof.v1.schema.json
# python3 qa/runner_substrate_proof_check.py --self-test
"""Validate protected runner substrate proof artifacts for manual VM proof runs."""
# noqa: SIZE_OK — this boundary validator intentionally keeps runner, protected-review, and substrate cross-checks together.
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import hashlib, re, sys
from typing import Final, Literal, TypeAlias

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from qa.protected_environment_review_check import (
    DEFAULT_SCHEMA as PROTECTED_REVIEW_SCHEMA,
    ProtectedReviewError,
    validate_proof as validate_normalized_protected_review,
)
from qa.runner_substrate_proof_common import JsonObject, JsonValue, RunnerProofError, load_json_object
Mode: TypeAlias = Literal["proof", "fixtures", "self-test"]
Outcome: TypeAlias = Literal["PASS", "SKIP", "REFUSE"]

SCHEMA: Final[str] = "zig-scheduler/runner-substrate-proof/v1"
DEFAULT_SCHEMA: Final[Path] = Path("schemas/control/runner-substrate-proof.v1.schema.json")
DEFAULT_FIXTURES: Final[Path] = Path("fixtures/runner-substrate-proof")
SAFE_PATH_RE: Final[re.Pattern[str]] = re.compile(r"^(?!/)(?!.*(?:^|/)\.\.(?:/|$)).+$")
SHA_RE: Final[re.Pattern[str]] = re.compile(r"^[0-9a-f]{64}$")
RUN_URL_RE: Final[re.Pattern[str]] = re.compile(r"^https://github\.com/.+/actions/runs/[0-9]+$")
RUN_URL_UNAVAILABLE: Final[str] = "unavailable"
TUPLE_RE: Final[re.Pattern[str]] = re.compile(r"^linux-(?P<release>6\.(1[2-9]|[2-9][0-9])([.]\d+)?|7\.1\.1-2-cachyos)-x86_64-sched_ext-bpf-bpf_jit-btf-vm_lab_only$")
PLACEHOLDER_SHA_VALUES: Final[frozenset[str]] = frozenset(("0" * 64, "1" * 64))
REQUIRED_LABELS: Final[frozenset[str]] = frozenset(("self-hosted", "zig-scheduler-vm-proof", "disposable-vm"))
ROOT_FIELDS: Final[frozenset[str]] = frozenset(("schema", "proof_outcome", "runner", "protected_environment", "protected_review", "qemu", "dev_kvm", "accel_mode", "kernel_tuple", "bpf_metadata", "attestation", "unavailable_reasons", "host_mutation", "release_eligible", "production_capacity_claim"))
RUNNER_FIELDS: Final[frozenset[str]] = frozenset(("class", "group", "labels", "name", "os", "arch"))
ENV_FIELDS: Final[frozenset[str]] = frozenset(("name", "protected", "required_reviewers", "reviewer_status", "reviewer_identity", "unavailable_reason", "run_url"))
STATUS_PATH_FIELDS: Final[frozenset[str]] = frozenset(("path", "version", "status", "unavailable_reason"))
KERNEL_FIELDS: Final[frozenset[str]] = frozenset(("supported_tuple", "release", "arch", "config_sha256", "btf_available", "sched_ext_available"))
REF_FIELDS: Final[frozenset[str]] = frozenset(("path", "sha256", "schema_role", "unavailable_reason"))
PROTECTED_REVIEW_ROLE: Final[str] = "protected-environment-review"
ATTEST_FIELDS: Final[frozenset[str]] = frozenset(("capability", "status", "workflow_uses", "verify_command", "unavailable_reason"))


@dataclass(frozen=True, slots=True)
class Args:
    mode: Mode
    proof: Path | None
    fixtures: Path
    schema: Path


def parse_args(argv: list[str]) -> Args:
    if argv == ["--self-test"]:
        return Args("self-test", None, DEFAULT_FIXTURES, DEFAULT_SCHEMA)
    proof: Path | None = None
    fixtures = DEFAULT_FIXTURES
    schema = DEFAULT_SCHEMA
    mode: Mode = "fixtures"
    index = 0
    while index < len(argv):
        arg = argv[index]
        if arg == "--proof":
            index += 1
            if index >= len(argv):
                raise RunnerProofError("--proof requires a path")
            proof = Path(argv[index])
            mode = "proof"
        elif arg == "--fixtures":
            index += 1
            if index >= len(argv):
                raise RunnerProofError("--fixtures requires a path")
            fixtures = Path(argv[index])
            mode = "fixtures"
        elif arg == "--schema":
            index += 1
            if index >= len(argv):
                raise RunnerProofError("--schema requires a path")
            schema = Path(argv[index])
        else:
            raise RunnerProofError("usage: runner_substrate_proof_check.py --self-test | --proof <path> [--schema <path>] | [--fixtures <dir>] [--schema <path>]")
        index += 1
    return Args(mode, proof, fixtures, schema)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RunnerProofError(message)


def only_fields(row: JsonObject, allowed: frozenset[str], context: str) -> None:
    extra = sorted(set(row) - allowed)
    require(not extra, f"{context} has unexpected fields: {', '.join(extra)}")


def text(value: JsonValue | None, context: str) -> str:
    if not isinstance(value, str) or value == "":
        raise RunnerProofError(f"{context} must be non-empty text")
    return value


def bool_field(value: JsonValue | None, context: str) -> bool:
    if not isinstance(value, bool):
        raise RunnerProofError(f"{context} must be bool")
    return value


def safe_path(value: JsonValue | None, context: str) -> Path:
    raw = text(value, context)
    require(SAFE_PATH_RE.fullmatch(raw) is not None, f"{context} must be relative and non-traversing: {raw}")
    return Path(raw)


def digest(path: Path) -> str:
    try:
        return hashlib.sha256(path.read_bytes()).hexdigest()
    except FileNotFoundError as exc:
        raise RunnerProofError(f"missing referenced file: {path}") from exc


def enum_text(value: JsonValue | None, allowed: frozenset[str], context: str) -> str:
    raw = text(value, context)
    require(raw in allowed, f"{context} has unsupported value: {raw}")
    return raw


def strings(value: JsonValue | None, context: str) -> tuple[str, ...]:
    if not isinstance(value, list) or not value:
        raise RunnerProofError(f"{context} must be a non-empty list")
    return tuple(text(item, f"{context}[{index}]") for index, item in enumerate(value))


def object_field(data: JsonObject, field: str, context: str) -> JsonObject:
    value = data.get(field)
    if not isinstance(value, dict):
        raise RunnerProofError(f"{context}.{field} must be an object")
    return value


def validate_schema_file(path: Path) -> None:
    schema = load_json_object(path)
    require(schema.get("$id") == SCHEMA, "runner substrate schema $id mismatch")


def validate_runner(data: JsonObject, outcome: Outcome) -> None:
    runner = object_field(data, "runner", "proof")
    only_fields(runner, RUNNER_FIELDS, "runner")
    require(enum_text(runner.get("class"), frozenset(("self-hosted", "unknown")), "runner.class") == "self-hosted", "runner.class must be self-hosted for protected proof")
    labels = frozenset(strings(runner.get("labels"), "runner.labels"))
    missing = sorted(REQUIRED_LABELS - labels)
    require(not missing, "runner.labels missing protected labels: " + ", ".join(missing))
    if outcome == "PASS":
        _ = text(runner.get("group"), "runner.group")
        _ = text(runner.get("name"), "runner.name")
    _ = text(runner.get("os"), "runner.os")
    _ = text(runner.get("arch"), "runner.arch")


def validate_environment(data: JsonObject, outcome: Outcome) -> None:
    env = object_field(data, "protected_environment", "proof")
    only_fields(env, ENV_FIELDS, "protected_environment")
    require(env.get("name") == "vm-proof-manual", "protected_environment.name must be vm-proof-manual")
    require(env.get("protected") is True, "protected_environment.protected must be true")
    _ = text(env.get("required_reviewers"), "protected_environment.required_reviewers")
    status_raw = enum_text(env.get("reviewer_status"), frozenset(("approved", "not_exposed_by_github_actions_runtime", "unavailable")), "protected_environment.reviewer_status")
    run_url = text(env.get("run_url"), "protected_environment.run_url")
    if run_url == RUN_URL_UNAVAILABLE:
        require(outcome != "PASS", "PASS proof requires a GitHub Actions run URL")
        require(status_raw != "approved", "approved reviewer proof requires a GitHub Actions run URL")
    else:
        require(RUN_URL_RE.fullmatch(run_url) is not None, "protected_environment.run_url must be a GitHub Actions run URL or unavailable for SKIP/REFUSE")
    if status_raw == "approved":
        _ = text(env.get("reviewer_identity"), "protected_environment.reviewer_identity")
    else:
        _ = text(env.get("unavailable_reason"), "protected_environment.unavailable_reason")
        require(outcome != "PASS", "PASS proof requires explicit protected environment reviewer approval")



def validate_protected_review(data: JsonObject, outcome: Outcome) -> None:
    ref = object_field(data, "protected_review", "proof")
    only_fields(ref, REF_FIELDS, "protected_review")
    path = safe_path(ref.get("path"), "protected_review.path")
    sha = text(ref.get("sha256"), "protected_review.sha256")
    require(SHA_RE.fullmatch(sha) is not None, "protected_review.sha256 must be sha256 hex")
    require(digest(path) == sha, f"protected_review.sha256 does not match {path}")
    role = enum_text(ref.get("schema_role"), frozenset((PROTECTED_REVIEW_ROLE,)), "protected_review.schema_role")
    require(role == PROTECTED_REVIEW_ROLE, "protected_review.schema_role must be protected-environment-review")
    try:
        validate_normalized_protected_review(path, PROTECTED_REVIEW_SCHEMA)
    except ProtectedReviewError as exc:
        raise RunnerProofError(f"protected_review artifact is not normalized proof: {exc}") from exc
    review = load_json_object(path)
    env = object_field(data, "protected_environment", "proof")
    if review.get("run_url") != env.get("run_url") or review.get("reviewer_identity") != env.get("reviewer_identity"):
        _ = text(ref.get("unavailable_reason"), "protected_review.unavailable_reason")
        require(outcome != "PASS", "PASS proof requires protected review artifact to match runner proof")

def validate_status_path(data: JsonObject, field: str) -> str:
    value = object_field(data, field, "proof")
    only_fields(value, STATUS_PATH_FIELDS, field)
    _ = safe_path(value.get("path"), f"{field}.path")
    status = enum_text(value.get("status"), frozenset(("available", "unavailable")), f"{field}.status")
    if status == "available" and field == "qemu":
        _ = text(value.get("version"), "qemu.version")
    if status == "unavailable":
        _ = text(value.get("unavailable_reason"), f"{field}.unavailable_reason")
    return status


def validate_kernel(data: JsonObject, outcome: Outcome, reasons: tuple[str, ...]) -> None:
    kernel = object_field(data, "kernel_tuple", "proof")
    only_fields(kernel, KERNEL_FIELDS, "kernel_tuple")
    tuple_match = TUPLE_RE.fullmatch(text(kernel.get("supported_tuple"), "kernel_tuple.supported_tuple"))
    require(tuple_match is not None, "kernel_tuple.supported_tuple is unsupported")
    release = text(kernel.get("release"), "kernel_tuple.release")
    require(kernel.get("arch") == "x86_64", "kernel_tuple.arch must be x86_64")
    config_sha = text(kernel.get("config_sha256"), "kernel_tuple.config_sha256")
    require(SHA_RE.fullmatch(config_sha) is not None, "kernel_tuple.config_sha256 must be sha256 hex")
    config_unavailable = "kernel config metadata unavailable or placeholder" in reasons
    require(config_sha not in PLACEHOLDER_SHA_VALUES or (outcome != "PASS" and config_unavailable), "kernel_tuple.config_sha256 placeholder metadata requires SKIP/REFUSE unavailable reason")
    btf_available = bool_field(kernel.get("btf_available"), "kernel_tuple.btf_available")
    sched_ext_available = bool_field(kernel.get("sched_ext_available"), "kernel_tuple.sched_ext_available")
    if outcome == "PASS":
        assert tuple_match is not None
        expected_release = tuple_match.group("release")
        require(release.startswith(expected_release), "PASS proof kernel release must match supported_tuple")
        require(btf_available, "PASS proof requires kernel BTF availability")
        require(sched_ext_available, "PASS proof requires sched_ext availability")


def validate_bpf(data: JsonObject, outcome: Outcome) -> None:
    bpf = object_field(data, "bpf_metadata", "proof")
    only_fields(bpf, REF_FIELDS, "bpf_metadata")
    path = safe_path(bpf.get("path"), "bpf_metadata.path")
    sha = text(bpf.get("sha256"), "bpf_metadata.sha256")
    require(SHA_RE.fullmatch(sha) is not None, "bpf_metadata.sha256 must be sha256 hex")
    require(digest(path) == sha, f"bpf_metadata.sha256 does not match {path}")
    role = enum_text(bpf.get("schema_role"), frozenset(("bpf-metadata", "bpf-skip-json")), "bpf_metadata.schema_role")
    if role == "bpf-skip-json":
        _ = text(bpf.get("unavailable_reason"), "bpf_metadata.unavailable_reason")
        require(outcome != "PASS", "PASS proof requires BPF object metadata")


def validate_attestation(data: JsonObject, outcome: Outcome) -> None:
    att = object_field(data, "attestation", "proof")
    only_fields(att, ATTEST_FIELDS, "attestation")
    capability = enum_text(att.get("capability"), frozenset(("available", "unavailable")), "attestation.capability")
    status = enum_text(att.get("status"), frozenset(("pending-post-run-github-attestation", "verified-by-operator", "unavailable")), "attestation.status")
    require(text(att.get("workflow_uses"), "attestation.workflow_uses").startswith("actions/attest-build-provenance"), "attestation.workflow_uses must use actions/attest-build-provenance")
    require("gh attestation verify" in text(att.get("verify_command"), "attestation.verify_command"), "attestation.verify_command must document gh attestation verify")
    if capability == "unavailable" or status == "unavailable":
        _ = text(att.get("unavailable_reason"), "attestation.unavailable_reason")
        require(outcome != "PASS", "attestation unavailable cannot accompany PASS proof")


def validate_proof(path: Path, schema_path: Path) -> None:
    validate_schema_file(schema_path)
    data = load_json_object(path)
    only_fields(data, ROOT_FIELDS, str(path))
    require(data.get("schema") == SCHEMA, "unsupported runner substrate schema")
    require(data.get("host_mutation") is False, "proof.host_mutation must be false")
    require(data.get("release_eligible") is False, "proof.release_eligible must be false")
    require(data.get("production_capacity_claim") is False, "proof.production_capacity_claim must be false")
    outcome_raw = enum_text(data.get("proof_outcome"), frozenset(("PASS", "SKIP", "REFUSE")), "proof_outcome")
    outcome: Outcome = "PASS" if outcome_raw == "PASS" else "SKIP" if outcome_raw == "SKIP" else "REFUSE"
    validate_runner(data, outcome)
    validate_environment(data, outcome)
    validate_protected_review(data, outcome)
    qemu_status = validate_status_path(data, "qemu")
    kvm_status = validate_status_path(data, "dev_kvm")
    accel = enum_text(data.get("accel_mode"), frozenset(("kvm", "tcg", "unavailable")), "accel_mode")
    require(accel != "kvm" or (qemu_status == "available" and kvm_status == "available"), "accel_mode=kvm requires available qemu and /dev/kvm")
    require(outcome != "PASS" or (qemu_status == "available" and kvm_status == "available"), "PASS proof requires qemu and /dev/kvm availability")
    require(outcome != "PASS" or accel == "kvm", "PASS proof requires accel_mode=kvm")
    reasons_value = data.get("unavailable_reasons")
    if not isinstance(reasons_value, list):
        raise RunnerProofError("unavailable_reasons must be a list")
    reasons_list: list[JsonValue] = reasons_value
    reasons = () if outcome == "PASS" else strings(reasons_list, "unavailable_reasons")
    require(outcome != "PASS" or len(reasons_list) == 0, "PASS proof must not carry unavailable reasons")
    require(outcome == "PASS" or len(reasons) > 0, "SKIP/REFUSE proof must explain unavailable reasons")
    validate_kernel(data, outcome, reasons)
    validate_bpf(data, outcome)
    validate_attestation(data, outcome)


def validate_fixtures(root: Path, schema: Path) -> None:
    valid_paths = sorted(path for path in (root / "valid").glob("*.json") if path.name not in {"bpf-meta.json", "protected-review.json"})
    require(bool(valid_paths), f"missing valid runner substrate fixtures under {root / 'valid'}")
    for valid in valid_paths:
        validate_proof(valid, schema)
        print(f"PASS runner substrate fixture: {valid}")
    invalid_root = root / "invalid"
    invalid_paths = sorted(invalid_root.glob("*.json"))
    require(bool(invalid_paths), f"missing invalid runner substrate fixtures under {invalid_root}")
    for invalid in invalid_paths:
        try:
            validate_proof(invalid, schema)
        except RunnerProofError as exc:
            print(f"PASS reject invalid runner substrate fixture {invalid.name}: {exc}")
            continue
        raise RunnerProofError(f"expected invalid runner substrate fixture rejection: {invalid}")


def run_self_test(schema: Path) -> None:
    from qa.runner_substrate_proof_selftest import run_self_test as run

    run(schema, validate_fixtures=validate_fixtures, validate_proof=validate_proof, load_json=load_json_object)


def main(argv: list[str]) -> int:
    try:
        args = parse_args(argv)
        if args.mode == "self-test":
            run_self_test(args.schema)
        elif args.mode == "proof" and args.proof is not None:
            validate_proof(args.proof, args.schema)
            print(f"PASS runner substrate proof: {args.proof}")
        else:
            validate_fixtures(args.fixtures, args.schema)
        return 0
    except RunnerProofError as exc:
        print(f"FAIL runner substrate proof: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
