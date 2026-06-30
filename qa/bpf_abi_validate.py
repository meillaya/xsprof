"""Validate BPF ABI metadata and SKIP evidence."""

from __future__ import annotations

from pathlib import Path

from qa.bpf_abi_model import ABI_VERSION, ABI_V3_ACCEPTED_CALLBACKS, CGROUP_KNOB_SEMANTICS, EVENTS_COUNT, PARTIAL_SWITCH, POLICY_NAME, POLICY_SYMBOL, STATS_COUNT, VM_CONTRACT, VM_MARKER, AbiSnapshot, JsonObject, SourceAbi, obj, require, require_int, require_string, require_string_list, sha256_file, str_list
from qa.bpf_abi_parse import load_json, parse_header, parse_source_abi, require_text, source_abi_status, source_map_layouts_object
from qa.bpf_abi_model import REQUIRED_ADR_TEXT


def require_map_layouts(value: JsonObject, source_abi: SourceAbi) -> None:
    require(value == source_map_layouts_object(source_abi), "map layout metadata drifted from source")


def require_abi_contract(contract: JsonObject, snapshot: AbiSnapshot, source_abi: SourceAbi, source_status: str) -> None:
    require_int(contract.get("abi_version"), ABI_VERSION, "abi_contract.abi_version")
    require(contract.get("header_sha256") == snapshot.header_sha256, "abi_contract.header_sha256 mismatch")
    require(contract.get("source_sha256") == source_abi.source_sha256, "abi_contract.source_sha256 mismatch")
    require(obj(contract.get("defines"), "abi_contract.defines") == snapshot.defines, "ABI defines drifted")
    require_int(contract.get("stats_count"), STATS_COUNT, "abi_contract.stats_count")
    require_int(contract.get("events_count"), EVENTS_COUNT, "abi_contract.events_count")
    require_string_list(contract.get("stats"), snapshot.stats, "abi_contract.stats")
    require_string_list(contract.get("events"), snapshot.events, "abi_contract.events")
    require_string_list(contract.get("stats_fields"), snapshot.stats_fields, "abi_contract.stats_fields")
    require_string_list(contract.get("policy_config_fields"), snapshot.policy_config_fields, "abi_contract.policy_config_fields")
    require_string_list(contract.get("cgroup_policy_fields"), snapshot.cgroup_policy_fields, "abi_contract.cgroup_policy_fields")
    require_string_list(contract.get("struct_ops_used_fields"), source_abi.struct_ops_used_fields, "abi_contract.struct_ops_used_fields")
    require_string_list(contract.get("abi_v3_accepted_callbacks"), ABI_V3_ACCEPTED_CALLBACKS, "abi_contract.abi_v3_accepted_callbacks")
    require(contract.get("abi_v3_source_status") == source_status, f"abi_contract.abi_v3_source_status must match source shape: {source_status}")
    require(obj(contract.get("cgroup_knob_semantics"), "abi_contract.cgroup_knob_semantics") == CGROUP_KNOB_SEMANTICS, "cgroup knob semantics changed without ABI acceptance")
    require(contract.get("tuple_reference") == "docs/releases/supported-kernel-tuples.md", "abi_contract.tuple_reference must pin supported tuple document")
    require_map_layouts(obj(contract.get("map_layouts"), "abi_contract.map_layouts"), source_abi)


def resolve_repo_path(value: str) -> Path:
    path = Path(value)
    require(not path.is_absolute() and ".." not in path.parts, f"unsafe repo path in metadata: {value}")
    return path


def common_checks(data: JsonObject, snapshot: AbiSnapshot) -> SourceAbi:
    require(data.get("policy_name") == POLICY_NAME, "policy name mismatch")
    require(data.get("policy_symbol") == POLICY_SYMBOL, "policy symbol mismatch")
    require(data.get("vm_only") is True, "BPF metadata must remain VM-only")
    require(data.get("vm_marker_required") == VM_MARKER, "VM marker requirement missing")
    require(data.get("vm_contract") == VM_CONTRACT, "VM contract path mismatch")
    require(data.get("host_mutation") is False, "BPF metadata must not claim host mutation")
    require(data.get("host_attach_allowed") is False, "host attach must stay forbidden")
    require(data.get("verification_claimed") is False, "metadata cannot claim verifier success")
    source_sha = require_string(data.get("source_sha256"), "source_sha256")
    require(data.get("source_hash") == f"sha256:{source_sha}", "source_hash/source_sha256 mismatch")
    source_abi = parse_source_abi(resolve_repo_path(require_string(data.get("source"), "source")), source_sha)
    source_status = source_abi_status(source_abi)
    require_abi_contract(obj(data.get("abi_contract"), "abi_contract"), snapshot, source_abi, source_status)
    tuple_data = obj(data.get("tuple"), "tuple")
    require(tuple_data.get("target_arch") == "bpf", "target arch mismatch")
    require(tuple_data.get("target_define") == "__TARGET_ARCH_x86", "target define mismatch")
    require(tuple_data.get("vm_required_for_attach") is True, "tuple must require VM attach")
    require(tuple_data.get("vm_contract") == VM_CONTRACT, "tuple VM contract mismatch")
    require(tuple_data.get("tuple_reference") == "docs/releases/supported-kernel-tuples.md", "tuple reference mismatch")
    tools = obj(data.get("tool_versions"), "tool_versions")
    for key in ("clang", "clang_path", "llvm_objdump", "bpftool", "file", "zig"):
        require(isinstance(tools.get(key), str) and tools[key] != "", f"tool_versions missing {key}")
    struct_ops = obj(data.get("struct_ops"), "struct_ops")
    require(struct_ops.get("policy_name") == POLICY_NAME, "struct_ops policy name mismatch")
    require(struct_ops.get("object_name") == POLICY_SYMBOL, "struct_ops object mismatch")
    require(struct_ops.get("object_section") == ".struct_ops", "struct_ops section mismatch")
    require(struct_ops.get("expected_switch_mode") == PARTIAL_SWITCH, "switch mode must stay partial")
    require("SCX_OPS_SWITCH_ALL" in str_list(struct_ops.get("prohibited_switch_modes"), "prohibited_switch_modes"), "full-switch prohibition missing")
    require(tuple(str_list(struct_ops.get("expected_callbacks"), "expected_callbacks")) == source_abi.struct_ops_callbacks, "callback ABI drifted")
    require(tuple(str_list(struct_ops.get("program_sections"), "program_sections")) == source_abi.program_sections, "program section ABI drifted")
    return source_abi


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
    _ = common_checks(data, snapshot)
    return "object"


def check_skip(data: JsonObject, snapshot: AbiSnapshot) -> str:
    require(data.get("schema") == "zig-scheduler/bpf-build-skip/v1", "bad skip schema")
    require(data.get("status") == "SKIP", "skip status must be SKIP")
    require(isinstance(data.get("reason"), str) and data["reason"] != "", "skip reason missing")
    for key in ("object", "object_hash", "object_sha256", "expected_verifier_object"):
        require(data.get(key) is None, f"skip must not include {key}")
    require(data.get("release_eligible") is False, "skip cannot be release eligible")
    require(data.get("skip_is_release_eligible") is False, "skip release flag must be false")
    _ = common_checks(data, snapshot)
    return "skip"


def validate(header: Path, strategy: Path, metadata: Path, skip_json: Path | None) -> str:
    snapshot = parse_header(header)
    _ = require_text(strategy, REQUIRED_ADR_TEXT, "BPF ABI ADR")
    if metadata.is_file():
        return check_object(load_json(metadata), snapshot)
    if skip_json is not None and skip_json.is_file():
        return check_skip(load_json(skip_json), snapshot)
    from qa.bpf_abi_model import BpfAbiError
    raise BpfAbiError("neither object metadata nor SKIP JSON evidence exists")
