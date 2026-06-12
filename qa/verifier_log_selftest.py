from __future__ import annotations

import json
import shutil
from pathlib import Path
import importlib
from collections.abc import Mapping
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


def assert_result(result: Mapping[str, JsonValue], status: str, reason: str) -> None:
    if result.get("status") != status or result.get("reason") != reason:
        verifier = importlib.import_module("verifier_log_check")
        raise verifier.VerifierLogError(f"expected {status}/{reason}, got {result}")
