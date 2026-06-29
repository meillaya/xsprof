#!/usr/bin/env python3
# allow: SIZE_OK -- Single-file CLI checker keeps ABI constants, parsing, fixtures, and exits together.
"""Check the frozen sched_ext BPF ABI contract and metadata evidence."""

from __future__ import annotations

import json
import re
import sys
from dataclasses import dataclass
from hashlib import sha256
from pathlib import Path
from tempfile import TemporaryDirectory
from typing import Final

JsonValue = None | bool | int | float | str | list["JsonValue"] | dict[str, "JsonValue"]
JsonObject = dict[str, JsonValue]

VM_MARKER: Final = "/run/zig-scheduler-vm-lab.marker"
VM_CONTRACT: Final = "qa/vm/execution_contract.json"
POLICY_NAME: Final = "zigsched_minimal"
POLICY_SYMBOL: Final = "zigsched_minimal_ops"
PARTIAL_SWITCH: Final = "SCX_OPS_SWITCH_PARTIAL"
ABI_VERSION: Final = 1
STATS_COUNT: Final = 8
EVENTS_COUNT: Final = 4
EXPECTED_DEFINES: Final = {
    "ZIGSCHED_ABI_VERSION": "1u",
    "ZIGSCHED_MINIMAL_NR_STATS": "8u",
    "ZIGSCHED_MINIMAL_NR_EVENTS": "4u",
    "ZIGSCHED_DSQ_FIFO": "0x5a195f1f0ULL",
    "ZIGSCHED_DSQ_VTIME": "0x5a195f1f1ULL",
    "ZIGSCHED_STARVATION_NS_MAX": "50000000ULL",
    "ZIGSCHED_POLICY_MODE_FIFO": "1ULL",
    "ZIGSCHED_POLICY_MODE_VTIME": "2ULL",
    "SCX_OPS_SWITCH_PARTIAL": "8ULL",
}
EXPECTED_STATS: Final = (
    "ZIGSCHED_STAT_SELECT_CPU_CALLS",
    "ZIGSCHED_STAT_ENQUEUE_CALLS",
    "ZIGSCHED_STAT_DISPATCH_CALLS",
    "ZIGSCHED_STAT_LOCAL_DIRECT_INSERTS",
    "ZIGSCHED_STAT_FIFO_INSERTS",
    "ZIGSCHED_STAT_VTIME_INSERTS",
    "ZIGSCHED_STAT_FIFO_DISPATCHES",
    "ZIGSCHED_STAT_VTIME_DISPATCHES",
)
EXPECTED_EVENTS: Final = (
    "ZIGSCHED_EVENT_SELECT_CPU_FALLBACK",
    "ZIGSCHED_EVENT_DISPATCH_EMPTY",
    "ZIGSCHED_EVENT_INIT_FIFO_DSQ_FAILED",
    "ZIGSCHED_EVENT_INIT_VTIME_DSQ_FAILED",
)
EXPECTED_POLICY_CONFIG_FIELDS: Final = (
    "zigsched_u64 fifo_dsq",
    "zigsched_u64 vtime_dsq",
    "zigsched_u64 starvation_ns_max",
    "zigsched_u64 mode",
)
STRUCT_OPS_USED_FIELDS: Final = ("name", "flags", "init", "enqueue", "dispatch")
REQUIRED_HEADER_TEXT: Final = (
    "#define ZIGSCHED_ABI_VERSION 1u",
    "ZIGSCHED_DSQ_FIFO",
    "ZIGSCHED_DSQ_VTIME",
    "ZIGSCHED_STARVATION_NS_MAX",
    "enum zigsched_stat_index",
    "enum zigsched_event_index",
    "struct zigsched_policy_config",
    "struct sched_ext_ops",
    "SCX_OPS_SWITCH_PARTIAL",
)
REQUIRED_ADR_TEXT: Final = (
    "Policy expansion is blocked",
    "v1 compatibility contract",
    "v2 requires",
    "zigsched_minimal_ops",
    "SCX_OPS_SWITCH_PARTIAL",
    "SCX_OPS_SWITCH_ALL",
    "host_attach_allowed=false",
    "SKIP mode",
    "not a production-readiness claim",
)
PROGRAM_SECTIONS: Final = (
    "struct_ops.s/zigsched_minimal_init",
    "struct_ops/zigsched_minimal_enqueue",
    "struct_ops/zigsched_minimal_dispatch",
)
EXPECTED_MAP_LAYOUTS: Final = {
    "zigsched_stats": {
        "type": "BPF_MAP_TYPE_ARRAY",
        "max_entries": "ZIGSCHED_MINIMAL_NR_STATS",
        "key": "u32",
        "value": "u64",
    },
    "zigsched_events": {
        "type": "BPF_MAP_TYPE_ARRAY",
        "max_entries": "ZIGSCHED_MINIMAL_NR_EVENTS",
        "key": "u32",
        "value": "u64",
    },
    "zigsched_policy_config": {
        "type": "BPF_MAP_TYPE_ARRAY",
        "max_entries": "1",
        "key": "u32",
        "value": "struct zigsched_policy_config",
    },
}


@dataclass(frozen=True, slots=True)
class Args:
    header: Path
    strategy: Path
    metadata: Path
    skip_json: Path | None
    self_test: bool


@dataclass(frozen=True, slots=True)
class AbiSnapshot:
    header_sha256: str
    defines: dict[str, str]
    stats: tuple[str, ...]
    events: tuple[str, ...]
    policy_config_fields: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class SourceMapLayout:
    name: str
    map_type: str
    max_entries: str
    key_type: str
    value_type: str


@dataclass(frozen=True, slots=True)
class SourceAbi:
    source_sha256: str
    map_layouts: tuple[SourceMapLayout, ...]
    program_sections: tuple[str, ...]
    struct_ops_used_fields: tuple[str, ...]
    struct_ops_callbacks: tuple[str, ...]


class BpfAbiError(Exception):
    """Raised when BPF ABI freeze evidence is missing or unsafe."""


def parse_args(argv: list[str]) -> Args:
    if argv == ["--self-test"]:
        return Args(Path("bpf/include/zigsched_common.h"), Path("docs/adr/0004-bpf-abi-strategy.md"), Path("zig-out/bpf/zigsched_minimal.bpf.meta.json"), Path("zig-out/bpf/zigsched_minimal.bpf.skip.json"), True)
    if len(argv) in (6, 8) and argv[:1] == ["--header"] and argv[2] == "--strategy" and argv[4] == "--metadata":
        skip_path = Path(argv[7]) if len(argv) == 8 and argv[6] == "--skip-json" else None
        if len(argv) == 8 and argv[6] != "--skip-json":
            raise BpfAbiError("expected --skip-json before skip path")
        return Args(Path(argv[1]), Path(argv[3]), Path(argv[5]), skip_path, False)
    raise BpfAbiError("usage: bpf_abi_freeze_check.py --header <h> --strategy <adr> --metadata <meta.json> [--skip-json <skip.json>] | --self-test")


def obj(value: JsonValue | None, context: str) -> JsonObject:
    if not isinstance(value, dict):
        raise BpfAbiError(f"{context} must be an object")
    return value


def str_list(value: JsonValue | None, context: str) -> list[str]:
    if not isinstance(value, list):
        raise BpfAbiError(f"{context} must be a list")
    out: list[str] = []
    for item in value:
        if not isinstance(item, str):
            raise BpfAbiError(f"{context} contains a non-string")
        out.append(item)
    return out


def require(condition: bool, message: str) -> None:
    if not condition:
        raise BpfAbiError(message)


def sha256_file(path: Path) -> str:
    digest = sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_text(path: Path, needles: tuple[str, ...], context: str) -> str:
    text = path.read_text()
    missing = [needle for needle in needles if needle not in text]
    if missing:
        raise BpfAbiError(f"{context} missing text: {', '.join(missing)}")
    return text


def load_json(path: Path) -> JsonObject:
    try:
        raw: JsonValue = json.loads(path.read_text())
    except FileNotFoundError as exc:
        raise BpfAbiError(f"missing JSON evidence: {path}") from exc
    except json.JSONDecodeError as exc:
        raise BpfAbiError(f"invalid JSON evidence {path}: {exc}") from exc
    return obj(raw, str(path))


def parse_defines(header_text: str) -> dict[str, str]:
    define_pairs: list[tuple[str, str]] = re.findall(r"^#define\s+(ZIGSCHED_[A-Z0-9_]+|SCX_OPS_SWITCH_PARTIAL)\s+([^\s/]+)", header_text, re.MULTILINE)
    found = dict(define_pairs)
    for name, expected in EXPECTED_DEFINES.items():
        require(found.get(name) == expected, f"{name} changed without ABI acceptance: expected {expected}, got {found.get(name)}")
    return {name: found[name] for name in EXPECTED_DEFINES}


def parse_enum_names(header_text: str, enum_name: str, expected: tuple[str, ...]) -> tuple[str, ...]:
    match = re.search(rf"enum\s+{enum_name}\s*\{{(?P<body>.*?)\}};", header_text, re.DOTALL)
    if match is None:
        raise BpfAbiError(f"missing enum {enum_name}")
    body = match.group("body")
    pairs: list[tuple[str, str]] = re.findall(r"\b(ZIGSCHED_[A-Z0-9_]+)\s*=\s*(\d+)\s*,", body)
    names = tuple(name for name, _value in pairs)
    require(names == expected, f"{enum_name} order changed without ABI acceptance: expected {expected}, got {names}")
    for index, (name, value) in enumerate(pairs):
        require(int(value) == index, f"{enum_name}.{name} index changed without ABI acceptance: expected {index}, got {value}")
    return names


def parse_struct_fields(header_text: str, struct_name: str) -> tuple[str, ...]:
    match = re.search(rf"struct\s+{struct_name}\s*\{{(?P<body>.*?)\}};", header_text, re.DOTALL)
    if match is None:
        raise BpfAbiError(f"missing struct {struct_name}")
    fields: list[str] = []
    for raw_line in match.group("body").splitlines():
        line = raw_line.strip().rstrip(";")
        if line:
            fields.append(line)
    return tuple(fields)


def parse_header(path: Path) -> AbiSnapshot:
    header_text = require_text(path, REQUIRED_HEADER_TEXT, "BPF header")
    defines = parse_defines(header_text)
    stats = parse_enum_names(header_text, "zigsched_stat_index", EXPECTED_STATS)
    events = parse_enum_names(header_text, "zigsched_event_index", EXPECTED_EVENTS)
    policy_config_fields = parse_struct_fields(header_text, "zigsched_policy_config")
    require(policy_config_fields == EXPECTED_POLICY_CONFIG_FIELDS, "policy config layout changed without ABI acceptance")
    struct_ops_fields = parse_struct_fields(header_text, "sched_ext_ops")
    require("char name[128]" in struct_ops_fields, "struct_ops field missing from header: name")
    require("zigsched_u64 flags" in struct_ops_fields, "struct_ops field missing from header: flags")
    for callback in ("init", "enqueue", "dispatch"):
        needle = f"(*{callback})("
        require(any(needle in line for line in struct_ops_fields), f"struct_ops callback missing from header: {callback}")
    return AbiSnapshot(
        header_sha256=sha256_file(path),
        defines=defines,
        stats=stats,
        events=events,
        policy_config_fields=policy_config_fields,
    )


def require_string(value: JsonValue | None, context: str) -> str:
    if not isinstance(value, str) or value == "":
        raise BpfAbiError(f"{context} must be a non-empty string")
    return value


def require_int(value: JsonValue | None, expected: int, context: str) -> None:
    require(value == expected, f"{context} changed without ABI acceptance: expected {expected}, got {value}")


def require_string_list(value: JsonValue | None, expected: tuple[str, ...], context: str) -> None:
    got = tuple(str_list(value, context))
    require(got == expected, f"{context} changed without ABI acceptance: expected {expected}, got {got}")


def expected_source_map_layouts() -> tuple[SourceMapLayout, ...]:
    return tuple(
        SourceMapLayout(
            name=name,
            map_type=layout["type"],
            max_entries=layout["max_entries"],
            key_type=layout["key"],
            value_type=layout["value"],
        )
        for name, layout in EXPECTED_MAP_LAYOUTS.items()
    )


def normalize_c_value(value: str) -> str:
    return " ".join(value.strip().split())


def strip_c_comments(source: str) -> str:
    without_block_comments = re.sub(r"/\*.*?\*/", "", source, flags=re.DOTALL)
    return re.sub(r"//.*", "", without_block_comments)


def extract_macro_value(body: str, macro: str, key: str, context: str) -> str:
    match = re.search(rf"\b{re.escape(macro)}\(\s*{re.escape(key)}\s*,\s*(?P<value>[^)]+?)\s*\)\s*;", body)
    if match is None:
        raise BpfAbiError(f"{context} missing {macro}({key}, ...)")
    return normalize_c_value(match.group("value"))


def parse_source_map_layouts(source: str) -> tuple[SourceMapLayout, ...]:
    layouts: list[SourceMapLayout] = []
    pattern = re.compile(r"struct\s*\{(?P<body>.*?)\}\s*(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s+SEC\(\"\.maps\"\)\s*;", re.DOTALL)
    for match in pattern.finditer(source):
        name = match.group("name")
        body = match.group("body")
        context = f"source map {name}"
        layouts.append(
            SourceMapLayout(
                name=name,
                map_type=extract_macro_value(body, "__uint", "type", context),
                max_entries=extract_macro_value(body, "__uint", "max_entries", context),
                key_type=extract_macro_value(body, "__type", "key", context),
                value_type=extract_macro_value(body, "__type", "value", context),
            )
        )
    return tuple(layouts)


def parse_source_program_sections(source: str) -> tuple[str, ...]:
    sections: list[str] = []
    for match in re.finditer(r"SEC\(\"(?P<section>[^\"]+)\"\)", source):
        section = match.group("section")
        if section in (".maps", ".struct_ops", "license"):
            continue
        declaration = source[match.end() : match.end() + 240]
        require("BPF_PROG(" in declaration, f"unexpected non-program SEC section in source: {section}")
        sections.append(section)
    return tuple(sections)


def parse_struct_ops_source(source: str) -> tuple[tuple[str, ...], tuple[str, ...]]:
    pattern = re.compile(
        rf"struct\s+sched_ext_ops\s+{re.escape(POLICY_SYMBOL)}\s+SEC\(\"\.struct_ops\"\)\s*=\s*\{{(?P<body>.*?)\}}\s*;",
        re.DOTALL,
    )
    match = pattern.search(source)
    if match is None:
        raise BpfAbiError(f"source missing struct_ops object {POLICY_SYMBOL}")
    body = match.group("body")
    fields = tuple(re.findall(r"^\s*\.([A-Za-z_][A-Za-z0-9_]*)\s*=", body, re.MULTILINE))
    require(re.search(rf"^\s*\.name\s*=\s*\"{re.escape(POLICY_NAME)}\"\s*,", body, re.MULTILINE) is not None, "source struct_ops scheduler name drifted")
    require(re.search(rf"^\s*\.flags\s*=\s*{re.escape(PARTIAL_SWITCH)}\s*,", body, re.MULTILINE) is not None, "source struct_ops switch mode drifted")
    callbacks = tuple(field for field in fields if field not in ("name", "flags"))
    return fields, callbacks


def parse_source_abi(source_path: Path, source_sha256: str) -> SourceAbi:
    require(source_path.is_file(), f"source path missing: {source_path}")
    actual_sha = sha256_file(source_path)
    require(actual_sha == source_sha256, "source_sha256 does not match source file bytes")
    source = strip_c_comments(source_path.read_text())
    struct_ops_fields, callbacks = parse_struct_ops_source(source)
    map_layouts = parse_source_map_layouts(source)
    map_section_count = len(re.findall(r"SEC\(\"\.maps\"\)", source))
    require(len(map_layouts) == map_section_count, "source contains an unrecognized SEC(\".maps\") declaration")
    require(len(re.findall(r"SEC\(\"\.struct_ops\"\)", source)) == 1, "source must contain exactly one SEC(\".struct_ops\") object")
    return SourceAbi(
        source_sha256=actual_sha,
        map_layouts=map_layouts,
        program_sections=parse_source_program_sections(source),
        struct_ops_used_fields=struct_ops_fields,
        struct_ops_callbacks=callbacks,
    )


def require_source_abi_v1(source_abi: SourceAbi) -> None:
    expected_maps = expected_source_map_layouts()
    require(
        tuple(layout.name for layout in source_abi.map_layouts) == tuple(layout.name for layout in expected_maps),
        f"source map declarations changed without ABI acceptance: expected {tuple(layout.name for layout in expected_maps)}, got {tuple(layout.name for layout in source_abi.map_layouts)}",
    )
    for got, expected in zip(source_abi.map_layouts, expected_maps, strict=True):
        require(got == expected, f"source map layout drift for {expected.name}: expected {expected}, got {got}")
    require(
        source_abi.program_sections == PROGRAM_SECTIONS,
        f"source SEC program sections changed without ABI acceptance: expected {PROGRAM_SECTIONS}, got {source_abi.program_sections}",
    )
    require(
        source_abi.struct_ops_used_fields == STRUCT_OPS_USED_FIELDS,
        f"source struct_ops used fields changed without ABI acceptance: expected {STRUCT_OPS_USED_FIELDS}, got {source_abi.struct_ops_used_fields}",
    )


def source_map_layouts_object(source_abi: SourceAbi) -> JsonObject:
    layouts: JsonObject = {}
    for layout in source_abi.map_layouts:
        layouts[layout.name] = {
            "type": layout.map_type,
            "max_entries": layout.max_entries,
            "key": layout.key_type,
            "value": layout.value_type,
        }
    return layouts


def require_map_layouts(value: JsonValue | None, source_abi: SourceAbi) -> None:
    maps = obj(value, "abi_contract.map_layouts")
    expected_layouts = source_map_layouts_object(source_abi)
    require(
        set(maps) == set(expected_layouts),
        f"metadata map layouts changed without source ABI agreement: expected {tuple(expected_layouts)}, got {tuple(maps)}",
    )
    for name, expected_layout in expected_layouts.items():
        layout = obj(maps.get(name), f"abi_contract.map_layouts.{name}")
        for key, expected in expected_layout.items():
            require(layout.get(key) == expected, f"map layout drift for {name}.{key}: expected {expected}, got {layout.get(key)}")


def require_abi_contract(data: JsonObject, snapshot: AbiSnapshot, source_abi: SourceAbi) -> None:
    contract = obj(data.get("abi_contract"), "abi_contract")
    require_int(contract.get("abi_version"), ABI_VERSION, "ABI version")
    require(contract.get("header_sha256") == snapshot.header_sha256, "header_sha256 mismatch; stale metadata or header drift")
    source_sha_value = contract.get("source_sha256")
    require(isinstance(source_sha_value, str) and source_sha_value != "", "abi_contract.source_sha256 must be a non-empty string")
    require(source_sha_value == source_abi.source_sha256, "abi_contract.source_sha256/source bytes mismatch")
    require(contract.get("stats_count") == STATS_COUNT, "stats count changed without ABI acceptance")
    require(contract.get("events_count") == EVENTS_COUNT, "events count changed without ABI acceptance")
    require_string_list(contract.get("stats"), snapshot.stats, "stats enum")
    require_string_list(contract.get("events"), snapshot.events, "events enum")
    require_string_list(contract.get("policy_config_fields"), snapshot.policy_config_fields, "policy config fields")
    require_string_list(contract.get("struct_ops_used_fields"), source_abi.struct_ops_used_fields, "struct_ops used fields")
    require_map_layouts(contract.get("map_layouts"), source_abi)
    defines = obj(contract.get("defines"), "abi_contract.defines")
    for key, expected in snapshot.defines.items():
        require(defines.get(key) == expected, f"ABI define drift for {key}: expected {expected}, got {defines.get(key)}")


def resolve_repo_path(path_text: str) -> Path:
    path = Path(path_text)
    if path.is_absolute():
        return path
    return Path.cwd() / path


def common_checks(data: JsonObject, snapshot: AbiSnapshot) -> None:
    require(data.get("policy_name") == POLICY_NAME, "bad policy name")
    require(data.get("policy_symbol") == POLICY_SYMBOL, "bad policy symbol")
    require(data.get("vm_only") is True, "metadata must be VM-only")
    require(data.get("vm_marker_required") == VM_MARKER, "VM marker mismatch")
    require(data.get("vm_contract") == VM_CONTRACT, "VM contract mismatch")
    require(data.get("host_mutation") is False, "host_mutation must be false")
    require(data.get("host_attach_allowed") is False, "host attach must be refused")
    require(data.get("verification_claimed") is False, "metadata must not claim verification")
    source = require_string(data.get("source"), "source")
    source_sha256 = require_string(data.get("source_sha256"), "source_sha256")
    require(data.get("source_hash") == f"sha256:{source_sha256}", "source_hash/source_sha256 mismatch")
    source_abi = parse_source_abi(resolve_repo_path(source), source_sha256)
    require_source_abi_v1(source_abi)
    require_abi_contract(data, snapshot, source_abi)
    contract = obj(data.get("abi_contract"), "abi_contract")
    require(contract.get("source_sha256") == source_sha256, "abi_contract.source_sha256/source_sha256 mismatch")
    tuple_info = obj(data.get("tuple"), "tuple")
    require(tuple_info.get("target_arch") == "bpf", "tuple target_arch mismatch")
    require(tuple_info.get("target_define") == "__TARGET_ARCH_x86", "tuple target define mismatch")
    require(tuple_info.get("vm_required_for_attach") is True, "tuple VM-required gate missing")
    require(tuple_info.get("vm_contract") == VM_CONTRACT, "tuple VM contract mismatch")
    tools = obj(data.get("tool_versions"), "tool_versions")
    for key in ("clang", "clang_path", "llvm_objdump", "bpftool", "file", "zig"):
        require(isinstance(tools.get(key), str) and tools[key] != "", f"tool_versions missing {key}")
    struct_ops = obj(data.get("struct_ops"), "struct_ops")
    require(struct_ops.get("policy_name") == POLICY_NAME, "struct_ops policy name mismatch")
    require(struct_ops.get("object_name") == POLICY_SYMBOL, "struct_ops object mismatch")
    require(struct_ops.get("object_section") == ".struct_ops", "struct_ops section mismatch")
    require(struct_ops.get("expected_switch_mode") == PARTIAL_SWITCH, "switch mode must stay partial")
    require("SCX_OPS_SWITCH_ALL" in str_list(struct_ops.get("prohibited_switch_modes"), "prohibited_switch_modes"), "full-switch prohibition missing")
    callbacks = tuple(str_list(struct_ops.get("expected_callbacks"), "expected_callbacks"))
    require(callbacks == source_abi.struct_ops_callbacks, f"callback ABI drifted: expected {source_abi.struct_ops_callbacks}, got {callbacks}")
    sections = tuple(str_list(struct_ops.get("program_sections"), "program_sections"))
    require(sections == source_abi.program_sections, f"program section ABI drifted: expected {source_abi.program_sections}, got {sections}")


def check_object(data: JsonObject, snapshot: AbiSnapshot) -> str:
    require(data.get("schema") == "zig-scheduler/bpf-object-metadata/v1", "bad object metadata schema")
    require(data.get("status") == "built", "object metadata status must be built")
    require(data.get("artifact_kind") == "sched_ext_struct_ops_policy_object", "bad object artifact kind")
    for key in ("object", "object_hash", "object_sha256", "source", "source_hash", "source_sha256", "expected_verifier_object"):
        require(isinstance(data.get(key), str) and data[key] != "", f"object metadata missing {key}")
    object_sha = require_string(data.get("object_sha256"), "object_sha256")
    require(data.get("object_hash") == f"sha256:{object_sha}", "object_hash/object_sha256 mismatch")
    object_path = resolve_repo_path(require_string(data.get("object"), "object"))
    require(object_path.is_file(), f"object path missing: {object_path}")
    require(sha256_file(object_path) == object_sha, "object_sha256 does not match object file bytes")
    common_checks(data, snapshot)
    return "object"


def check_skip(data: JsonObject, snapshot: AbiSnapshot) -> str:
    require(data.get("schema") == "zig-scheduler/bpf-build-skip/v1", "bad skip schema")
    require(data.get("status") == "SKIP", "skip status must be SKIP")
    require(isinstance(data.get("reason"), str) and data["reason"] != "", "skip reason missing")
    require(data.get("object") is None, "skip must not name an object")
    require(data.get("object_hash") is None, "skip must not include object hash")
    require(data.get("object_sha256") is None, "skip must not include object sha")
    require(data.get("expected_verifier_object") is None, "skip must not include verifier object")
    require(data.get("release_eligible") is False, "skip cannot be release eligible")
    require(data.get("skip_is_release_eligible") is False, "skip release flag must be false")
    common_checks(data, snapshot)
    return "skip"


def validate(args: Args) -> str:
    snapshot = parse_header(args.header)
    _ = require_text(args.strategy, REQUIRED_ADR_TEXT, "BPF ABI ADR")
    if args.metadata.is_file():
        return check_object(load_json(args.metadata), snapshot)
    if args.skip_json is not None and args.skip_json.is_file():
        return check_skip(load_json(args.skip_json), snapshot)
    raise BpfAbiError("neither object metadata nor SKIP JSON evidence exists")


def json_string_map(values: dict[str, str]) -> JsonObject:
    return {key: value for key, value in values.items()}


def map_layouts_fixture(source_abi: SourceAbi) -> JsonObject:
    return source_map_layouts_object(source_abi)


def abi_contract_fixture(header: Path, source_abi: SourceAbi) -> JsonObject:
    snapshot = parse_header(header)
    return {
        "abi_version": ABI_VERSION,
        "header_sha256": snapshot.header_sha256,
        "source_sha256": source_abi.source_sha256,
        "defines": json_string_map(snapshot.defines),
        "stats_count": STATS_COUNT,
        "events_count": EVENTS_COUNT,
        "stats": list(snapshot.stats),
        "events": list(snapshot.events),
        "policy_config_fields": list(snapshot.policy_config_fields),
        "struct_ops_used_fields": list(source_abi.struct_ops_used_fields),
        "map_layouts": map_layouts_fixture(source_abi),
    }


def update_source_metadata(data: JsonObject, source: Path) -> None:
    source_sha = sha256_file(source)
    source_abi = parse_source_abi(source, source_sha)
    data["source"] = str(source)
    data["source_hash"] = "sha256:" + source_sha
    data["source_sha256"] = source_sha
    contract = obj(data["abi_contract"], "abi_contract")
    contract["source_sha256"] = source_sha
    contract["struct_ops_used_fields"] = list(source_abi.struct_ops_used_fields)
    contract["map_layouts"] = map_layouts_fixture(source_abi)
    struct_ops = obj(data["struct_ops"], "struct_ops")
    struct_ops["expected_callbacks"] = list(source_abi.struct_ops_callbacks)
    struct_ops["program_sections"] = list(source_abi.program_sections)


def expect_rejected(args: Args, metadata: Path, data: JsonObject, label: str) -> None:
    _ = metadata.write_text(json.dumps(data))
    try:
        _ = validate(args)
    except BpfAbiError as exc:
        print(f"PASS self-test rejected {label}: {exc}")
        return
    raise BpfAbiError(f"self-test failed to reject {label}")


def clone_json_object(data: JsonObject) -> JsonObject:
    return obj(json.loads(json.dumps(data)), "cloned self-test metadata")


def run_self_test(args: Args) -> None:
    with TemporaryDirectory(prefix="zigsched-bpf-abi-") as tmp:
        root = Path(tmp)
        header = root / "zigsched_common.h"
        strategy = root / "adr.md"
        metadata = root / "meta.json"
        skip = root / "skip.json"
        source = root / "zigsched_minimal.bpf.c"
        _ = header.write_text(args.header.read_text())
        _ = strategy.write_text(args.strategy.read_text())
        source_text = Path("bpf/zigsched_minimal.bpf.c").read_text()
        _ = source.write_text(source_text)
        source_sha = sha256_file(source)
        source_abi = parse_source_abi(source, source_sha)
        good: JsonObject = {
            "schema": "zig-scheduler/bpf-object-metadata/v1",
            "status": "built",
            "artifact_kind": "sched_ext_struct_ops_policy_object",
            "policy_name": POLICY_NAME,
            "policy_symbol": POLICY_SYMBOL,
            "object": str(root / "zigsched_minimal.bpf.o"),
            "object_hash": "sha256:abc",
            "object_sha256": "abc",
            "source": str(source),
            "source_hash": "sha256:" + source_sha,
            "source_sha256": source_sha,
            "expected_verifier_object": "zig-out/bpf/zigsched_minimal.bpf.o",
            "abi_contract": abi_contract_fixture(header, source_abi),
            "tuple": {"target_arch": "bpf", "target_define": "__TARGET_ARCH_x86", "vm_required_for_attach": True, "vm_contract": VM_CONTRACT},
            "tool_versions": {"clang": "c", "clang_path": "/usr/bin/clang", "llvm_objdump": "o", "bpftool": "b", "file": "f", "zig": "z"},
            "struct_ops": {"policy_name": POLICY_NAME, "object_name": POLICY_SYMBOL, "object_section": ".struct_ops", "expected_switch_mode": PARTIAL_SWITCH, "prohibited_switch_modes": ["SCX_OPS_SWITCH_ALL"], "expected_callbacks": ["init", "enqueue", "dispatch"], "program_sections": list(PROGRAM_SECTIONS)},
            "vm_only": True,
            "vm_marker_required": VM_MARKER,
            "vm_contract": VM_CONTRACT,
            "host_mutation": False,
            "host_attach_allowed": False,
            "verification_claimed": False,
        }
        object_path = root / "zigsched_minimal.bpf.o"
        _ = object_path.write_bytes(b"abc")
        object_sha = sha256_file(object_path)
        good["object_sha256"] = object_sha
        good["object_hash"] = "sha256:" + object_sha
        _ = metadata.write_text(json.dumps(good))
        _ = validate(Args(header, strategy, metadata, skip, False))
        bad = clone_json_object(good)
        bad["host_attach_allowed"] = True
        expect_rejected(Args(header, strategy, metadata, skip, False), metadata, bad, "unsafe metadata")
        bad = clone_json_object(good)
        contract = dict(obj(bad["abi_contract"], "abi_contract"))
        contract["stats_count"] = 9
        bad["abi_contract"] = contract
        expect_rejected(Args(header, strategy, metadata, skip, False), metadata, bad, "stats_count drift")
        extra_map_source = root / "extra_map.bpf.c"
        _ = extra_map_source.write_text(
            source_text
            + '\nstruct {\n    __uint(type, BPF_MAP_TYPE_ARRAY);\n    __uint(max_entries, 1);\n    __type(key, u32);\n    __type(value, u64);\n} zigsched_extra SEC(".maps");\n',
        )
        bad = clone_json_object(good)
        update_source_metadata(bad, extra_map_source)
        expect_rejected(Args(header, strategy, metadata, skip, False), metadata, bad, "unversioned source map")
        extra_program_source = root / "extra_program.bpf.c"
        _ = extra_program_source.write_text(source_text + '\nSEC("struct_ops/zigsched_extra")\nvoid BPF_PROG(zigsched_extra) {\n}\n')
        bad = clone_json_object(good)
        update_source_metadata(bad, extra_program_source)
        expect_rejected(Args(header, strategy, metadata, skip, False), metadata, bad, "unversioned SEC program")
        struct_ops_drift_source = root / "struct_ops_drift.bpf.c"
        _ = struct_ops_drift_source.write_text(source_text.replace("    .init = (void *)zigsched_minimal_init,\n", "    .select_cpu = (void *)zigsched_minimal_init,\n    .init = (void *)zigsched_minimal_init,\n", 1))
        bad = clone_json_object(good)
        update_source_metadata(bad, struct_ops_drift_source)
        expect_rejected(Args(header, strategy, metadata, skip, False), metadata, bad, "struct_ops source usage drift")
        stale = clone_json_object(good)
        stale["source_sha256"] = "0" * 64
        stale["source_hash"] = "sha256:" + "0" * 64
        contract = dict(obj(stale["abi_contract"], "abi_contract"))
        contract["source_sha256"] = "0" * 64
        stale["abi_contract"] = contract
        expect_rejected(Args(header, strategy, metadata, skip, False), metadata, stale, "stale source metadata")
        misleading = clone_json_object(good)
        struct_ops = dict(obj(misleading["struct_ops"], "struct_ops"))
        struct_ops["program_sections"] = [*PROGRAM_SECTIONS, "struct_ops/zigsched_extra"]
        misleading["struct_ops"] = struct_ops
        expect_rejected(Args(header, strategy, metadata, skip, False), metadata, misleading, "misleading program metadata")
        _ = metadata.write_text("{")
        try:
            _ = validate(Args(header, strategy, metadata, skip, False))
        except BpfAbiError as exc:
            print(f"PASS self-test rejected malformed metadata: {exc}")
        else:
            raise BpfAbiError("self-test failed to reject malformed metadata")
        _ = metadata.unlink()
        skip_data = clone_json_object(good)
        skip_data.update({"schema": "zig-scheduler/bpf-build-skip/v1", "status": "SKIP", "reason": "clang unavailable", "object": None, "object_hash": None, "object_sha256": None, "expected_verifier_object": None, "release_eligible": False, "skip_is_release_eligible": False})
        _ = skip.write_text(json.dumps(skip_data))
        _ = validate(Args(header, strategy, metadata, skip, False))
        skip_data["reason"] = ""
        _ = skip.write_text(json.dumps(skip_data))
        try:
            _ = validate(Args(header, strategy, metadata, skip, False))
        except BpfAbiError as exc:
            print(f"PASS self-test rejected bad skip: {exc}")
            return
    raise BpfAbiError("self-test failed to reject bad skip metadata")


def run(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.self_test:
        run_self_test(args)
    else:
        mode = validate(args)
        print(f"PASS BPF ABI freeze check: mode={mode} abi=v{ABI_VERSION} stats={STATS_COUNT} events={EVENTS_COUNT} header={args.header} strategy={args.strategy}")
    return 0


def main() -> int:
    try:
        return run(sys.argv[1:])
    except (OSError, UnicodeError, BpfAbiError) as exc:
        print(f"FAIL BPF ABI freeze check: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
