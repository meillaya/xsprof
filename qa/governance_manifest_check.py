#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
# ─── How to run ───
# python3 qa/governance_manifest_check.py --manifest fixtures/lab/governance-sources.json
from __future__ import annotations

from dataclasses import dataclass
from hashlib import sha256
from pathlib import Path
import json
import os
import subprocess
import sys
from typing import Final, NotRequired, TypedDict


SCHEMA_VERSION: Final[int] = 1
REQUIRED_SOURCE_PATHS: Final[tuple[str, ...]] = (
    "AGENTS.md",
    "README.md",
    "WORKLOG.md",
    "docs/security/threat-model.md",
    "docs/releases/governance-gate.md",
    "qa/clean_archive_check.sh",
    "qa/governance_manifest_check.py",
    "qa/release_gate.sh",
    "qa/security_gate.sh",
    "qa/wording_audit.sh",
)


class SourceJson(TypedDict):
    path: str
    purpose: str
    required: bool
    sha256: str


class ManifestJson(TypedDict):
    schema_version: int
    generated_for: NotRequired[str]
    sources: list[SourceJson]


@dataclass(frozen=True, slots=True)
class Args:
    manifest: Path
    require_production_matrix: bool


@dataclass(frozen=True, slots=True)
class Source:
    path: Path
    purpose: str
    required: bool
    digest: str


class ManifestError(Exception):
    """Raised when the governance manifest is malformed or stale."""


def parse_args(argv: list[str]) -> Args:
    if not argv:
        raise ManifestError("usage: governance_manifest_check.py --manifest <path>")
    manifest = Path("fixtures/lab/governance-sources.json")
    require_production_matrix = False
    index = 0
    while index < len(argv):
        arg = argv[index]
        if arg == "--manifest":
            index += 1
            if index >= len(argv):
                raise ManifestError("--manifest requires a path")
            manifest = Path(argv[index])
        elif arg == "--require-production-matrix":
            require_production_matrix = True
        else:
            raise ManifestError("usage: governance_manifest_check.py [--manifest <path>] [--require-production-matrix]")
        index += 1
    return Args(manifest=manifest, require_production_matrix=require_production_matrix)


def parse_manifest(path: Path) -> list[Source]:
    try:
        raw = json.loads(path.read_text())
    except FileNotFoundError as exc:
        raise ManifestError(f"missing governance manifest: {path}") from exc
    except json.JSONDecodeError as exc:
        raise ManifestError(f"invalid governance manifest JSON: {exc}") from exc
    if not isinstance(raw, dict):
        raise ManifestError("governance manifest must be a JSON object")
    schema_version = raw.get("schema_version")
    if schema_version != SCHEMA_VERSION:
        raise ManifestError(f"unsupported governance manifest schema_version: {schema_version!r}")
    sources = raw.get("sources")
    if not isinstance(sources, list) or len(sources) == 0:
        raise ManifestError("governance manifest must contain non-empty sources")
    parsed: list[Source] = []
    seen: set[str] = set()
    for index, item in enumerate(sources):
        if not isinstance(item, dict):
            raise ManifestError(f"source[{index}] must be an object")
        path_value = item.get("path")
        purpose = item.get("purpose")
        required = item.get("required")
        digest = item.get("sha256")
        if not isinstance(path_value, str) or path_value == "" or path_value.startswith("/"):
            raise ManifestError(f"source[{index}] has invalid relative path")
        if path_value in seen:
            raise ManifestError(f"duplicate governance source: {path_value}")
        seen.add(path_value)
        if not isinstance(purpose, str) or purpose == "":
            raise ManifestError(f"source[{path_value}] has invalid purpose")
        if not isinstance(required, bool):
            raise ManifestError(f"source[{path_value}] has invalid required flag")
        if not isinstance(digest, str) or len(digest) != 64:
            raise ManifestError(f"source[{path_value}] has invalid sha256")
        parsed.append(Source(Path(path_value), purpose, required, digest))
    paths = {source.path.as_posix() for source in parsed}
    for required_path in REQUIRED_SOURCE_PATHS:
        if required_path not in paths:
            raise ManifestError(f"missing tracked governance source manifest entry: {required_path}")
    return parsed


def git_tracked_files() -> set[str]:
    result = subprocess.run(
        ["git", "ls-files"],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        raise ManifestError(f"git ls-files failed: {result.stderr.strip()}")
    return set(result.stdout.splitlines())


def git_check_ignore(path: Path) -> bool:
    result = subprocess.run(
        ["git", "check-ignore", str(path)],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return result.returncode == 0


def archive_mode_allowed() -> bool:
    return os.environ.get("ZIG_SCHEDULER_GOVERNANCE_ARCHIVE_OK") == "1"


def validate_sources(sources: list[Source]) -> None:
    tracked: set[str] = set() if archive_mode_allowed() else git_tracked_files()
    for source in sources:
        path_text = source.path.as_posix()
        if source.required and not archive_mode_allowed() and path_text not in tracked:
            raise ManifestError(f"missing tracked governance source: {path_text}")
        if source.required and not archive_mode_allowed() and git_check_ignore(source.path):
            raise ManifestError(f"missing tracked governance source (ignored): {path_text}")
        try:
            content = source.path.read_bytes()
        except FileNotFoundError as exc:
            raise ManifestError(f"missing tracked governance source: {path_text}") from exc
        actual = sha256(content).hexdigest()
        if actual != source.digest:
            raise ManifestError(f"governance source hash mismatch: {path_text}")


PRODUCTION_MATRIX_TERMS: Final[tuple[tuple[str, str], ...]] = (
    ("kernel tuple matrix", "kernel tuple matrix"),
    ("verifier logs", "verifier log"),
    ("VM attach evidence", "vm-only partial-switch attach"),
    ("rollback drills", "rollback drill"),
    ("stress and chaos", "stress/chaos"),
    ("audit ledger", "audit ledger"),
    ("security signoff", "security signoff"),
    ("package install safety", "package install"),
    ("package upgrade safety", "package upgrade"),
    ("package uninstall safety", "package uninstall"),
    ("incident runbook", "incident runbook"),
    ("privacy review", "privacy review"),
    ("systemd no auto-start", "no auto-start"),
)


def require_text(path: Path, needle: str, label: str) -> None:
    try:
        haystack = path.read_text().lower()
    except FileNotFoundError as exc:
        raise ManifestError(f"missing production matrix source: {path}") from exc
    if needle.lower() not in haystack:
        raise ManifestError(f"production evidence matrix missing {label}: {path}")


def validate_production_matrix() -> None:
    gate = Path("docs/releases/governance-gate.md")
    checklist = Path("docs/security/review-checklist.md")
    release_summary = Path("evidence/releases/0.2.0-lab/summary.json")
    for label, needle in PRODUCTION_MATRIX_TERMS:
        require_text(gate, needle, label)
    require_text(checklist, "security signoff", "security signoff checklist")
    require_text(checklist, "privacy review", "privacy review checklist")
    try:
        summary = json.loads(release_summary.read_text())
    except FileNotFoundError as exc:
        raise ManifestError(f"missing release summary: {release_summary}") from exc
    if summary.get("production_ready") is not False:
        raise ManifestError("current release summary must keep production_ready=false")
    if summary.get("arbitrary_host_safe") is not False:
        raise ManifestError("current release summary must keep arbitrary_host_safe=false")
    if summary.get("release_status") != "controlled_lab_pilot_candidate":
        raise ManifestError("current release summary must remain controlled_lab_pilot_candidate")


def run(argv: list[str]) -> int:
    args = parse_args(argv)
    sources = parse_manifest(args.manifest)
    validate_sources(sources)
    if args.require_production_matrix:
        validate_production_matrix()
    required = sum(1 for source in sources if source.required)
    print(f"PASS governance manifest: {args.manifest} required_sources={required} total_sources={len(sources)}")
    return 0


def main() -> int:
    try:
        return run(sys.argv[1:])
    except ManifestError as exc:
        print(f"FAIL governance manifest: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
