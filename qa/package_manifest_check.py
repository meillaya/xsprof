# /// script
# requires-python = ">=3.11"
# ///
# ─── How to run ───
# python3 qa/package_manifest_check.py --manifest zig-out/package/manifest.json

from __future__ import annotations

import hashlib
import json
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Final

REQUIRED_FILES: Final[set[str]] = {
    "usr/bin/zig-scheduler",
    "usr/bin/zig-scheduler-linux-preflight",
    "usr/bin/zig-scheduler-tui",
    "etc/zig-scheduler/default.toml",
    "usr/lib/systemd/system/zig-scheduler-preflight.service",
    "usr/lib/systemd/system/zig-scheduler-lab-mutation.service",
}


@dataclass(frozen=True, slots=True)
class PackageIssue:
    message: str


class PackageManifestError(Exception):
    """Raised when a package manifest is unsafe or stale."""


def parse_manifest_arg(argv: list[str]) -> Path:
    if len(argv) != 2 or argv[0] != "--manifest":
        raise PackageManifestError("usage: package_manifest_check.py --manifest <path>")
    return Path(argv[1])


def file_digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise PackageManifestError(message)


def run(argv: list[str]) -> int:
    manifest_path = parse_manifest_arg(argv)
    data = json.loads(manifest_path.read_text())
    require(data.get("schema") == "zig-scheduler/package-manifest/v1", "bad schema")
    require(data.get("no_auto_start") is True, "package may auto-start")
    require(data.get("services_not_enabled") is True, "services may be enabled")
    require(data.get("mutation_service_gated") is True, "mutation service is not gated")
    require(data.get("mutation_service_has_wanted_by") is False, "mutation service has WantedBy")
    install_root = Path(str(data.get("install_root", "")))
    require(install_root.is_dir(), "install root missing")
    seen: set[str] = set()
    for item in data.get("files", []):
        rel = str(item.get("path", ""))
        safe_relative = rel != "" and not rel.startswith("/") and ".." not in Path(rel).parts
        require(safe_relative, f"unsafe file path: {rel}")
        path = install_root / rel
        require(path.is_file(), f"missing packaged file: {rel}")
        require(file_digest(path) == item.get("sha256"), f"checksum mismatch: {rel}")
        seen.add(rel)
    missing = sorted(REQUIRED_FILES - seen)
    require(not missing, "missing required package files: " + ",".join(missing))
    mutation_unit = install_root / "usr/lib/systemd/system/zig-scheduler-lab-mutation.service"
    require("WantedBy=" not in mutation_unit.read_text(), "mutation service install-enables by default")
    print(f"PASS package manifest: {manifest_path} files={len(seen)}")
    return 0


def main() -> int:
    try:
        return run(sys.argv[1:])
    except (OSError, json.JSONDecodeError, PackageManifestError) as exc:
        print(f"FAIL package manifest: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
