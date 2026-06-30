#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
# ─── How to run ───
# python3 qa/evidence_manifest_check.py --manifest evidence/lab/manual-vm-proof/evidence-manifest.json --schema schemas/control/evidence-manifest.v1.schema.json
# python3 qa/evidence_manifest_check.py --self-test
"""Validate VM proof evidence-manifest/v1 bundles."""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import hashlib
import json
import re
import subprocess
import sys
from typing import Final, TypeAlias

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

JsonValue: TypeAlias = None | bool | int | float | str | list["JsonValue"] | dict[str, "JsonValue"]
JsonObject: TypeAlias = dict[str, JsonValue]

SCHEMA: Final[str] = "zig-scheduler/evidence-manifest/v1"
VM_MARKER: Final[str] = "/run/zig-scheduler-vm-lab.marker"
SHA_RE: Final[re.Pattern[str]] = re.compile(r"^[0-9a-f]{64}$")
AUDIT_RE: Final[re.Pattern[str]] = re.compile(r"^AUD-[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9_.-]+$")
ROLLBACK_RE: Final[re.Pattern[str]] = re.compile(r"^RB-[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
TUPLE_RE: Final[re.Pattern[str]] = re.compile(r"^linux-6\.(1[2-9]|[2-9][0-9])([.][0-9]+)?-x86_64-sched_ext-bpf-bpf_jit-btf-vm_lab_only$")
FIELDS: Final[frozenset[str]] = frozenset(("schema", "audit_id", "rollback_id", "vm_marker", "supported_tuple", "bpf_metadata_or_skip", "matrix_manifest", "daemon_events", "artifacts", "benchmark_provenance", "privacy_scan", "attestation", "required_sources", "host_mutation", "release_eligible", "production_capacity_claim"))
REF_FIELDS: Final[frozenset[str]] = frozenset(("path", "sha256", "schema_role"))
MARKER_FIELDS: Final[frozenset[str]] = frozenset(("path", "present", "checked_by"))
PRIVACY_FIELDS: Final[frozenset[str]] = frozenset(("status", "private_fields_found", "artifact_paths"))
ATTEST_FIELDS: Final[frozenset[str]] = frozenset(("status", "workflow_uses", "verify_command", "retention_days"))
REQUIRED_ROLES: Final[frozenset[str]] = frozenset(("matrix-row", "rollback-proof", "cleanup-proof", "host-refusal-proof", "privacy-scan", "static-verification-log"))
BPF_ROLES: Final[frozenset[str]] = frozenset(("bpf-metadata", "bpf-skip-json"))
ATTEST_STATUSES: Final[frozenset[str]] = frozenset(("pending-post-run-github-attestation", "verified-by-operator"))


@dataclass(frozen=True, slots=True)
class Args:
    manifest: Path | None
    schema: Path
    self_test: bool


class ManifestError(Exception):
    """Raised when an evidence manifest is malformed or stale."""


def parse_args(argv: list[str]) -> Args:
    if argv == ["--self-test"]:
        return Args(None, Path("schemas/control/evidence-manifest.v1.schema.json"), True)
    manifest: Path | None = None
    schema = Path("schemas/control/evidence-manifest.v1.schema.json")
    index = 0
    while index < len(argv):
        arg = argv[index]
        if arg == "--manifest":
            index += 1
            if index >= len(argv):
                raise ManifestError("--manifest requires a path")
            manifest = Path(argv[index])
        elif arg == "--schema":
            index += 1
            if index >= len(argv):
                raise ManifestError("--schema requires a path")
            schema = Path(argv[index])
        else:
            raise ManifestError("usage: evidence_manifest_check.py --manifest <path> [--schema <path>] | --self-test")
        index += 1
    if manifest is None:
        raise ManifestError("--manifest is required")
    return Args(manifest, schema, False)


def load_json(path: Path) -> JsonObject:
    try:
        raw: JsonValue = json.loads(path.read_text())
    except FileNotFoundError as exc:
        raise ManifestError(f"missing JSON file: {path}") from exc
    except json.JSONDecodeError as exc:
        raise ManifestError(f"invalid JSON in {path}: {exc}") from exc
    if not isinstance(raw, dict):
        raise ManifestError(f"{path} must contain a JSON object")
    return raw


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ManifestError(message)


def only_fields(row: JsonObject, allowed: frozenset[str], context: str) -> None:
    extra = sorted(set(row) - allowed)
    require(not extra, f"{context} has unexpected fields: {', '.join(extra)}")


def text(value: JsonValue | None, context: str) -> str:
    if not isinstance(value, str) or value == "":
        raise ManifestError(f"{context} must be non-empty text")
    return value


def safe_path(value: JsonValue | None, context: str) -> Path:
    raw = text(value, context)
    path = Path(raw)
    require(not path.is_absolute() and ".." not in path.parts, f"{context} must be relative and non-traversing: {raw}")
    return path


def file_sha(path: Path) -> str:
    try:
        return hashlib.sha256(path.read_bytes()).hexdigest()
    except FileNotFoundError as exc:
        raise ManifestError(f"missing referenced artifact: {path}") from exc


def validate_ref(value: JsonValue | None, context: str) -> str:
    if not isinstance(value, dict):
        raise ManifestError(f"{context} must be an artifact reference")
    only_fields(value, REF_FIELDS, context)
    path = safe_path(value.get("path"), f"{context}.path")
    digest = text(value.get("sha256"), f"{context}.sha256")
    require(SHA_RE.fullmatch(digest) is not None, f"{context}.sha256 must be sha256 hex")
    require(file_sha(path) == digest, f"{context}.sha256 does not match {path}")
    return text(value.get("schema_role"), f"{context}.schema_role")


def reject_claims(path: Path) -> None:
    if path.suffix == ".json":
        reject_claim_value(load_json(path), str(path))
        return
    if path.suffix != ".jsonl":
        return
    for line_no, line in enumerate(path.read_text().splitlines(), start=1):
        if line.strip() == "":
            continue
        try:
            value: JsonValue = json.loads(line)
        except json.JSONDecodeError as exc:
            raise ManifestError(f"invalid referenced JSON {path}:{line_no}: {exc}") from exc
        reject_claim_value(value, f"{path}:{line_no}")


def reject_claim_value(value: JsonValue, context: str) -> None:
    match value:  # noqa: MATCH_OK — JsonValue cases are exhausted by the union definition.
        case dict():
            for key, child in value.items():
                if key == "host_mutation":
                    require(child is False, f"{context}.host_mutation must be false")
                if key in {"release_eligible", "production_capacity_claim"}:
                    require(child is False, f"{context}.{key} must be false")
                reject_claim_value(child, f"{context}.{key}")
        case list():
            for index, child in enumerate(value):
                reject_claim_value(child, f"{context}[{index}]")
        case None | bool() | int() | float() | str():
            return


def tracked_sources(paths: JsonValue | None) -> None:
    if not isinstance(paths, list) or not paths:
        raise ManifestError("required_sources must be a non-empty list")
    result = subprocess.run(["git", "ls-files"], check=False, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode != 0:
        raise ManifestError(f"git ls-files failed: {result.stderr.strip()}")
    tracked = set(result.stdout.splitlines())
    for index, item in enumerate(paths):
        path = safe_path(item, f"required_sources[{index}]").as_posix()
        require(path in tracked, f"required source is not tracked: {path}")


def validate_manifest(path: Path, schema_path: Path) -> None:
    schema = load_json(schema_path)
    require(schema.get("$id") == SCHEMA, "evidence manifest schema $id mismatch")
    data = load_json(path)
    only_fields(data, FIELDS, str(path))
    require(data.get("schema") == SCHEMA, "unsupported evidence manifest schema")
    require(data.get("host_mutation") is False, "manifest.host_mutation must be false")
    require(data.get("release_eligible") is False, "manifest.release_eligible must be false")
    require(data.get("production_capacity_claim") is False, "manifest.production_capacity_claim must be false")
    require(AUDIT_RE.fullmatch(text(data.get("audit_id"), "audit_id")) is not None, "audit_id is malformed")
    require(ROLLBACK_RE.fullmatch(text(data.get("rollback_id"), "rollback_id")) is not None, "rollback_id is malformed")
    require(TUPLE_RE.fullmatch(text(data.get("supported_tuple"), "supported_tuple")) is not None, "supported_tuple is unsupported")
    marker = data.get("vm_marker")
    if not isinstance(marker, dict):
        raise ManifestError("vm_marker must be an object")
    only_fields(marker, MARKER_FIELDS, "vm_marker")
    require(marker.get("path") == VM_MARKER and marker.get("present") is True, "VM marker proof is missing")
    roles: set[str] = set()
    artifact_paths: list[Path] = []
    for field in ("matrix_manifest", "daemon_events", "bpf_metadata_or_skip"):
        value = data.get(field)
        roles.add(validate_ref(value, field))
        if isinstance(value, dict):
            artifact_paths.append(safe_path(value.get("path"), f"{field}.path"))
    require(roles & BPF_ROLES, "BPF metadata or SKIP JSON role is required")
    artifacts = data.get("artifacts")
    if not isinstance(artifacts, list) or not artifacts:
        raise ManifestError("artifacts must be a non-empty list")
    for index, item in enumerate(artifacts):
        role = validate_ref(item, f"artifacts[{index}]")
        roles.add(role)
        if isinstance(item, dict):
            artifact_paths.append(safe_path(item.get("path"), f"artifacts[{index}].path"))
    missing = sorted(REQUIRED_ROLES - roles)
    require(not missing, "missing required artifact role(s): " + ", ".join(missing))
    benchmark = data.get("benchmark_provenance")
    if not isinstance(benchmark, list) or not benchmark:
        raise ManifestError("benchmark_provenance must be a non-empty list")
    for index, item in enumerate(benchmark):
        require(validate_ref(item, f"benchmark_provenance[{index}]") == "benchmark-provenance", f"benchmark_provenance[{index}] must use benchmark-provenance role")
        if isinstance(item, dict):
            artifact_paths.append(safe_path(item.get("path"), f"benchmark_provenance[{index}].path"))
    validate_privacy(data.get("privacy_scan"))
    validate_attestation(data.get("attestation"))
    tracked_sources(data.get("required_sources"))
    for artifact_path in artifact_paths:
        reject_claims(artifact_path)


def validate_privacy(value: JsonValue | None) -> None:
    if not isinstance(value, dict):
        raise ManifestError("privacy_scan must be an object")
    only_fields(value, PRIVACY_FIELDS, "privacy_scan")
    require(value.get("status") == "PASS" and value.get("private_fields_found") is False, "privacy scan must pass without private fields")
    paths = value.get("artifact_paths")
    require(isinstance(paths, list) and bool(paths), "privacy_scan.artifact_paths must be non-empty")
    for index, item in enumerate(paths):
        _ = safe_path(item, f"privacy_scan.artifact_paths[{index}]")


def validate_attestation(value: JsonValue | None) -> None:
    if not isinstance(value, dict):
        raise ManifestError("attestation must be an object")
    only_fields(value, ATTEST_FIELDS, "attestation")
    require(text(value.get("status"), "attestation.status") in ATTEST_STATUSES, "attestation.status is unsupported")
    require("actions/attest-build-provenance" in text(value.get("workflow_uses"), "attestation.workflow_uses"), "attestation workflow action is missing")
    require("gh attestation verify" in text(value.get("verify_command"), "attestation.verify_command"), "attestation verify command is missing")
    require(isinstance(value.get("retention_days"), int) and value.get("retention_days") > 0, "attestation.retention_days must be positive")


def self_test(schema: Path) -> None:
    from evidence_manifest_selftest import run_self_test

    run_self_test(schema)


def main(argv: list[str]) -> int:
    try:
        args = parse_args(argv)
        if args.self_test:
            self_test(args.schema)
        elif args.manifest is not None:
            validate_manifest(args.manifest, args.schema)
            print(f"PASS evidence manifest: {args.manifest}")
        return 0
    except ManifestError as exc:
        print(f"FAIL evidence manifest: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
