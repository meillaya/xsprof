"""Parse frozen BPF ABI facts from headers and C source."""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import TYPE_CHECKING, Protocol

from qa.bpf_abi_model import ABI_VERSION, EXPECTED_DEFINES, EXPECTED_EVENTS, EXPECTED_MAP_LAYOUTS, EXPECTED_POLICY_CONFIG_FIELDS, EXPECTED_STATS, PARTIAL_SWITCH, POLICY_NAME, POLICY_SYMBOL, PROGRAM_SECTIONS, REQUIRED_HEADER_TEXT, STRUCT_OPS_USED_FIELDS, AbiSnapshot, BpfAbiError, JsonObject, JsonValue, SourceAbi, SourceMapLayout, obj, require, sha256_file


class JsonLoader(Protocol):
    def loads(self, text: str) -> JsonValue: ...


if TYPE_CHECKING:
    json_loader: JsonLoader
else:
    json_loader = json


def require_text(path: Path, needles: tuple[str, ...], context: str) -> str:
    text = path.read_text()
    missing = [needle for needle in needles if needle not in text]
    if missing:
        raise BpfAbiError(f"{context} missing text: {', '.join(missing)}")
    return text


def load_json(path: Path) -> JsonObject:
    try:
        raw = json_loader.loads(path.read_text())
    except FileNotFoundError as exc:
        raise BpfAbiError(f"missing JSON evidence: {path}") from exc
    except json.JSONDecodeError as exc:
        raise BpfAbiError(f"invalid JSON evidence {path}: {exc}") from exc
    return obj(raw, str(path))


def parse_defines(header_text: str) -> dict[str, str]:
    pairs: list[tuple[str, str]] = re.findall(r"^#define\s+(ZIGSCHED_[A-Z0-9_]+|SCX_OPS_SWITCH_PARTIAL)\s+([^\s/]+)", header_text, re.MULTILINE)
    found = dict(pairs)
    for name, expected in EXPECTED_DEFINES.items():
        require(found.get(name) == expected, f"{name} changed without ABI acceptance: expected {expected}, got {found.get(name)}")
    return {name: found[name] for name in EXPECTED_DEFINES}


def parse_enum_names(header_text: str, enum_name: str, expected: tuple[str, ...]) -> tuple[str, ...]:
    match = re.search(rf"enum\s+{enum_name}\s*\{{(?P<body>.*?)\}};", header_text, re.DOTALL)
    if match is None:
        raise BpfAbiError(f"missing enum {enum_name}")
    pairs: list[tuple[str, str]] = re.findall(r"\b(ZIGSCHED_[A-Z0-9_]+)\s*=\s*(\d+)\s*,", match.group("body"))
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
        require(any(f"(*{callback})(" in line for line in struct_ops_fields), f"struct_ops callback missing from header: {callback}")
    return AbiSnapshot(sha256_file(path), defines, stats, events, policy_config_fields)


def expected_source_map_layouts() -> tuple[SourceMapLayout, ...]:
    return tuple(SourceMapLayout(name, layout["type"], layout["max_entries"], layout["key"], layout["value"]) for name, layout in EXPECTED_MAP_LAYOUTS.items())


def normalize_c_value(value: str) -> str:
    return " ".join(value.strip().split())


def strip_c_comments(source: str) -> str:
    return re.sub(r"//.*", "", re.sub(r"/\*.*?\*/", "", source, flags=re.DOTALL))


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
        layouts.append(SourceMapLayout(name, extract_macro_value(body, "__uint", "type", context), extract_macro_value(body, "__uint", "max_entries", context), extract_macro_value(body, "__type", "key", context), extract_macro_value(body, "__type", "value", context)))
    return tuple(layouts)


def parse_source_program_sections(source: str) -> tuple[str, ...]:
    sections: list[str] = []
    for match in re.finditer(r"SEC\(\"(?P<section>[^\"]+)\"\)", source):
        section = match.group("section")
        if section in (".maps", ".struct_ops", "license"):
            continue
        require("BPF_PROG(" in source[match.end() : match.end() + 240], f"unexpected non-program SEC section in source: {section}")
        sections.append(section)
    return tuple(sections)


def parse_struct_ops_source(source: str) -> tuple[tuple[str, ...], tuple[str, ...]]:
    pattern = re.compile(rf"struct\s+sched_ext_ops\s+{re.escape(POLICY_SYMBOL)}\s+SEC\(\"\.struct_ops\"\)\s*=\s*\{{(?P<body>.*?)\}}\s*;", re.DOTALL)
    match = pattern.search(source)
    if match is None:
        raise BpfAbiError(f"source missing struct_ops object {POLICY_SYMBOL}")
    body = match.group("body")
    fields: tuple[str, ...] = tuple(re.findall(r"^\s*\.([A-Za-z_][A-Za-z0-9_]*)\s*=", body, re.MULTILINE))
    require(re.search(rf"^\s*\.name\s*=\s*\"{re.escape(POLICY_NAME)}\"\s*,", body, re.MULTILINE) is not None, "source struct_ops scheduler name drifted")
    require(re.search(rf"^\s*\.flags\s*=\s*{re.escape(PARTIAL_SWITCH)}\s*,", body, re.MULTILINE) is not None, "source struct_ops switch mode drifted")
    return fields, tuple(field for field in fields if field not in ("name", "flags"))


def parse_source_abi(source_path: Path, source_sha256: str) -> SourceAbi:
    require(source_path.is_file(), f"source path missing: {source_path}")
    require(sha256_file(source_path) == source_sha256, "source_sha256 does not match source file bytes")
    source = strip_c_comments(source_path.read_text())
    struct_ops_fields, callbacks = parse_struct_ops_source(source)
    return SourceAbi(source_sha256, parse_source_map_layouts(source), parse_source_program_sections(source), struct_ops_fields, callbacks)


def source_map_layouts_object(source_abi: SourceAbi) -> JsonObject:
    return {layout.name: {"type": layout.map_type, "max_entries": layout.max_entries, "key": layout.key_type, "value": layout.value_type} for layout in source_abi.map_layouts}


def require_source_abi_v1(source_abi: SourceAbi) -> None:
    require(source_abi.map_layouts == expected_source_map_layouts(), f"source map layouts changed without ABI v{ABI_VERSION + 1}: expected {expected_source_map_layouts()}, got {source_abi.map_layouts}")
    require(source_abi.program_sections == PROGRAM_SECTIONS, f"source SEC program set changed without ABI v{ABI_VERSION + 1}: expected {PROGRAM_SECTIONS}, got {source_abi.program_sections}")
    require(source_abi.struct_ops_used_fields == STRUCT_OPS_USED_FIELDS, f"source struct_ops fields changed without ABI v{ABI_VERSION + 1}: expected {STRUCT_OPS_USED_FIELDS}, got {source_abi.struct_ops_used_fields}")
    require(source_abi.struct_ops_callbacks == ("init", "enqueue", "dispatch"), "source struct_ops callbacks changed without ABI acceptance")
