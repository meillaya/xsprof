#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
# ─── How to run ───
# python3 qa/vm/attestation_check.py --input evidence/lab/task-T16/attestation.json
# python3 qa/vm/attestation_check.py --self-test
# ──────────────────
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import json
import shutil
import subprocess
import sys
from typing import Final, TypeAlias

JsonValue: TypeAlias = None | bool | int | float | str | list["JsonValue"] | dict[str, "JsonValue"]
JsonObject: TypeAlias = dict[str, JsonValue]

SCHEMA: Final[str] = "zig-scheduler/vm-attestation/v1"
VM_MARKER: Final[str] = "/run/zig-scheduler-vm-lab.marker"
SUPPORTED_ARCH: Final[str] = "x86_64"
MIN_KERNEL: Final[tuple[int, int]] = (6, 12)


@dataclass(frozen=True, slots=True)
class Args:
    input_path: Path | None
    self_test: bool


class AttestationError(Exception):
    pass


def parse_args(argv: list[str]) -> Args:
    if argv == ["--self-test"]:
        return Args(input_path=None, self_test=True)
    if len(argv) == 2 and argv[0] == "--input":
        return Args(input_path=Path(argv[1]), self_test=False)
    raise AttestationError("usage: attestation_check.py --input <attestation.json> | --self-test")


def load_object(path: Path) -> JsonObject:
    try:
        raw: JsonValue = json.loads(path.read_text())
    except FileNotFoundError as exc:
        raise AttestationError(f"missing attestation: {path}") from exc
    except json.JSONDecodeError as exc:
        raise AttestationError(f"invalid attestation JSON: {exc}") from exc
    if not isinstance(raw, dict):
        raise AttestationError("attestation must be a JSON object")
    return raw


def require_string(data: JsonObject, field: str, context: str) -> str:
    value = data.get(field)
    if not isinstance(value, str) or value == "":
        raise AttestationError(f"{context} missing non-empty string field: {field}")
    return value


def require_bool(data: JsonObject, field: str, context: str) -> bool:
    value = data.get(field)
    if not isinstance(value, bool):
        raise AttestationError(f"{context} missing bool field: {field}")
    return value


def require_object(data: JsonObject, field: str, context: str) -> JsonObject:
    value = data.get(field)
    if not isinstance(value, dict):
        raise AttestationError(f"{context} missing object field: {field}")
    return value


def current_git_sha() -> str:
    result = subprocess.run(["git", "rev-parse", "HEAD"], check=True, stdout=subprocess.PIPE, text=True)
    return result.stdout.strip()


def parse_kernel(release: str) -> tuple[int, int]:
    parts = release.split(".", maxsplit=2)
    if len(parts) < 2:
        raise AttestationError(f"kernel release is malformed: {release}")
    return int("".join(ch for ch in parts[0] if ch.isdigit())), int("".join(ch for ch in parts[1] if ch.isdigit()))


def reject_host_path(value: str, context: str) -> None:
    path = Path(value)
    if path.is_absolute() and (value.startswith("/sys/") or value.startswith("/proc/sys/")):
        raise AttestationError(f"{context} uses host system path: {value}")


def validate_tuple(data: JsonObject) -> None:
    kernel = require_object(data, "kernel_tuple", "attestation")
    release = require_string(kernel, "release", "attestation.kernel_tuple")
    arch = require_string(kernel, "arch", "attestation.kernel_tuple")
    major, minor = parse_kernel(release)
    if arch != SUPPORTED_ARCH or (major, minor) < MIN_KERNEL:
        raise AttestationError(f"unsupported kernel tuple: {release}/{arch}")
    if not require_bool(data, "btf_present", "attestation"):
        raise AttestationError("BTF is required")
    if not require_bool(data, "bpf_jit_enabled", "attestation"):
        raise AttestationError("BPF JIT is required")
    if not require_bool(data, "sched_class_ext_enabled", "attestation"):
        raise AttestationError("CONFIG_SCHED_CLASS_EXT is required")


def validate_attestation(path: Path) -> None:
    data = load_object(path)
    if require_string(data, "schema", "attestation") != SCHEMA:
        raise AttestationError("unsupported attestation schema")
    if require_string(data, "status", "attestation") != "PASS":
        raise AttestationError("attestation status must be PASS")
    if require_bool(data, "host_mutation", "attestation"):
        raise AttestationError("attestation host_mutation must be false")
    if not require_bool(data, "vm_marker_present", "attestation"):
        raise AttestationError("VM marker is missing")
    if require_string(data, "vm_marker_path", "attestation") != VM_MARKER:
        raise AttestationError("VM marker path mismatch")
    if require_string(data, "git_sha", "attestation") != current_git_sha():
        raise AttestationError("attestation git_sha is stale")
    if not require_bool(data, "copied_from_guest", "attestation"):
        raise AttestationError("attestation was not copied out from the guest")
    reject_host_path(require_string(data, "source_path", "attestation"), "attestation.source_path")
    transcript = Path(require_string(data, "transcript_path", "attestation"))
    if transcript.is_absolute() or ".." in transcript.parts or not transcript.exists():
        raise AttestationError("attestation transcript path is unsafe or missing")
    validate_tuple(data)


def good(current_sha: str, transcript: Path) -> JsonObject:
    return {
        "schema": SCHEMA,
        "status": "PASS",
        "vm_kind": "vm-configured-fixture",
        "vm_marker_present": True,
        "vm_marker_path": VM_MARKER,
        "copied_from_guest": True,
        "source_path": "/guest/copy-out/attestation.json",
        "transcript_path": transcript.as_posix(),
        "git_sha": current_sha,
        "object_sha256": "0" * 64,
        "kernel_tuple": {"release": "6.12.0-lab", "arch": "x86_64", "config_sha256": "fixture"},
        "btf_present": True,
        "bpf_jit_enabled": True,
        "sched_class_ext_enabled": True,
        "host_mutation": False,
        "release_eligible_live_proof": False,
    }


def reject(path: Path, label: str) -> None:
    try:
        validate_attestation(path)
    except (AttestationError, ValueError) as exc:
        print(f"PASS reject {label}: {exc}")
        return
    raise AttestationError(f"expected rejection did not occur: {label}")


def self_test() -> None:
    root = Path("evidence/lab/vm-attestation-self-test")
    shutil.rmtree(root, ignore_errors=True)
    root.mkdir(parents=True)
    transcript = root / "transcript.jsonl"
    transcript.write_text('{"event":"marker","host_mutation":false}\n')
    base = good(current_git_sha(), transcript)
    ok = root / "good.json"
    ok.write_text(json.dumps(base, indent=2, sort_keys=True) + "\n")
    validate_attestation(ok)
    for label, patch in {
        "missing marker": {"vm_marker_present": False},
        "stale git": {"git_sha": "stale"},
        "host sys path": {"source_path": "/sys/kernel/sched_ext/state"},
        "unsupported tuple": {"kernel_tuple": {"release": "6.11.0", "arch": "x86_64", "config_sha256": "old"}},
    }.items():
        bad = {**base, **patch}
        path = root / f"{label.replace(' ', '-')}.json"
        path.write_text(json.dumps(bad, indent=2, sort_keys=True) + "\n")
        reject(path, label)
    shutil.rmtree(root, ignore_errors=True)
    print("PASS VM attestation self-test: accepted copied guest marker tuple and rejected unsafe fixtures")


def run(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.self_test:
        self_test()
        return 0
    if args.input_path is None:
        raise AttestationError("internal argument parser error")
    validate_attestation(args.input_path)
    print(f"PASS VM attestation: {args.input_path}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(run(sys.argv[1:]))
    except (AttestationError, ValueError, subprocess.CalledProcessError) as exc:
        print(f"FAIL VM attestation: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
