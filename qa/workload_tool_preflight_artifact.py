"""Validation helpers for workload tool preflight artifacts."""
from __future__ import annotations

import hashlib
import re
from pathlib import Path
from typing import Final, Literal, TypeAlias

JsonValue: TypeAlias = None | bool | int | float | str | list["JsonValue"] | dict[str, "JsonValue"]
JsonObject: TypeAlias = dict[str, JsonValue]
WorkloadTool: TypeAlias = Literal["stress-ng", "cyclictest", "perf", "taskset", "chrt"]

SCHEMA: Final[str] = "zig-scheduler/workload-tool-preflight/v1"
REQUIRED_TOOLS: Final[tuple[WorkloadTool, ...]] = ("stress-ng", "cyclictest", "perf", "taskset", "chrt")
SAFE_ABSOLUTE_PREFIXES: Final[tuple[str, ...]] = ("/bin/", "/usr/bin/", "/usr/sbin/", "/sbin/", "/nix/store/")
PRIVATE_NEEDLES: Final[tuple[str, ...]] = ("argv", "environment", "secret", "api_key", "token", "password", "authorization", "bearer")
HEX_DIGITS: Final[frozenset[str]] = frozenset("0123456789abcdef")
ALLOWED_OUT_ROOTS: Final[tuple[str, ...]] = ("evidence/lab/", ".omo/evidence/")
PATH_REDACTION: Final[re.Pattern[str]] = re.compile(r"(?<![\w.-])(?:~|/[A-Za-z0-9._+@%=-][^\s:;,)\]}>\"']*)")
# Documented acceptable read-only probe exit codes. Keep this table narrow:
# rc=127 means the executable could not run (for example a missing dynamic loader
# dependency), so it must never be treated as available evidence.
ACCEPTABLE_PROBE_RCS: Final[tuple[int, ...]] = (0,)


class WorkloadToolPreflightError(Exception):
    """Raised when workload tool preflight evidence is unsafe or incomplete."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise WorkloadToolPreflightError(message)


def text(value: JsonValue | None, context: str) -> str:
    if not isinstance(value, str) or value == "":
        raise WorkloadToolPreflightError(f"{context} must be non-empty text")
    return value


def obj(value: JsonValue | None, context: str) -> JsonObject:
    if not isinstance(value, dict):
        raise WorkloadToolPreflightError(f"{context} must be an object")
    return value


def json_list(value: JsonValue | None, context: str) -> list[JsonValue]:
    if not isinstance(value, list):
        raise WorkloadToolPreflightError(f"{context} must be a list")
    return value


def is_hex_sha256(raw: str) -> bool:
    return len(raw) == 64 and all(char in HEX_DIGITS for char in raw)


def rel_or_public_path(raw: str, artifact_root: Path, context: str) -> str:
    path = Path(raw)
    require(".." not in path.parts, f"{context} must not traverse: {raw}")
    if not path.is_absolute():
        require(path.as_posix() == raw, f"{context} must use posix separators: {raw}")
        return raw
    try:
        return path.resolve().relative_to(artifact_root.resolve()).as_posix()
    except ValueError:
        require(raw.startswith(SAFE_ABSOLUTE_PREFIXES), f"{context} absolute path is not public tool provenance: {raw}")
        return raw


def validate_path(value: JsonValue | None, context: str) -> None:
    raw = text(value, context)
    path = Path(raw)
    require(".." not in path.parts, f"{context} must not traverse")
    if path.is_absolute():
        require(raw.startswith(SAFE_ABSOLUTE_PREFIXES), f"{context} must be public tool provenance")


def validate_probe(value: JsonValue | None, context: str) -> None:
    probe = obj(value, context)
    raw_rc = probe.get("rc")
    require(type(raw_rc) is int, f"{context}.rc must be an integer")
    rc = raw_rc
    require(rc in ACCEPTABLE_PROBE_RCS, f"{context}.rc must be a usable read-only probe exit code; got {rc}")
    digest = text(probe.get("output_sha256"), f"{context}.output_sha256")
    require(is_hex_sha256(digest), f"{context}.output_sha256 must be hex sha256")
    require(digest != hashlib.sha256(b"").hexdigest(), f"{context}.output_sha256 must not be empty output evidence")
    first_line = text(probe.get("first_line"), f"{context}.first_line")
    require(first_line != "no-output", f"{context}.first_line must show non-empty probe evidence")
    require("[redacted-path]" in first_line or not PATH_REDACTION.search(first_line), f"{context}.first_line contains an unredacted path")


def validate_dependencies(value: JsonValue | None, context: str) -> None:
    deps = obj(value, context)
    status = text(deps.get("status"), f"{context}.status")
    require(status in ("present", "script_or_static", "unavailable"), f"{context}.status invalid")
    raw_count = deps.get("count")
    if type(raw_count) is not int or raw_count < 0:
        raise WorkloadToolPreflightError(f"{context}.count must be a non-negative integer")
    count = raw_count
    digest = text(deps.get("summary_sha256"), f"{context}.summary_sha256")
    require(is_hex_sha256(digest), f"{context}.summary_sha256 must be hex sha256")
    empty_digest = hashlib.sha256(b"").hexdigest()
    if status == "present":
        require(count > 0 and digest != empty_digest, f"{context} present dependencies need count and digest evidence")
    if status == "unavailable":
        require(count == 0 and digest == empty_digest, f"{context} unavailable dependencies must have empty evidence")


def reject_private_text(value: JsonValue, context: str) -> None:
    match value:  # noqa: RUF100  # noqa: MATCH_OK
        case dict():
            for key, child in value.items():
                lowered = key.lower()
                require(not any(needle in lowered for needle in PRIVATE_NEEDLES), f"privacy-unsafe key: {context}.{key}")
                reject_private_text(child, f"{context}.{key}")
        case list():
            for index, child in enumerate(value):
                reject_private_text(child, f"{context}[{index}]")
        case str():
            lowered = value.lower()
            require(not any(needle in lowered for needle in PRIVATE_NEEDLES), f"privacy-unsafe text: {context}")
        case None | bool() | int() | float():
            return


def validate_artifact(data: JsonObject) -> None:
    require(data.get("schema") == SCHEMA, "schema mismatch")
    require(data.get("status") == "PASS", "status must be PASS")
    for field in ("host_mutation", "release_eligible", "production_capacity_claim"):
        require(data.get(field) is False, f"{field} must remain false")
    tools_value = json_list(data.get("tools"), "tools")
    require(len(tools_value) == len(REQUIRED_TOOLS), "tools must contain exactly one record per required tool")
    seen: set[str] = set()
    for index, item in enumerate(tools_value):
        tool = obj(item, f"tools[{index}]")
        name = text(tool.get("name"), f"tools[{index}].name")
        require(name in REQUIRED_TOOLS, f"unexpected tool: {name}")
        require(name not in seen, f"duplicate required tool record: {name}")
        require(tool.get("available") is True, f"{name} must be available")
        validate_path(tool.get("path"), f"{name}.path")
        require(is_hex_sha256(text(tool.get("sha256"), f"{name}.sha256")), f"{name}.sha256 must be hex sha256")
        validate_probe(tool.get("version_probe"), f"{name}.version_probe")
        validate_probe(tool.get("help_probe"), f"{name}.help_probe")
        validate_dependencies(tool.get("dynamic_dependencies"), f"{name}.dynamic_dependencies")
        seen.add(name)
    require(seen == set(REQUIRED_TOOLS), "missing required tool record")
    tar_zstd = obj(data.get("tar_zstd"), "tar_zstd")
    require(tar_zstd.get("status") == "PASS", "tar_zstd.status must be PASS")
    validate_path(tar_zstd.get("path"), "tar_zstd.path")
    require(is_hex_sha256(text(tar_zstd.get("archive_sha256"), "tar_zstd.archive_sha256")), "tar_zstd.archive_sha256 must be hex sha256")
    reject_private_text(data, "artifact")


def parse_out_path(raw: str) -> Path:
    path = Path(raw)
    require(not path.is_absolute(), "--out must be relative")
    require(".." not in path.parts, "--out must not traverse")
    posix = path.as_posix()
    require(posix == raw, "--out must use posix separators")
    require(any(posix.startswith(root) for root in ALLOWED_OUT_ROOTS), "--out must be under evidence/lab/ or .omo/evidence/")
    require(path.name != "", "--out must name a JSON artifact")
    return path
