#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
# ─── How to run ───
# python3 qa/vm_mutation_contract_check.py --mode host-refusal --mutation cgroup.weight
"""Validate host-refusal and VM-only mutation evidence contracts."""

from __future__ import annotations

import json
import sys
from dataclasses import dataclass
from pathlib import Path
from tempfile import TemporaryDirectory
from typing import Final

JsonValue = None | bool | int | float | str | list["JsonValue"] | dict[str, "JsonValue"]
JsonObject = dict[str, JsonValue]

VM_MARKER: Final = "/run/zig-scheduler-vm-lab.marker"
MUTATIONS: Final = ("cgroup.weight", "cpu.max", "uclamp", "topology.offline_cpu")
HOST_FIXTURE_DIR: Final = Path("fixtures/vm-mutation-contract/host-refusal")
HOST_TRUE_FIELDS: Final = ("no_bpf_load_attach", "no_cgroup_write", "no_cpuset_write", "no_affinity_write", "no_priority_write", "no_sys_write", "no_proc_write")
FORBIDDEN_TEXT: Final = ("bpftool prog load", "bpftool struct_ops register", "/sys/fs/cgroup", "sched_ext attach", "chrt ", "taskset ")


@dataclass(frozen=True, slots=True)
class Args:
    mode: str
    mutation: str | None
    summary: Path | None
    path: Path | None
    self_test: bool


class MutationContractError(Exception):
    """Raised when VM mutation evidence is incomplete or host-unsafe."""


def parse_args(argv: list[str]) -> Args:
    if argv == ["--self-test"]:
        return Args("self-test", None, None, None, True)
    if len(argv) == 4 and argv[0] == "--mode" and argv[1] == "host-refusal" and argv[2] == "--mutation":
        return Args("host-refusal", argv[3], None, None, False)
    if len(argv) == 6 and argv[0] == "--mode" and argv[1] == "host-refusal" and argv[2] == "--mutation" and argv[4] == "--path":
        return Args("host-refusal", argv[3], None, Path(argv[5]), False)
    if len(argv) == 4 and argv[0] == "--mode" and argv[1] == "vm-evidence" and argv[2] == "--summary":
        return Args("vm-evidence", None, Path(argv[3]), None, False)
    raise MutationContractError("usage: vm_mutation_contract_check.py --mode host-refusal --mutation <name> [--path <artifact.json>] | --mode vm-evidence --summary <summary.json> | --self-test")


def load_json(path: Path) -> JsonObject:
    try:
        raw = json.loads(path.read_text())
    except FileNotFoundError as exc:
        raise MutationContractError(f"missing JSON file: {path}") from exc
    except json.JSONDecodeError as exc:
        raise MutationContractError(f"invalid JSON in {path}: {exc}") from exc
    if not isinstance(raw, dict):
        raise MutationContractError(f"{path} must contain an object")
    return raw


def obj(value: JsonValue | None, context: str) -> JsonObject:
    if not isinstance(value, dict):
        raise MutationContractError(f"{context} must be an object")
    return value


def text(value: JsonValue | None, context: str) -> str:
    if not isinstance(value, str) or value == "":
        raise MutationContractError(f"{context} must be non-empty text")
    return value


def require(condition: bool, message: str) -> None:
    if not condition:
        raise MutationContractError(message)


def reject_forbidden_text(value: JsonValue, context: str) -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            reject_forbidden_text(child, f"{context}.{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            reject_forbidden_text(child, f"{context}[{index}]")
    elif isinstance(value, str):
        for needle in FORBIDDEN_TEXT:
            require(needle not in value, f"forbidden host mutation text in {context}: {needle}")


def validate_host_refusal(data: JsonObject, mutation: str) -> None:
    require(mutation in MUTATIONS, f"unknown mutation: {mutation}")
    require(data.get("schema") == "zig-scheduler/lab-evidence/v1", "bad host-refusal schema")
    require(data.get("evidence_mode") == "host-refusal", "host-refusal mode missing")
    require(data.get("mutation") == mutation, "host-refusal mutation mismatch")
    require(data.get("status") in ("REFUSE", "SKIP"), "host-refusal status must be REFUSE or SKIP")
    require(data.get("host_mutation") is False, "host-refusal host_mutation must be false")
    require(data.get("release_eligible") is False, "host-refusal cannot be release eligible")
    require(data.get("vm_marker_present") is False, "host-refusal must not claim VM marker")
    require(data.get("target_allowlisted") is False, "host-refusal must not allowlist a host target")
    for field in HOST_TRUE_FIELDS:
        require(data.get(field) is True, f"host-refusal missing {field}=true")
    reject_forbidden_text(data, "host_refusal")


def validate_vm_mutation(name: str, data: JsonObject) -> None:
    require(name in MUTATIONS, f"unknown VM mutation family: {name}")
    require(data.get("host_mutation") is False, f"{name} host_mutation must be false")
    require(data.get("target_allowlisted") is True, f"{name} target must be allowlisted")
    text(data.get("target"), f"{name}.target")
    text(data.get("audit_id"), f"{name}.audit_id")
    text(data.get("rollback_id"), f"{name}.rollback_id")
    obj(data.get("pre_state"), f"{name}.pre_state")
    pre_state = obj(data.get("pre_state"), f"{name}.pre_state")
    obj(data.get("post_state"), f"{name}.post_state")
    rollback = obj(data.get("rollback_proof"), f"{name}.rollback_proof")
    cleanup = obj(data.get("cleanup_proof"), f"{name}.cleanup_proof")
    require(rollback.get("result") == "PASS", f"{name} rollback proof must pass")
    restored = rollback.get("restored_state")
    if restored is not None:
        require(restored == pre_state, f"{name} rollback restored_state must equal pre_state")
    require(cleanup.get("status") == "PASS", f"{name} cleanup proof must pass")


def find_mutation_evidence(summary: JsonObject) -> JsonObject:
    direct = summary.get("mutation_evidence")
    if isinstance(direct, dict):
        return direct
    live = summary.get("live")
    if isinstance(live, dict) and isinstance(live.get("mutation_evidence"), dict):
        return live["mutation_evidence"]
    raise MutationContractError("summary missing mutation_evidence object")


def validate_vm_summary(summary: JsonObject) -> None:
    require(summary.get("host_mutation") is False, "summary host_mutation must be false")
    require(summary.get("vm_marker_present") is True, "VM evidence missing marker")
    require(summary.get("vm_marker_path") == VM_MARKER, "VM evidence marker path mismatch")
    evidence = find_mutation_evidence(summary)
    missing = sorted(set(MUTATIONS) - set(evidence))
    require(not missing, "mutation evidence missing: " + ", ".join(missing))
    for name in MUTATIONS:
        validate_vm_mutation(name, obj(evidence.get(name), name))


def host_fixture_path(mutation: str) -> Path:
    return HOST_FIXTURE_DIR / f"{mutation}.json"


def run_self_test() -> None:
    for mutation in MUTATIONS:
        validate_host_refusal(load_json(host_fixture_path(mutation)), mutation)
    good_mutation = {
        "target": "vm:/sys/fs/cgroup/zig-scheduler-lab/workload",
        "target_allowlisted": True,
        "audit_id": "AUD-20990101T000000Z-test",
        "rollback_id": "RB-test",
        "host_mutation": False,
        "pre_state": {"value": "old"},
        "post_state": {"value": "new"},
        "rollback_proof": {"result": "PASS"},
        "cleanup_proof": {"status": "PASS"},
    }
    good = {"host_mutation": False, "vm_marker_present": True, "vm_marker_path": VM_MARKER, "mutation_evidence": {name: dict(good_mutation) for name in MUTATIONS}}
    validate_vm_summary(good)
    with TemporaryDirectory(prefix="zigsched-vm-mutation-") as tmp:
        bad_path = Path(tmp) / "bad.json"
        bad = dict(good)
        bad["vm_marker_present"] = False
        bad_path.write_text(json.dumps(bad))
        try:
            validate_vm_summary(load_json(bad_path))
        except MutationContractError as exc:
            print(f"PASS self-test rejected missing VM marker: {exc}")
        else:
            raise MutationContractError("self-test failed to reject missing VM marker")
        bad_rollback = json.loads(json.dumps(good))
        bad_rollback["mutation_evidence"]["cgroup.weight"]["rollback_proof"]["restored_state"] = {"value": "not-restored"}
        bad_path.write_text(json.dumps(bad_rollback))
        try:
            validate_vm_summary(load_json(bad_path))
        except MutationContractError as exc:
            print(f"PASS self-test rejected rollback mismatch: {exc}")
            return
    raise MutationContractError("self-test failed to reject rollback mismatch")


def run(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.self_test:
        run_self_test()
    elif args.mode == "host-refusal" and args.mutation is not None:
        artifact = args.path if args.path is not None else host_fixture_path(args.mutation)
        validate_host_refusal(load_json(artifact), args.mutation)
        print(f"PASS VM mutation host refusal: mutation={args.mutation} artifact={artifact}")
    elif args.mode == "vm-evidence" and args.summary is not None:
        validate_vm_summary(load_json(args.summary))
        print(f"PASS VM mutation evidence: summary={args.summary}")
    else:
        raise MutationContractError("invalid argument combination")
    return 0


def main() -> int:
    try:
        return run(sys.argv[1:])
    except (OSError, UnicodeError, MutationContractError) as exc:
        print(f"FAIL VM mutation contract: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
