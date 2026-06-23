# /// script
# requires-python = ">=3.11"
# ///
# ─── How to run ───
# python3 qa/package_manifest_check.py --manifest zig-out/package/manifest.json

from __future__ import annotations

import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Final

REQUIRED_FILES: Final[set[str]] = {
    "usr/bin/zig-scheduler",
    "usr/bin/zig-scheduler-daemon",
    "usr/bin/zig-scheduler-linux-preflight",
    "etc/zig-scheduler/default.toml",
    "usr/lib/systemd/system/zig-scheduler-daemon.service",
    "usr/lib/systemd/system/zig-scheduler-preflight.service",
    "usr/lib/systemd/system/zig-scheduler-lab-mutation.service",
}
FORBIDDEN_EXACT_PATH_SEGMENTS: Final[frozenset[str]] = frozenset({
    "browser",
    "browser-ui",
    "browser_ui",
    "desktop",
    "front-end",
    "front_end",
    "frontend",
    "simulator",
    "tui",
    "ui",
    "web-view",
    "web_view",
    "webview",
})
FORBIDDEN_PATH_TERMS: Final[tuple[str, ...]] = (
    "browser",
    "browser-ui",
    "browser_ui",
    "desktop",
    "front-end",
    "front_end",
    "frontend",
    "simulator",
    "web-view",
    "web_view",
    "webview",
)
FORBIDDEN_CANONICAL_PATH_TERMS: Final[frozenset[str]] = frozenset({
    "browserui",
    "frontend",
    "webview",
})
FORBIDDEN_PROJECT_FRONTEND_FILENAMES: Final[frozenset[str]] = frozenset({
    "app.css",
    "design.html",
    "live-data.jsx",
})
FORBIDDEN_FRONTEND_BUNDLE_SUFFIXES: Final[tuple[str, ...]] = (
    ".css",
    ".html",
    ".js",
    ".jsx",
    ".mjs",
    ".cjs",
    ".ts",
    ".tsx",
)
FORBIDDEN_PATH_TOKENS: Final[frozenset[str]] = frozenset({
    "browser",
    "desktop",
    "frontend",
    "simulator",
    "tui",
    "ui",
    "webview",
})
PATH_TOKEN_SPLIT_RE: Final[re.Pattern[str]] = re.compile(r"[^a-z0-9]+")
PATH_CANONICAL_RE: Final[re.Pattern[str]] = re.compile(r"[^a-z0-9]")


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


def forbidden_payload_reason(rel: str) -> str | None:
    lower_parts = tuple(part.lower() for part in Path(rel).parts)
    filename = lower_parts[-1] if lower_parts else ""
    if filename in FORBIDDEN_PROJECT_FRONTEND_FILENAMES:
        return filename
    for suffix in FORBIDDEN_FRONTEND_BUNDLE_SUFFIXES:
        if filename.endswith(suffix):
            return suffix
    for part in lower_parts:
        if part in FORBIDDEN_EXACT_PATH_SEGMENTS:
            return part
        canonical_part = PATH_CANONICAL_RE.sub("", part)
        if canonical_part in FORBIDDEN_CANONICAL_PATH_TERMS:
            return part
        for token in PATH_TOKEN_SPLIT_RE.split(part):
            if token in FORBIDDEN_PATH_TOKENS:
                return token
    lower_rel = "/".join(lower_parts)
    for term in FORBIDDEN_PATH_TERMS:
        if term in lower_rel:
            return term
    canonical_rel = PATH_CANONICAL_RE.sub("", lower_rel)
    for term in FORBIDDEN_CANONICAL_PATH_TERMS:
        if term in canonical_rel:
            return term
    return None


def current_git_sha() -> str:
    try:
        return subprocess.check_output(("git", "rev-parse", "HEAD"), text=True).strip()
    except (FileNotFoundError, subprocess.CalledProcessError) as exc:
        raise PackageManifestError("could not read current git SHA") from exc

def run(argv: list[str]) -> int:
    manifest_path = parse_manifest_arg(argv)
    raw = json.loads(manifest_path.read_text())
    require(isinstance(raw, dict), "manifest must be a JSON object")
    data = raw
    require(data.get("schema") == "zig-scheduler/package-manifest/v1", "bad schema")
    require(data.get("git_sha") == current_git_sha(), "manifest git_sha is stale")
    require(data.get("milestone") == "vm_lab_backend_readiness", "package milestone must be VM/lab backend readiness")
    require(data.get("production_ready") is False, "package must not claim production readiness")
    require(data.get("arbitrary_host_safe") is False, "package must not claim arbitrary-host safety")
    require(data.get("out_of_scope_artifacts_included") is False, "package includes out-of-scope artifacts")
    require(data.get("simulator_artifacts_included") is False, "package includes simulator artifacts")
    require(data.get("no_auto_start") is True, "package may auto-start")
    require(data.get("services_not_enabled") is True, "services may be enabled")
    require(data.get("mutation_service_gated") is True, "mutation service is not gated")
    require(data.get("mutation_service_has_wanted_by") is False, "mutation service has WantedBy")
    install_root = Path(str(data.get("install_root", "")))
    require(install_root.is_dir(), "install root missing")
    files = data.get("files")
    require(isinstance(files, list), "manifest files must be a list")
    seen: set[str] = set()
    for index, item in enumerate(files):
        require(isinstance(item, dict), f"file[{index}] must be an object")
        rel_value = item.get("path")
        require(isinstance(rel_value, str), f"file[{index}] path must be text")
        rel = rel_value
        digest = item.get("sha256")
        require(isinstance(digest, str) and len(digest) == 64, f"file[{index}] sha256 must be a digest")
        safe_relative = rel != "" and not rel.startswith("/") and ".." not in Path(rel).parts
        require(safe_relative, f"unsafe file path: {rel}")
        forbidden_reason = forbidden_payload_reason(rel)
        require(forbidden_reason is None, f"forbidden package payload ({forbidden_reason}): {rel}")
        path = install_root / rel
        require(path.is_file(), f"missing packaged file: {rel}")
        require(file_digest(path) == digest, f"checksum mismatch: {rel}")
        seen.add(rel)
    missing = sorted(REQUIRED_FILES - seen)
    require(not missing, "missing required package files: " + ",".join(missing))
    daemon_unit = install_root / "usr/lib/systemd/system/zig-scheduler-daemon.service"
    daemon_text = daemon_unit.read_text()
    require("ExecStart=/usr/bin/zig-scheduler-daemon --foreground --state-dir daemon" in daemon_text, "daemon service command is unsupported")
    require("WantedBy=" not in daemon_text, "daemon service install-enables by default")
    require("CapabilityBoundingSet=" in daemon_text, "daemon service must not keep capabilities")
    mutation_unit = install_root / "usr/lib/systemd/system/zig-scheduler-lab-mutation.service"
    mutation_text = mutation_unit.read_text()
    require("WantedBy=" not in mutation_text, "mutation service install-enables by default")
    require("[Install]" not in mutation_text, "mutation service has install section")
    config_text = (install_root / "etc/zig-scheduler/default.toml").read_text()
    require('release_scope = "vm-lab-backend-only"' in config_text, "default config missing VM/lab scope")
    require("production_ready = false" in config_text, "default config claims production readiness")
    require("arbitrary_host_safe = false" in config_text, "default config claims arbitrary-host safety")
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
