from __future__ import annotations

import os
import shutil
from pathlib import Path
from tempfile import TemporaryDirectory

from qa.frontend_contract_pack_types import ContractPackError, JsonObject
from qa.matrix_run_contract_check import MATRIX_BASE, MANIFEST_FILE, MatrixRunContractError, validate_manifest


def validate_referenced_matrix_manifest(manifest_path: Path) -> None:
    """Validate generated matrix refs or committed clean-tree fixture copies."""
    if manifest_path.parts[: len(MATRIX_BASE.parts)] == MATRIX_BASE.parts:
        _ = validate_manifest(manifest_path)
        return
    fixture_prefix = Path("fixtures/frontend-contract/matrix-artifact-reference")
    if manifest_path.parts[: len(fixture_prefix.parts)] != fixture_prefix.parts or manifest_path.name != MANIFEST_FILE:
        message = "matrix artifact must be a generated matrix manifest or committed frontend-contract fixture: " + str(manifest_path)
        raise MatrixRunContractError(message)
    run_id = manifest_path.parent.name
    with TemporaryDirectory(prefix="zigsched-matrix-fixture-") as tmp:
        temp_root = Path(tmp)
        target = temp_root / MATRIX_BASE / run_id
        _ = shutil.copytree(manifest_path.parent, target)
        previous = Path.cwd()
        os.chdir(temp_root)
        try:
            _ = validate_manifest(MATRIX_BASE / run_id / MANIFEST_FILE)
        finally:
            os.chdir(previous)


def require_matrix_manifest_reference(row: JsonObject, context: str) -> Path:
    raw_artifact = row.get("artifact")
    if not isinstance(raw_artifact, str) or raw_artifact == "":
        raise ContractPackError(f"{context} must carry a matrix manifest artifact path")
    manifest_path = Path(raw_artifact)
    if manifest_path.name != "manifest.json":
        raise ContractPackError(f"{context} must reference a matrix manifest.json artifact")
    raw_artifact_paths = row.get("artifact_paths")
    if not isinstance(raw_artifact_paths, list) or raw_artifact not in raw_artifact_paths:
        raise ContractPackError(f"{context} artifact_paths must include the matrix manifest artifact")
    try:
        validate_referenced_matrix_manifest(manifest_path)
    except MatrixRunContractError as exc:
        raise ContractPackError(f"{context} referenced matrix manifest is invalid: {exc}") from exc
    return manifest_path


def validate_matrix_artifact_reference(name: str, rows: list[JsonObject]) -> None:
    seen_manifest = False
    for row in rows:
        if row.get("event") == "validation" and row.get("reason") == "matrix_artifact_referenced":
            seen_manifest = True
            _ = require_matrix_manifest_reference(row, name)
    if not seen_manifest:
        raise ContractPackError(f"{name} must validate a matrix artifact reference")
