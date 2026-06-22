from __future__ import annotations

import json
import shutil
from pathlib import Path
import importlib
from collections.abc import Mapping
import hashlib
from typing import TypeAlias

JsonValue: TypeAlias = None | bool | int | float | str | list["JsonValue"] | dict[str, "JsonValue"]
JsonObject: TypeAlias = dict[str, JsonValue]

REFUSAL_SCHEMA = "zig-scheduler/verifier-only-refusal/v1"
SELF_ROOT = Path("evidence/lab/verifier-log-self-test")


def run_self_test() -> None:
    verifier = importlib.import_module("verifier_log_check")

    shutil.rmtree(SELF_ROOT, ignore_errors=True)
    SELF_ROOT.mkdir(parents=True)
    bad = write_log("bad.log", "invalid mem access 'scalar'\nbpftool_rc=255")
    skip = write_log("skip.log", "SKIP: bpftool unavailable inside VM; verifier load not attempted")
    clean = write_log("clean.log", "bpftool_rc=0")
    missing = SELF_ROOT / "missing-state.log"
    missing.write_text("schema=zig-scheduler/bpf-verifier-log/v1\nobject=zig-out/bpf/min.o\nobject_sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nbpftool_rc=0\n")
    state_delta = SELF_ROOT / "state-delta.log"
    state_delta.write_text("\n".join((
        "schema=zig-scheduler/bpf-verifier-log/v1",
        "object=zig-out/bpf/zigsched_minimal.bpf.o",
        "object_sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nbpf_metadata_path=zig-out/bpf/zigsched_minimal.bpf.meta.json\nbpf_metadata_object_sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "sched_ext_state_before=enabled",
        "sched_ext_enable_seq_before=1",
        "bpftool_rc=0",
        "sched_ext_state_after=disabled",
        "sched_ext_enable_seq_after=1",
        "cgroup_membership_before=abc",
        "cgroup_membership_after=abc",
    )) + "\n")
    assert_result(verifier.parse_log(bad), "FAIL", "INVALID_MEM_ACCESS")
    assert_result(verifier.parse_log(skip), "SKIP", "BPFTOOL_UNAVAILABLE")
    assert_result(verifier.parse_log(clean), "PASS", "VERIFIER_ACCEPTED")
    assert_result(verifier.parse_log(missing), "FAIL", "MISSING_STATE_EVIDENCE")
    assert_result(verifier.parse_log(state_delta), "FAIL", "SCHED_EXT_STATE_CHANGED")
    evidence = SELF_ROOT / "verifier-evidence.json"
    evidence.write_text(json.dumps({
        "schema": "zig-scheduler/verifier-only-evidence/v1",
        "host_mutation": False,
        "object": "zig-out/bpf/zigsched_minimal.bpf.o",
        "object_sha256": "a" * 64,
        "bpf_metadata_path": "zig-out/bpf/zigsched_minimal.bpf.meta.json",
        "bpf_metadata_object_sha256": "a" * 64,
        "parsed_verifier_status": "PASS",
        "parsed_verifier_reason": "VERIFIER_ACCEPTED",
        "sched_ext_state_before": "enabled",
        "sched_ext_state_after": "enabled",
        "enable_seq_before": "1",
        "enable_seq_after": "1",
        "cgroup_membership_before": "abc",
        "cgroup_membership_after": "abc",
    }) + "\n")
    assert_result(verifier.parse_evidence(evidence), "PASS", "VERIFIER_ACCEPTED")
    vm_log = write_vm_log("vm-live.log")
    assert_result(verifier.parse_log(vm_log), "PASS", "VM_VERIFIER_ACCEPTED")
    vm_evidence = SELF_ROOT / "vm-verifier-evidence.json"
    vm_evidence.write_text(json.dumps(vm_evidence_data(vm_log), sort_keys=True) + "\n")
    assert_result(verifier.parse_evidence(vm_evidence), "PASS", "VM_VERIFIER_ACCEPTED")
    bad_vm_evidence = SELF_ROOT / "vm-attach-only-evidence.json"
    bad_data = vm_evidence_data(vm_log)
    bad_data["rollback_status"] = "SKIP"
    bad_vm_evidence.write_text(json.dumps(bad_data, sort_keys=True) + "\n")
    try:
        verifier.parse_evidence(bad_vm_evidence)
    except verifier.VerifierLogError:
        pass
    else:
        raise verifier.VerifierLogError("attach-only VM verifier evidence was accepted")
    refusal = SELF_ROOT / "host-refusal.json"
    refusal.write_text(json.dumps({"schema": REFUSAL_SCHEMA, "status": "refused-host", "reason": "marker required", "object": "obj.o", "host_mutation": False}) + "\n")
    assert_result(verifier.parse_refusal(refusal, allow_refusal=True), "REFUSE", "marker required")
    try:
        verifier.parse_refusal(refusal, allow_refusal=False)
    except verifier.VerifierLogError:
        pass
    else:
        raise verifier.VerifierLogError("refusal without --allow-refusal was accepted")
    shutil.rmtree(SELF_ROOT, ignore_errors=True)
    print("PASS verifier log self-test: fail/skip/pass/evidence/refusal cases classified")


def write_log(name: str, tail: str) -> Path:
    path = SELF_ROOT / name
    body = "\n".join((
        "schema=zig-scheduler/bpf-verifier-log/v1",
        "object=zig-out/bpf/zigsched_minimal.bpf.o",
        "object_sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nbpf_metadata_path=zig-out/bpf/zigsched_minimal.bpf.meta.json\nbpf_metadata_object_sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "sched_ext_state_before=enabled",
        "sched_ext_enable_seq_before=1",
        tail,
        "sched_ext_state_after=enabled",
        "sched_ext_enable_seq_after=1",
        "cgroup_membership_before=abc",
        "cgroup_membership_after=abc",
    ))
    path.write_text(body + "\n")
    return path


def write_vm_log(name: str) -> Path:
    path = SELF_ROOT / name
    object_path = write_object()
    metadata_path = write_metadata(object_path)
    object_sha = sha256_file(object_path)
    body = "\n".join((
        "verification time 233 usec",
        "Registered sched_ext_ops zigsched_minima id 4",
        "Unregistered sched_ext_ops zigsched_minima id 4",
        "schema=zig-scheduler/bpf-verifier-log/v1",
        "evidence_mode=vm-live",
        "vm_kind=qemu-vm",
        "vm_marker_present=true",
        "vm_marker_path=/run/zig-scheduler-vm-lab.marker",
        "kernel_release=7.0.12-lab",
        "kernel_arch=x86_64",
        "kernel_config_sha256=microvm-host-kernel",
        "host_mutation=false",
        "release_eligible_live_proof=true",
        "verifier_result=accepted",
        "attach_result=registered",
        "rollback_status=PASS",
        f"object={object_path.as_posix()}",
        f"object_sha256={object_sha}",
        f"bpf_metadata_path={metadata_path.as_posix()}",
        f"bpf_metadata_object_sha256={object_sha}",
        "bpftool_rc=0",
    ))
    path.write_text(body + "\n")
    return path


def vm_evidence_data(log_path: Path) -> JsonObject:
    object_path = SELF_ROOT / "zigsched_minimal.bpf.o"
    metadata_path = SELF_ROOT / "zigsched_minimal.bpf.meta.json"
    object_sha = sha256_file(object_path)
    return {
        "schema": "zig-scheduler/vm-verifier-evidence/v1",
        "status": "PASS",
        "evidence_mode": "vm-live",
        "vm_kind": "qemu-vm",
        "vm_marker_present": True,
        "vm_marker_path": "/run/zig-scheduler-vm-lab.marker",
        "kernel_tuple": {"release": "7.0.12-lab", "arch": "x86_64", "config_sha256": "microvm-host-kernel"},
        "host_mutation": False,
        "release_eligible_live_proof": True,
        "verifier_result": "accepted",
        "attach_result": "registered",
        "rollback_status": "PASS",
        "object": object_path.as_posix(),
        "object_sha256": object_sha,
        "bpf_metadata_path": metadata_path.as_posix(),
        "bpf_metadata_object_sha256": object_sha,
        "verifier_log": log_path.as_posix(),
    }


def write_object() -> Path:
    path = SELF_ROOT / "zigsched_minimal.bpf.o"
    path.write_bytes(b"self-test-bpf-object\n")
    return path


def write_metadata(object_path: Path) -> Path:
    path = SELF_ROOT / "zigsched_minimal.bpf.meta.json"
    object_sha = sha256_file(object_path)
    path.write_text(json.dumps({"object": object_path.as_posix(), "object_sha256": object_sha}, sort_keys=True) + "\n")
    return path


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def assert_result(result: Mapping[str, JsonValue], status: str, reason: str) -> None:
    if result.get("status") != status or result.get("reason") != reason:
        verifier = importlib.import_module("verifier_log_check")
        raise verifier.VerifierLogError(f"expected {status}/{reason}, got {result}")
