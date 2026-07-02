from __future__ import annotations

import hashlib
from pathlib import Path

from qa.evidence_manifest_check import JsonObject, JsonValue


class BundleCompareError(Exception):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise BundleCompareError(message)


def text(value: JsonValue | None, context: str) -> str:
    if not isinstance(value, str) or value == "":
        raise BundleCompareError(f"{context} must be non-empty text")
    return value


def obj(value: JsonValue | None, context: str) -> JsonObject:
    if not isinstance(value, dict):
        raise BundleCompareError(f"{context} must be an object")
    return value


def resolve_manifest(path: Path) -> Path:
    return path / "evidence-manifest.json" if path.is_dir() else path


def safe_path(value: JsonValue | None, context: str) -> Path:
    raw = text(value, context)
    path = Path(raw)
    require(not path.is_absolute() and ".." not in path.parts, f"{context} must be relative and non-traversing: {raw}")
    return path


def artifact_path(manifest_path: Path, artifact_root: Path | None, value: JsonValue | None, context: str) -> Path:
    path = safe_path(value, context)
    rooted = (artifact_root if artifact_root is not None else manifest_path.parent) / path
    require(rooted.exists(), f"missing referenced artifact: {path}")
    return rooted


def file_sha(path: Path) -> str:
    try:
        return hashlib.sha256(path.read_bytes()).hexdigest()
    except FileNotFoundError as exc:
        raise BundleCompareError(f"missing referenced artifact: {path}") from exc
