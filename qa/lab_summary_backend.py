from __future__ import annotations

from pathlib import Path
import json
from typing import Final

from qa.evidence_safety_check import JsonObject, JsonValue
from qa.live_behavior_check import LiveBehaviorError, validate_bundle

VM_BACKEND_SCHEMA: Final[str] = "zig-scheduler/vm-backend-run/v1"
VM_BACKEND_MARKER: Final[str] = ".zig-scheduler-vm-backend-owned"
VM_MARKER: Final[str] = "/run/zig-scheduler-vm-lab.marker"


class BackendSummaryError(Exception):
    pass


def is_backend_live_summary(path: Path, summary: JsonObject) -> bool:
    return (
        summary.get("evidence_mode") == "vm-live"
        and path.name == "summary.json"
        and path.parent.name == "live"
        and (path.parent.parent / VM_BACKEND_MARKER).is_file()
    )


def validate_backend_run_summary(path: Path, summary: JsonObject) -> None:
    root = path.parent
    if not (root / VM_BACKEND_MARKER).is_file():
        raise BackendSummaryError("backend summary missing VM backend ownership marker")
    if require_string(summary, "status", "backend summary") != "PASS":
        raise BackendSummaryError("backend summary must be PASS VM-live evidence")
    if require_string(summary, "mode", "backend summary") != "vm-required":
        raise BackendSummaryError("backend summary must come from vm-required mode")
    if require_string(summary, "vm_kind", "backend summary") != "qemu-vm":
        raise BackendSummaryError("backend summary must come from qemu-vm")
    if require_string(summary, "vm_marker_required", "backend summary") != VM_MARKER:
        raise BackendSummaryError("backend summary VM marker requirement is invalid")
    if require_bool(summary, "host_mutation", "backend summary"):
        raise BackendSummaryError("backend summary host_mutation must be false")
    if require_bool(summary, "release_eligible_live_proof", "backend summary"):
        raise BackendSummaryError("backend wrapper must not be the release-eligible proof")
    output_dir = Path(require_string(summary, "output_dir", "backend summary"))
    if output_dir != root:
        raise BackendSummaryError("backend summary output_dir must match summary parent")
    assert_backend_artifact_paths(summary, "backend summary", root)
    live_summary = Path(require_string(summary, "live_summary", "backend summary"))
    if live_summary != root / "live" / "summary.json":
        raise BackendSummaryError("backend summary live_summary must point at the generated live bundle")
    if live_summary.is_symlink() or not live_summary.is_file():
        raise BackendSummaryError("backend summary live bundle is missing or symlinked")
    validate_backend_live_summary(live_summary, load_object(live_summary))


def validate_backend_live_summary(path: Path, summary: JsonObject) -> None:
    root = path.parent
    try:
        validate_bundle(path)
    except LiveBehaviorError as exc:
        raise BackendSummaryError(str(exc)) from exc
    if require_string(summary, "status", "backend live summary") != "PASS":
        raise BackendSummaryError("backend live summary must be PASS")
    if require_string(summary, "evidence_mode", "backend live summary") != "vm-live":
        raise BackendSummaryError("backend live summary must be VM-live")
    if require_string(summary, "vm_kind", "backend live summary") != "qemu-vm":
        raise BackendSummaryError("backend live summary must come from qemu-vm")
    if not require_bool(summary, "vm_marker_present", "backend live summary"):
        raise BackendSummaryError("backend live summary missing VM marker")
    if require_string(summary, "vm_marker_path", "backend live summary") != VM_MARKER:
        raise BackendSummaryError("backend live summary VM marker path is invalid")
    if require_string(summary, "rollback_result", "backend live summary") != "PASS":
        raise BackendSummaryError("backend live summary rollback must pass")
    if require_bool(summary, "host_mutation", "backend live summary"):
        raise BackendSummaryError("backend live summary host_mutation must be false")
    if require_bool(summary, "release_use", "backend live summary"):
        raise BackendSummaryError("backend live summary must remain controlled-lab-only release_use=false")
    if not require_bool(summary, "release_eligible_live_proof", "backend live summary"):
        raise BackendSummaryError("backend live summary must be release-eligible VM-live proof")
    output_dir = Path(require_string(summary, "output_dir", "backend live summary"))
    if output_dir != root:
        raise BackendSummaryError("backend live summary output_dir must match summary parent")
    assert_kernel_tuple(summary, "backend live summary")
    assert_backend_artifact_paths(summary, "backend live summary", root)
    validate_backend_stages(summary, root)


def validate_backend_stages(summary: JsonObject, root: Path) -> None:
    stages = require_list(summary, "stages", "backend live summary")
    if len(stages) == 0:
        raise BackendSummaryError("backend live summary must include stages")
    for index, item in enumerate(stages):
        if not isinstance(item, dict):
            raise BackendSummaryError(f"backend live stage[{index}] must be an object")
        context = f"backend live stage[{index}]"
        if require_string(item, "status", context) != "PASS":
            raise BackendSummaryError(f"{context} must pass")
        require_string(item, "stage", context)
        require_string(item, "reason", context)
        artifact = Path(require_string(item, "artifact", context))
        if artifact.is_absolute() or ".." in artifact.parts or root not in (artifact, *artifact.parents) or not artifact.exists():
            raise BackendSummaryError(f"{context} artifact is unsafe or missing")


def load_object(path: Path) -> JsonObject:
    try:
        raw: JsonValue = json.loads(path.read_text())
    except FileNotFoundError as exc:
        raise BackendSummaryError(f"missing JSON file: {path}") from exc
    except json.JSONDecodeError as exc:
        raise BackendSummaryError(f"invalid JSON in {path}: {exc}") from exc
    if not isinstance(raw, dict):
        raise BackendSummaryError(f"{path} must contain a JSON object")
    return raw


def require_string(data: JsonObject, field: str, context: str) -> str:
    value = data.get(field)
    if not isinstance(value, str) or value == "":
        raise BackendSummaryError(f"{context} missing non-empty string field: {field}")
    return value


def require_bool(data: JsonObject, field: str, context: str) -> bool:
    value = data.get(field)
    if not isinstance(value, bool):
        raise BackendSummaryError(f"{context} missing bool field: {field}")
    return value


def require_list(data: JsonObject, field: str, context: str) -> list[JsonValue]:
    value = data.get(field)
    if not isinstance(value, list):
        raise BackendSummaryError(f"{context} missing list field: {field}")
    return value


def require_object(data: JsonObject, field: str, context: str) -> JsonObject:
    value = data.get(field)
    if not isinstance(value, dict):
        raise BackendSummaryError(f"{context} missing object field: {field}")
    return value


def assert_kernel_tuple(data: JsonObject, context: str) -> None:
    kernel = require_object(data, "kernel_tuple", context)
    for field in ("release", "arch", "config_sha256"):
        require_string(kernel, field, f"{context}.kernel_tuple")


def assert_backend_artifact_paths(data: JsonObject, context: str, root: Path) -> list[Path]:
    values = require_list(data, "artifact_paths", context)
    paths: list[Path] = []
    for index, value in enumerate(values):
        if not isinstance(value, str) or value == "":
            raise BackendSummaryError(f"{context}.artifact_paths[{index}] must be non-empty relative path text")
        path = Path(value)
        if path.is_absolute() or ".." in path.parts:
            raise BackendSummaryError(f"{context}.artifact_paths[{index}] escapes repository: {value}")
        if root not in (path, *path.parents):
            raise BackendSummaryError(f"{context}.artifact_paths[{index}] must stay under {root}: {value}")
        if path.is_symlink() or not path.exists():
            raise BackendSummaryError(f"{context}.artifact_paths[{index}] is missing or symlinked: {value}")
        paths.append(path)
    if len(paths) == 0:
        raise BackendSummaryError(f"{context} must include at least one artifact path")
    return paths
