#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
# ─── How to run ───
# python3 qa/zig_docs_vendor_check.py --root docs/vendor/zig-0.16.0
from __future__ import annotations

import hashlib
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Final

REQUIRED_FILES: Final[tuple[str, ...]] = (
    "SOURCE.md",
    "SHA256SUMS",
    "langref/index.html",
    "std/index.html",
    "std/main.js",
    "std/main.wasm",
    "std/sources.tar",
)
REQUIRED_SOURCE_TEXT: Final[tuple[str, ...]] = (
    "https://ziglang.org/documentation/0.16.0/",
    "https://ziglang.org/documentation/0.16.0/std/",
    "Retrieval date",
    "Dynamic stdlib limitations",
)
REQUIRED_SNAPSHOT_TEXT: Final[tuple[tuple[str, str], ...]] = (
    ("langref/index.html", "Zig Language Reference"),
    ("std/index.html", "Zig Documentation"),
    ("std/main.js", "fetch(\"main.wasm\")"),
    ("std/main.js", "fetch(\"sources.tar\")"),
)


@dataclass(frozen=True, slots=True)
class Args:
    root: Path


@dataclass(frozen=True, slots=True)
class ManifestEntry:
    digest: str
    path: Path


class VendorDocsError(Exception):
    """Raised when vendored Zig documentation is missing or stale."""


def parse_args(argv: list[str]) -> Args:
    if len(argv) != 2 or argv[0] != "--root":
        raise VendorDocsError("usage: zig_docs_vendor_check.py --root <vendor-root>")
    return Args(root=Path(argv[1]))


def digest_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def parse_manifest(root: Path) -> list[ManifestEntry]:
    manifest = root / "SHA256SUMS"
    try:
        lines = manifest.read_text().splitlines()
    except FileNotFoundError as exc:
        raise VendorDocsError(f"missing checksum manifest: {manifest}") from exc
    entries: list[ManifestEntry] = []
    seen: set[str] = set()
    for line_number, line in enumerate(lines, start=1):
        if not line.strip():
            continue
        parts = line.split(maxsplit=1)
        if len(parts) != 2:
            raise VendorDocsError(f"malformed checksum line {line_number}")
        digest, rel_path = parts
        if len(digest) != 64 or any(char not in "0123456789abcdef" for char in digest):
            raise VendorDocsError(f"invalid sha256 on line {line_number}")
        clean_rel = rel_path.removeprefix("*").removeprefix("./")
        candidate = Path(clean_rel)
        if candidate.is_absolute() or ".." in candidate.parts or candidate.as_posix() == "":
            raise VendorDocsError(f"unsafe checksum path on line {line_number}: {rel_path}")
        path_text = candidate.as_posix()
        if path_text in seen:
            raise VendorDocsError(f"duplicate checksum path: {path_text}")
        seen.add(path_text)
        entries.append(ManifestEntry(digest=digest, path=candidate))
    if not entries:
        raise VendorDocsError("checksum manifest is empty")
    return entries


def require_file(root: Path, relative_path: str) -> None:
    path = root / relative_path
    if not path.is_file():
        raise VendorDocsError(f"missing required file: {relative_path}")
    if path.stat().st_size == 0:
        raise VendorDocsError(f"empty required file: {relative_path}")


def validate_source(root: Path) -> None:
    source_text = (root / "SOURCE.md").read_text()
    for needle in REQUIRED_SOURCE_TEXT:
        if needle not in source_text:
            raise VendorDocsError(f"SOURCE.md missing required text: {needle}")


def validate_snapshot_text(root: Path) -> None:
    for relative_path, needle in REQUIRED_SNAPSHOT_TEXT:
        text = (root / relative_path).read_text(errors="replace")
        if needle not in text:
            raise VendorDocsError(f"{relative_path} does not look like official Zig docs")


def validate_checksums(root: Path) -> int:
    entries = parse_manifest(root)
    manifest_paths = {entry.path.as_posix() for entry in entries}
    for relative_path in REQUIRED_FILES:
        if relative_path == "SHA256SUMS":
            continue
        if relative_path not in manifest_paths:
            raise VendorDocsError(f"checksum manifest missing: {relative_path}")
    for entry in entries:
        path = root / entry.path
        if not path.is_file():
            raise VendorDocsError(f"checksum entry file missing: {entry.path.as_posix()}")
        actual = digest_file(path)
        if actual != entry.digest:
            raise VendorDocsError(f"checksum mismatch: {entry.path.as_posix()}")
    return len(entries)


def run(argv: list[str]) -> int:
    args = parse_args(argv)
    if not args.root.is_dir():
        raise VendorDocsError(f"vendor root missing or not a directory: {args.root}")
    for relative_path in REQUIRED_FILES:
        require_file(args.root, relative_path)
    validate_source(args.root)
    validate_snapshot_text(args.root)
    checked = validate_checksums(args.root)
    print(f"PASS Zig 0.16.0 vendored docs: root={args.root} checksums={checked}")
    return 0


def main() -> int:
    try:
        return run(sys.argv[1:])
    except (OSError, UnicodeError, VendorDocsError) as exc:
        print(f"FAIL Zig 0.16.0 vendored docs: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
