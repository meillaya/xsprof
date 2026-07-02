#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
# ─── How to run ───
# python3 qa/runner_substrate_proof_check.py --self-test
"""Self-test fixtures for runner_substrate_proof_check.py."""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import copy
import hashlib
import json
import shutil
import subprocess
import sys
from typing import Callable, Final, Literal, TypeAlias

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from qa.runner_substrate_proof_common import JsonObject, RunnerProofError
LoadJson: TypeAlias = Callable[[Path], JsonObject]
ValidateProof: TypeAlias = Callable[[Path, Path], None]
ValidateFixtures: TypeAlias = Callable[[Path, Path], None]

DEFAULT_FIXTURES: Final[Path] = Path("fixtures/runner-substrate-proof")

MutatorName = Literal[
    "missing-dev-kvm-status",
    "absolute-path",
    "missing-protected-environment",
    "missing-protected-review",
    "protected-review-hash-mismatch",
    "protected-review-role-mismatch",
    "release-claim",
    "production-claim",
    "fake-attestation-pass",
    "empty-qemu-version-pass",
    "missing-runner-group-pass",
    "missing-runner-name-pass",
]


@dataclass(frozen=True, slots=True)
class RejectContext:
    good: Path
    schema: Path
    root: Path
    load_json: LoadJson
    validate_proof: ValidateProof


def mutate(data: JsonObject, name: MutatorName) -> None:
    match name:
        case "missing-dev-kvm-status":
            dev_kvm = data.get("dev_kvm")
            if isinstance(dev_kvm, dict):
                del dev_kvm["status"]
        case "absolute-path":
            qemu = data.get("qemu")
            if isinstance(qemu, dict):
                qemu["path"] = "/usr/bin/qemu-system-x86_64"
        case "missing-protected-environment":
            del data["protected_environment"]
        case "missing-protected-review":
            del data["protected_review"]
        case "protected-review-hash-mismatch":
            protected_review = data.get("protected_review")
            if isinstance(protected_review, dict):
                protected_review["sha256"] = "0" * 64
        case "protected-review-role-mismatch":
            protected_review = data.get("protected_review")
            if isinstance(protected_review, dict):
                protected_review["schema_role"] = "runner-substrate-proof"
        case "release-claim":
            data["release_eligible"] = True
        case "production-claim":
            data["production_capacity_claim"] = True
        case "fake-attestation-pass":
            att = data.get("attestation")
            if isinstance(att, dict):
                att["status"] = "PASS"
        case "empty-qemu-version-pass":
            qemu = data.get("qemu")
            if isinstance(qemu, dict):
                qemu["version"] = ""
        case "missing-runner-group-pass":
            runner = data.get("runner")
            if isinstance(runner, dict):
                del runner["group"]
        case "missing-runner-name-pass":
            runner = data.get("runner")
            if isinstance(runner, dict):
                del runner["name"]


def expect_reject(context: RejectContext, name: MutatorName) -> None:
    data = copy.deepcopy(context.load_json(context.good))
    mutate(data, name)
    bad = context.root / f"bad-{name}.json"
    _ = bad.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
    try:
        context.validate_proof(bad, context.schema)
    except RunnerProofError as exc:
        print(f"PASS reject {name}: {exc}")
        return
    raise RunnerProofError(f"expected rejection did not occur: {name}")


def expect_reject_malformed_protected_review_artifact(context: RejectContext) -> None:
    data = copy.deepcopy(context.load_json(context.good))
    review_path = context.root / "protected-review-missing-run-url.json"
    review_data = context.load_json(DEFAULT_FIXTURES / "valid" / "protected-review.json")
    del review_data["run_url"]
    _ = review_path.write_text(json.dumps(review_data, indent=2, sort_keys=True) + "\n")
    protected_review = data.get("protected_review")
    if not isinstance(protected_review, dict):
        raise RunnerProofError("self-test setup missing protected_review object")
    protected_review["path"] = str(review_path)
    protected_review["sha256"] = hashlib.sha256(review_path.read_bytes()).hexdigest()
    bad = context.root / "bad-malformed-protected-review-artifact.json"
    _ = bad.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
    try:
        context.validate_proof(bad, context.schema)
    except RunnerProofError as exc:
        print(f"PASS reject malformed-protected-review-artifact: {exc}")
        return
    raise RunnerProofError("expected rejection did not occur: malformed-protected-review-artifact")


def run_self_test(
    schema: Path,
    *,
    validate_fixtures: ValidateFixtures,
    validate_proof: ValidateProof,
    load_json: LoadJson,
) -> None:
    validate_fixtures(DEFAULT_FIXTURES, schema)
    root = Path("evidence/lab/runner-substrate-self-test")
    shutil.rmtree(root, ignore_errors=True)
    root.mkdir(parents=True, exist_ok=True)
    context = RejectContext(
        DEFAULT_FIXTURES / "valid" / "protected-runner.json",
        schema,
        root,
        load_json,
        validate_proof,
    )
    names: tuple[MutatorName, ...] = ("missing-dev-kvm-status", "absolute-path", "missing-protected-environment", "missing-protected-review", "protected-review-hash-mismatch", "protected-review-role-mismatch", "release-claim", "production-claim", "fake-attestation-pass", "empty-qemu-version-pass", "missing-runner-group-pass", "missing-runner-name-pass")
    for name in names:
        expect_reject(context, name)
    expect_reject_malformed_protected_review_artifact(context)
    validate_proof(DEFAULT_FIXTURES / "valid" / "skip-config-unavailable.json", schema)
    print("PASS accept skip-config-unavailable: placeholder config hash has explicit unavailable reason")
    validate_proof(DEFAULT_FIXTURES / "valid" / "skip-qemu-version-unavailable.json", schema)
    print("PASS accept skip-qemu-version-unavailable: missing QEMU version is an unavailable QEMU SKIP proof")
    shutil.rmtree(root, ignore_errors=True)
    print("PASS runner substrate proof self-test: accepts complete fixture and rejects reviewer-unavailable PASS, missing/mismatched/malformed protected review artifact, empty QEMU version PASS, missing runner group/name PASS, sched_ext/BTF-unavailable PASS, unsupported release PASS, TCG accel PASS, placeholder config hash PASS, BPF SKIP PASS, unsafe paths, release/prod claims, host mutation, and fake attestation PASS; accepts SKIP unavailable config metadata")


def main() -> int:
    return subprocess.run(
        [sys.executable, "qa/runner_substrate_proof_check.py", "--self-test"],
        check=False,
    ).returncode


if __name__ == "__main__":
    raise SystemExit(main())
