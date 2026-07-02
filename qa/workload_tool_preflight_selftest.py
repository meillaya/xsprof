#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
# ─── How to run ───
# python3 qa/workload_tool_preflight_selftest.py --self-test
"""Host-safe protected workload tool preflight artifact self-test."""
from __future__ import annotations

import copy
import hashlib
import json
import os
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from tempfile import TemporaryDirectory
from typing import Literal

PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from qa.workload_tool_preflight_artifact import (  # noqa: E402
    ACCEPTABLE_PROBE_RCS,
    PATH_REDACTION,
    REQUIRED_TOOLS,
    SCHEMA,
    JsonObject,
    JsonValue,
    WorkloadTool,
    WorkloadToolPreflightError,
    json_list,
    obj,
    parse_out_path,
    rel_or_public_path,
    require,
    validate_artifact,
)


@dataclass(frozen=True, slots=True)
class CliArgs:
    mode: Literal["self-test", "out"]
    missing: WorkloadTool | None = None
    out: Path | None = None


@dataclass(frozen=True, slots=True)
class ProbeResult:
    rc: int
    output_sha256: str
    first_line: str


def file_sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def resolve_safe_executable(name: str, artifact_root: Path, context: str) -> Path:
    found = shutil.which(name)
    if found is None:
        raise WorkloadToolPreflightError(f"missing required executable: {name}")
    raw = Path(found)
    require(".." not in raw.parts, f"{context} must not traverse before execution: {found}")
    resolved = raw.resolve(strict=True)
    require(resolved.is_file(), f"{context} is not a file: {resolved}")
    _ = rel_or_public_path(resolved.as_posix(), artifact_root, context)
    return resolved


def redact_first_line(raw: bytes) -> str:
    lines = [line.strip() for line in raw.decode("utf-8", errors="replace").splitlines()]
    line = next((line for line in lines if line), "")
    redacted = PATH_REDACTION.sub("[redacted-path]", line)[:120].strip()
    return redacted or "no-output"


def run_probe(exe: Path, arg: str) -> ProbeResult:
    try:
        completed = subprocess.run([exe.as_posix(), arg], check=False, text=False, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=5)
    except subprocess.TimeoutExpired as exc:
        raise WorkloadToolPreflightError(f"probe timed out for {exe.name} {arg}") from exc
    output = completed.stdout
    return ProbeResult(completed.returncode, hashlib.sha256(output).hexdigest(), redact_first_line(output))


def require_usable_probe(tool: WorkloadTool, label: str, probe: ProbeResult) -> None:
    require(probe.rc in ACCEPTABLE_PROBE_RCS, f"{tool} {label} probe failed with unusable read-only exit code: {probe.rc}")


def dependency_summary(exe: Path, artifact_root: Path) -> JsonObject:
    try:
        ldd = resolve_safe_executable("ldd", artifact_root, "ldd.path")
    except WorkloadToolPreflightError:
        return {"status": "unavailable", "count": 0, "summary_sha256": hashlib.sha256(b"").hexdigest()}
    completed = subprocess.run([ldd.as_posix(), exe.as_posix()], check=False, text=False, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=5)
    output = completed.stdout
    status = "present" if completed.returncode == 0 else "script_or_static"
    return {"status": status, "count": len(output.splitlines()) if completed.returncode == 0 else 0, "summary_sha256": hashlib.sha256(output).hexdigest()}


def probe_tool(tool: WorkloadTool, artifact_root: Path, forced_missing: str | None) -> JsonObject:
    require(forced_missing != tool, f"forced missing required tool: {tool}")
    exe = resolve_safe_executable(tool, artifact_root, f"tools.{tool}.path")
    version = run_probe(exe, "--version")
    help_probe = run_probe(exe, "--help")
    require_usable_probe(tool, "--version", version)
    require_usable_probe(tool, "--help", help_probe)
    return {
        "name": tool,
        "available": True,
        "path": rel_or_public_path(exe.as_posix(), artifact_root, f"tools.{tool}.path"),
        "sha256": file_sha256(exe),
        "version_probe": {"rc": version.rc, "output_sha256": version.output_sha256, "first_line": version.first_line},
        "help_probe": {"rc": help_probe.rc, "output_sha256": help_probe.output_sha256, "first_line": help_probe.first_line},
        "dynamic_dependencies": dependency_summary(exe, artifact_root),
    }


def verify_tar_zstd(root: Path) -> JsonObject:
    source = root / "tar-zstd" / "file.txt"
    archive = root / "tar-zstd" / "round-trip.tar.zst"
    source.parent.mkdir(parents=True, exist_ok=True)
    _ = source.write_text("ok\n", encoding="utf-8")
    tar = resolve_safe_executable("tar", root, "tar_zstd.path")
    create = subprocess.run([tar.as_posix(), "--zstd", "-cf", archive.as_posix(), "-C", source.parent.as_posix(), source.name], check=False, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=10)
    require(create.returncode == 0, f"tar --zstd create failed: {create.stdout.strip()}")
    listing = subprocess.run([tar.as_posix(), "--zstd", "-tf", archive.as_posix()], check=False, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=10)
    require(listing.returncode == 0 and source.name in listing.stdout.splitlines(), "tar --zstd list round trip failed")
    return {"status": "PASS", "path": rel_or_public_path(tar.as_posix(), root, "tar_zstd.path"), "archive_sha256": file_sha256(archive)}


def build_preflight(root: Path, forced_missing: str | None) -> JsonObject:
    tools: list[JsonValue] = [probe_tool(tool, root, forced_missing) for tool in REQUIRED_TOOLS]
    return {"schema": SCHEMA, "status": "PASS", "tools": tools, "tar_zstd": verify_tar_zstd(root), "host_mutation": False, "release_eligible": False, "production_capacity_claim": False}


def write_fake_tool(path: Path, name: str) -> None:
    body = f"#!/bin/sh\ncase \"$1\" in\n  --version) echo '{name} selftest 1.0' ;;\n  --help) echo 'usage: {name} [--version|--help]' ;;\n  *) echo 'refusing workload execution in preflight selftest' >&2; exit 64 ;;\nesac\n"
    _ = path.write_text(body, encoding="utf-8")
    path.chmod(0o755)


def expect_reject(data: JsonObject, label: str) -> None:
    try:
        validate_artifact(data)
    except WorkloadToolPreflightError as exc:
        _ = print(f"PASS reject {label}: {exc}")
        return
    raise WorkloadToolPreflightError(f"expected rejection did not occur: {label}")


def run_self_test(missing: str | None) -> None:
    with TemporaryDirectory(prefix="zigsched-workload-preflight-") as temp:
        root = Path(temp)
        bin_dir = root / "tools"
        bin_dir.mkdir()
        for tool in REQUIRED_TOOLS:
            if tool != missing:
                write_fake_tool(bin_dir / tool, tool)
        original_path = os.environ.get("PATH", "")
        os.environ["PATH"] = f"{bin_dir}{os.pathsep}{original_path}"
        try:
            data = build_preflight(root, os.environ.get("ZIGSCHED_FORCE_MISSING_WORKLOAD_TOOL") or missing)
            validate_artifact(data)
            bad_missing = copy.deepcopy(data)
            bad_missing["tools"] = [item for item in json_list(data.get("tools"), "selftest tools") if isinstance(item, dict) and item.get("name") != "cyclictest"]
            expect_reject(bad_missing, "missing required tool record")
            bad_duplicate = copy.deepcopy(data)
            duplicate_tools = json_list(bad_duplicate.get("tools"), "bad_duplicate.tools")
            require(bool(duplicate_tools), "self-test setup missing tool records")
            duplicate_tools[-1] = copy.deepcopy(duplicate_tools[0])
            expect_reject(bad_duplicate, "duplicate required tool record")
            bad_nonzero_probe = copy.deepcopy(data)
            obj(obj(json_list(bad_nonzero_probe.get("tools"), "bad_nonzero_probe.tools")[0], "bad_nonzero_probe.tool").get("version_probe"), "bad_nonzero_probe.version_probe")["rc"] = 127
            expect_reject(bad_nonzero_probe, "nonzero probe rc")
            bad_bool_probe = copy.deepcopy(data)
            obj(obj(json_list(bad_bool_probe.get("tools"), "bad_bool_probe.tools")[0], "bad_bool_probe.tool").get("version_probe"), "bad_bool_probe.version_probe")["rc"] = False
            expect_reject(bad_bool_probe, "boolean probe rc")
            bad_path = copy.deepcopy(data)
            bad_tools = json_list(bad_path.get("tools"), "bad_path.tools")
            require(bool(bad_tools), "self-test setup missing tool records")
            obj(bad_tools[0], "bad_path.tools[0]")["path"] = "../escape/stress-ng"
            expect_reject(bad_path, "unsafe traversing path")
            bad_probe = copy.deepcopy(data)
            obj(obj(json_list(bad_probe.get("tools"), "bad_probe.tools")[0], "bad_probe.tool").get("version_probe"), "bad_probe.version_probe")["first_line"] = ""
            expect_reject(bad_probe, "empty probe first line")
            bad_sha = copy.deepcopy(data)
            obj(json_list(bad_sha.get("tools"), "bad_sha.tools")[0], "bad_sha.tool")["sha256"] = "not-a-sha"
            expect_reject(bad_sha, "non-hex tool sha")
            bad_deps = copy.deepcopy(data)
            bad_dep_record = obj(obj(json_list(bad_deps.get("tools"), "bad_deps.tools")[0], "bad_deps.tool").get("dynamic_dependencies"), "bad_deps.dynamic_dependencies")
            bad_dep_record["status"] = "present"
            bad_dep_record["count"] = 0
            expect_reject(bad_deps, "dependency count consistency")
            bad_release = copy.deepcopy(data)
            bad_release["release_eligible"] = True
            expect_reject(bad_release, "release boolean")
        finally:
            os.environ["PATH"] = original_path
    _ = print("PASS workload tool preflight self-test: required tools, missing-tool rejection, duplicate records, nonzero and boolean probe rc, safe paths, tar --zstd round trip, non-release booleans, and privacy-safe artifact verified")


def write_real_artifact(out: Path) -> None:
    with TemporaryDirectory(prefix="zigsched-workload-preflight-real-") as temp:
        data = build_preflight(Path(temp), None)
    validate_artifact(data)
    out.parent.mkdir(parents=True, exist_ok=True)
    _ = out.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    _ = print(f"PASS workload tool preflight artifact: {out.as_posix()}")


def parse_args(argv: list[str]) -> CliArgs:
    match argv:  # noqa: RUF100  # noqa: MATCH_OK
        case ["--self-test"]:
            return CliArgs("self-test")
        case ["--self-test-missing", tool] if tool in REQUIRED_TOOLS:
            return CliArgs("self-test", tool)
        case ["--self-test-missing", tool]:
            raise WorkloadToolPreflightError(f"unsupported missing tool self-test: {tool}")
        case ["--out", raw]:
            return CliArgs("out", out=parse_out_path(raw))
        case _:
            raise WorkloadToolPreflightError("usage: workload_tool_preflight_selftest.py --self-test | --self-test-missing <tool> | --out <relative evidence path>")


def main(argv: list[str]) -> int:
    try:
        args = parse_args(argv)
        match args.mode:  # noqa: RUF100  # noqa: MATCH_OK
            case "self-test":
                run_self_test(args.missing)
            case "out":
                if args.out is None:
                    raise WorkloadToolPreflightError("--out path missing")
                write_real_artifact(args.out)
    except (OSError, subprocess.SubprocessError, WorkloadToolPreflightError, json.JSONDecodeError) as exc:
        _ = print(f"FAIL workload tool preflight: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
