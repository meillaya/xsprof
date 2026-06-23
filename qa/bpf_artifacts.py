from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import hashlib
import json
import subprocess
from typing import Final, TypeAlias

JsonValue: TypeAlias = None | bool | int | float | str | list["JsonValue"] | dict[str, "JsonValue"]
JsonObject: TypeAlias = dict[str, JsonValue]

CANONICAL_OBJECT: Final[Path] = Path("zig-out/bpf/zigsched_minimal.bpf.o")
CANONICAL_METADATA: Final[Path] = Path("zig-out/bpf/zigsched_minimal.bpf.meta.json")
BUILD_COMMAND: Final[tuple[str, str]] = ("bash", "tools/build_bpf.sh")


@dataclass(frozen=True, slots=True)
class BpfArtifacts:
    object_path: Path
    metadata_path: Path
    object_sha256: str


class BpfArtifactError(Exception):
    """Raised when BPF object or metadata artifacts are missing or inconsistent."""


def ensure_canonical_bpf_artifacts() -> BpfArtifacts:
    """Rebuild and validate the canonical VM-only BPF object when needed."""
    if not CANONICAL_OBJECT.is_file() or not CANONICAL_METADATA.is_file():
        run_build_bpf()
    return validate_bpf_artifacts(CANONICAL_OBJECT, CANONICAL_METADATA)


def ensure_if_canonical(path: Path) -> None:
    if path in {CANONICAL_OBJECT, CANONICAL_METADATA} and (not CANONICAL_OBJECT.is_file() or not CANONICAL_METADATA.is_file()):
        _ = ensure_canonical_bpf_artifacts()


def validate_bpf_artifacts(object_path: Path, metadata_path: Path) -> BpfArtifacts:
    if not object_path.is_file():
        raise BpfArtifactError(f"missing BPF object: {object_path}")
    if not metadata_path.is_file():
        raise BpfArtifactError(f"missing BPF metadata: {metadata_path}")
    object_sha = sha256_file(object_path)
    metadata = load_metadata(metadata_path)
    require_text(metadata, "schema", "metadata")
    if metadata.get("schema") != "zig-scheduler/bpf-object-metadata/v1":
        raise BpfArtifactError("BPF metadata schema mismatch")
    if metadata.get("object_sha256") != object_sha:
        raise BpfArtifactError("BPF metadata object_sha256 disagrees with object")
    if metadata.get("object_hash") != "sha256:" + object_sha:
        raise BpfArtifactError("BPF metadata object_hash disagrees with object")
    metadata_object = metadata.get("object")
    if isinstance(metadata_object, str) and Path(metadata_object) != object_path:
        raise BpfArtifactError("BPF metadata object path disagrees with object")
    if metadata.get("host_mutation") is not False or metadata.get("host_attach_allowed") is not False:
        raise BpfArtifactError("BPF metadata does not preserve host fail-closed policy")
    if metadata.get("vm_only") is not True:
        raise BpfArtifactError("BPF metadata must be VM-only")
    if metadata.get("verification_claimed") is not False:
        raise BpfArtifactError("BPF metadata must not claim verifier success")
    return BpfArtifacts(object_path=object_path, metadata_path=metadata_path, object_sha256=object_sha)


def run_build_bpf() -> None:
    try:
        result = subprocess.run(BUILD_COMMAND, check=False, capture_output=True, text=True)
    except FileNotFoundError as exc:
        raise BpfArtifactError("could not run tools/build_bpf.sh") from exc
    if result.returncode != 0:
        output = (result.stdout + result.stderr).strip()
        raise BpfArtifactError(f"BPF build failed: {output}")


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
        raise BpfArtifactError(f"invalid BPF metadata JSON: {path}") from exc
    if not isinstance(raw, dict):
        raise BpfArtifactError("BPF metadata must contain a JSON object")
    return raw


def require_text(data: JsonObject, field: str, context: str) -> str:
    value = data.get(field)
    if not isinstance(value, str) or value == "":
        raise BpfArtifactError(f"{context} missing text field: {field}")
    return value
