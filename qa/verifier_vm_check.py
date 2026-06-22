from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import hashlib
import json
from typing import Final

from qa.evidence_safety_check import JsonObject, JsonValue, reject_contradictions

SCHEMA: Final[str] = "zig-scheduler/verifier-log-parse/v1"
VM_EVIDENCE_SCHEMA: Final[str] = "zig-scheduler/vm-verifier-evidence/v1"
VM_LOG_SCHEMA: Final[str] = "zig-scheduler/bpf-verifier-log/v1"
VM_MARKER: Final[str] = "/run/zig-scheduler-vm-lab.marker"
LIVE_MODE: Final[str] = "vm-live"
LIVE_VM_KIND: Final[str] = "qemu-vm"


class VMVerifierError(Exception):
    pass


@dataclass(frozen=True, slots=True)
class ArtifactClaims:
    object_path: Path
    object_sha: str
    metadata_path: Path
    metadata_sha: str


def parse_vm_evidence(path: Path, raw: JsonObject) -> JsonObject:
    if raw.get("host_mutation") is not False:
        raise VMVerifierError("VM verifier evidence must have host_mutation=false")
    if raw.get("release_eligible_live_proof") is not True:
        raise VMVerifierError("VM verifier evidence must be release-eligible VM-live proof")
    reject_contradictions(raw, "VM verifier evidence")
    require_vm_live_fields(raw, "VM verifier evidence")
    require_vm_acceptance_fields(raw, "VM verifier evidence")
    object_path = require_relative_file(require_text(raw, "object"), "object")
    metadata_path = require_relative_file(require_text(raw, "bpf_metadata_path"), "bpf_metadata_path")
    object_sha = require_checked_sha(raw, "object_sha256")
    metadata_sha = require_checked_sha(raw, "bpf_metadata_object_sha256")
    require_artifact_hashes(ArtifactClaims(object_path, object_sha, metadata_path, metadata_sha))
    verifier_log = require_relative_file(require_text(raw, "verifier_log"), "verifier_log")
    log_text = verifier_log.read_text(errors="replace")
    log_values = parse_key_values(log_text)
    require_vm_log_values(log_values)
    require_vm_log_acceptance(log_text, "VM verifier log")
    require_log_matches_evidence(log_values, raw)
    return {
        "schema": SCHEMA,
        "status": "PASS",
        "reason": "VM_VERIFIER_ACCEPTED",
        "input": path.as_posix(),
        "object": object_path.as_posix(),
        "object_sha256": object_sha,
        "bpf_metadata_path": metadata_path.as_posix(),
        "bpf_metadata_object_sha256": metadata_sha,
        "bpftool_rc": 0,
        "verifier_errors": [],
        "host_mutation": False,
    }


def parse_vm_live_log(path: Path, values: dict[str, str], text: str) -> JsonObject | None:
    if values.get("schema") != VM_LOG_SCHEMA:
        return None
    if "evidence_mode" not in values:
        return None
    require_vm_log_values(values)
    object_sha = require_checked_value(values, "object_sha256")
    metadata_sha = require_checked_value(values, "bpf_metadata_object_sha256")
    object_path = require_relative_file(require_key(values, "object"), "object")
    metadata_path = require_relative_file(require_key(values, "bpf_metadata_path"), "bpf_metadata_path")
    require_artifact_hashes(ArtifactClaims(object_path, object_sha, metadata_path, metadata_sha))
    require_vm_log_acceptance(text, "VM verifier log")
    return {
        "schema": SCHEMA,
        "status": "PASS",
        "reason": "VM_VERIFIER_ACCEPTED",
        "input": path.as_posix(),
        "object": object_path.as_posix(),
        "object_sha256": object_sha,
        "bpf_metadata_path": metadata_path.as_posix(),
        "bpf_metadata_object_sha256": metadata_sha,
        "bpftool_rc": parse_bpftool_rc(values),
        "verifier_errors": [],
        "sched_ext_state_before": values.get("sched_ext_state_before", ""),
        "sched_ext_state_after": values.get("sched_ext_state_after", ""),
        "enable_seq_before": values.get("sched_ext_enable_seq_before", ""),
        "enable_seq_after": values.get("sched_ext_enable_seq_after", ""),
        "cgroup_membership_before": values.get("cgroup_membership_before", ""),
        "cgroup_membership_after": values.get("cgroup_membership_after", ""),
        "host_mutation": False,
    }


def parse_key_values(text: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw in text.splitlines():
        line = raw.strip()
        if "=" in line and not line.startswith("COMMAND:"):
            key, value = line.split("=", 1)
            values[key] = value
    return values


def require_text(data: JsonObject, field: str) -> str:
    value = data.get(field)
    if not isinstance(value, str) or value == "":
        raise VMVerifierError(f"VM verifier evidence missing text field: {field}")
    return value


def require_bool(data: JsonObject, field: str) -> bool:
    value = data.get(field)
    if not isinstance(value, bool):
        raise VMVerifierError(f"VM verifier evidence missing bool field: {field}")
    return value


def require_object(data: JsonObject, field: str) -> JsonObject:
    value = data.get(field)
    if not isinstance(value, dict):
        raise VMVerifierError(f"VM verifier evidence missing object field: {field}")
    return value


def require_key(values: dict[str, str], field: str) -> str:
    value = values.get(field, "")
    if value == "":
        raise VMVerifierError(f"VM verifier log missing field: {field}")
    return value


def require_checked_sha(data: JsonObject, field: str) -> str:
    value = require_text(data, field)
    require_sha256(value, field)
    return value


def require_checked_value(values: dict[str, str], field: str) -> str:
    value = require_key(values, field)
    require_sha256(value, field)
    return value


def require_sha256(value: str, context: str) -> None:
    if len(value) != 64 or any(char not in "0123456789abcdef" for char in value):
        raise VMVerifierError(f"{context} must be a lowercase sha256")


def require_relative_file(raw_path: str, context: str) -> Path:
    path = Path(raw_path)
    if path.is_absolute() or ".." in path.parts or path.is_symlink() or not path.is_file():
        raise VMVerifierError(f"{context} path is unsafe or missing")
    return path


def require_vm_live_fields(data: JsonObject, context: str) -> None:
    if require_text(data, "evidence_mode") != LIVE_MODE:
        raise VMVerifierError(f"{context} is not VM-live evidence")
    if require_text(data, "vm_kind") != LIVE_VM_KIND:
        raise VMVerifierError(f"{context} must come from qemu-vm")
    if not require_bool(data, "vm_marker_present"):
        raise VMVerifierError(f"{context} missing VM marker")
    if require_text(data, "vm_marker_path") != VM_MARKER:
        raise VMVerifierError(f"{context} has invalid VM marker path")
    kernel = require_object(data, "kernel_tuple")
    for field in ("release", "arch", "config_sha256"):
        value = kernel.get(field)
        if not isinstance(value, str) or value == "":
            raise VMVerifierError(f"{context} missing kernel tuple field: {field}")


def require_vm_acceptance_fields(data: JsonObject, context: str) -> None:
    if require_text(data, "status") != "PASS":
        raise VMVerifierError(f"{context} status must be PASS")
    if require_text(data, "verifier_result") != "accepted":
        raise VMVerifierError(f"{context} must report verifier acceptance")
    if require_text(data, "attach_result") != "registered":
        raise VMVerifierError(f"{context} must report registered attach")
    if require_text(data, "rollback_status") != "PASS":
        raise VMVerifierError(f"{context} must include rollback PASS")


def require_vm_log_values(values: dict[str, str]) -> None:
    if values.get("evidence_mode") != LIVE_MODE:
        raise VMVerifierError("VM verifier log is not VM-live evidence")
    if values.get("vm_kind") != LIVE_VM_KIND:
        raise VMVerifierError("VM verifier log must come from qemu-vm")
    if values.get("vm_marker_present") != "true" or values.get("vm_marker_path") != VM_MARKER:
        raise VMVerifierError("VM verifier log missing VM marker proof")
    if values.get("host_mutation") != "false":
        raise VMVerifierError("VM verifier log must have host_mutation=false")
    if values.get("release_eligible_live_proof") != "true":
        raise VMVerifierError("VM verifier log must be release-eligible VM-live proof")
    if values.get("verifier_result") != "accepted":
        raise VMVerifierError("VM verifier log must report verifier acceptance")
    if values.get("attach_result") != "registered":
        raise VMVerifierError("VM verifier log must report registered attach")
    if values.get("rollback_status") != "PASS":
        raise VMVerifierError("VM verifier log must include rollback PASS")


def require_vm_log_acceptance(text: str, context: str) -> None:
    lower = text.lower()
    for needle in ("invalid mem access", "unknown func", "invalid func", "program rejected", "permission denied"):
        if needle in lower:
            raise VMVerifierError(f"{context} contains verifier rejection: {needle}")
    for needle in ("verification time", "registered sched_ext_ops", "unregistered sched_ext_ops"):
        if needle not in lower:
            raise VMVerifierError(f"{context} missing VM verifier marker: {needle}")


def require_log_matches_evidence(values: dict[str, str], evidence: JsonObject) -> None:
    for field in ("object", "object_sha256", "bpf_metadata_path", "bpf_metadata_object_sha256"):
        if require_key(values, field) != require_text(evidence, field):
            raise VMVerifierError(f"VM verifier evidence {field} disagrees with verifier log")


def require_artifact_hashes(claims: ArtifactClaims) -> None:
    actual_object_sha = sha256_file(claims.object_path)
    if claims.object_sha != actual_object_sha:
        raise VMVerifierError("VM verifier evidence object_sha256 disagrees with object file")
    metadata = load_metadata(claims.metadata_path)
    metadata_object = metadata.get("object")
    if isinstance(metadata_object, str) and Path(metadata_object) != claims.object_path:
        raise VMVerifierError("VM verifier metadata object path disagrees with evidence object")
    metadata_object_sha = metadata.get("object_sha256")
    if claims.metadata_sha != metadata_object_sha or claims.metadata_sha != actual_object_sha:
        raise VMVerifierError("VM verifier metadata object sha disagrees with object")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_metadata(path: Path) -> JsonObject:
    try:
        raw: JsonValue = json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        raise VMVerifierError(f"invalid BPF metadata JSON: {path}") from exc
    if not isinstance(raw, dict):
        raise VMVerifierError("BPF metadata must contain a JSON object")
    return raw


def parse_bpftool_rc(values: dict[str, str]) -> int | None:
    value = values.get("bpftool_rc", "")
    if value == "":
        return None
    if not value.isdigit():
        raise VMVerifierError(f"invalid bpftool_rc: {value}")
    return int(value)
