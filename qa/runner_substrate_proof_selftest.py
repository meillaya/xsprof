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
import json
import shutil
from typing import Callable, Final, Literal, TypeAlias

from qa.runner_substrate_proof_common import JsonObject, RunnerProofError
LoadJson: TypeAlias = Callable[[Path], JsonObject]
ValidateProof: TypeAlias = Callable[[Path, Path], None]
ValidateFixtures: TypeAlias = Callable[[Path, Path], None]

DEFAULT_FIXTURES: Final[Path] = Path("fixtures/runner-substrate-proof")

MutatorName = Literal["missing-dev-kvm-status", "absolute-path", "missing-protected-environment", "release-claim", "production-claim", "fake-attestation-pass", "empty-qemu-version-pass", "missing-runner-group-pass", "missing-runner-name-pass"]


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
    names: tuple[MutatorName, ...] = ("missing-dev-kvm-status", "absolute-path", "missing-protected-environment", "release-claim", "production-claim", "fake-attestation-pass", "empty-qemu-version-pass", "missing-runner-group-pass", "missing-runner-name-pass")
    for name in names:
        expect_reject(context, name)
    validate_proof(DEFAULT_FIXTURES / "valid" / "skip-config-unavailable.json", schema)
    print("PASS accept skip-config-unavailable: placeholder config hash has explicit unavailable reason")
    validate_proof(DEFAULT_FIXTURES / "valid" / "skip-qemu-version-unavailable.json", schema)
    print("PASS accept skip-qemu-version-unavailable: missing QEMU version is an unavailable QEMU SKIP proof")
    shutil.rmtree(root, ignore_errors=True)
    print("PASS runner substrate proof self-test: accepts complete fixture and rejects reviewer-unavailable PASS, empty QEMU version PASS, missing runner group/name PASS, sched_ext/BTF-unavailable PASS, unsupported release PASS, TCG accel PASS, placeholder config hash PASS, BPF SKIP PASS, unsafe paths, release/prod claims, host mutation, and fake attestation PASS; accepts SKIP unavailable config metadata")
