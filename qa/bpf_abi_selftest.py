"""Self-tests for BPF ABI freeze validation."""

from __future__ import annotations

import json
from pathlib import Path
from typing import TYPE_CHECKING, Protocol
from tempfile import TemporaryDirectory

from qa.bpf_abi_model import JsonValue, PARTIAL_SWITCH, POLICY_NAME, POLICY_SYMBOL, PROGRAM_SECTIONS, VM_CONTRACT, VM_MARKER, Args, BpfAbiError, JsonObject, obj, sha256_file
from qa.bpf_abi_parse import parse_header, parse_source_abi, source_map_layouts_object
from qa.bpf_abi_validate import validate


class JsonLoader(Protocol):
    def loads(self, text: str) -> JsonValue: ...


if TYPE_CHECKING:
    json_loader: JsonLoader
else:
    json_loader = json


def json_string_map(values: dict[str, str]) -> JsonObject:
    return {key: value for key, value in values.items()}


def abi_contract_fixture(header: Path, source: Path) -> JsonObject:
    snapshot = parse_header(header)
    source_sha = sha256_file(source)
    source_abi = parse_source_abi(source, source_sha)
    return {
        "abi_version": 1,
        "header_sha256": snapshot.header_sha256,
        "source_sha256": source_sha,
        "defines": json_string_map(snapshot.defines),
        "stats_count": 8,
        "events_count": 4,
        "stats": list(snapshot.stats),
        "events": list(snapshot.events),
        "policy_config_fields": list(snapshot.policy_config_fields),
        "struct_ops_used_fields": list(source_abi.struct_ops_used_fields),
        "map_layouts": source_map_layouts_object(source_abi),
    }


def update_source_metadata(data: JsonObject, source: Path) -> None:
    source_sha = sha256_file(source)
    source_abi = parse_source_abi(source, source_sha)
    data["source"] = str(source.relative_to(Path.cwd()))
    data["source_hash"] = "sha256:" + source_sha
    data["source_sha256"] = source_sha
    contract = obj(data["abi_contract"], "abi_contract")
    contract["source_sha256"] = source_sha
    contract["struct_ops_used_fields"] = list(source_abi.struct_ops_used_fields)
    contract["map_layouts"] = source_map_layouts_object(source_abi)
    struct_ops = obj(data["struct_ops"], "struct_ops")
    struct_ops["expected_callbacks"] = list(source_abi.struct_ops_callbacks)
    struct_ops["program_sections"] = list(source_abi.program_sections)


def expect_rejected(args: Args, metadata: Path, data: JsonObject, label: str) -> None:
    _ = metadata.write_text(json.dumps(data))
    try:
        _ = validate(args.header, args.strategy, args.metadata, args.skip_json)
    except BpfAbiError as exc:
        print(f"PASS self-test rejected {label}: {exc}")
        return
    raise BpfAbiError(f"self-test failed to reject {label}")


def clone_json_object(data: JsonObject) -> JsonObject:
    return obj(json_loader.loads(json.dumps(data)), "cloned self-test metadata")


def good_metadata(root: Path, source: Path, header: Path) -> JsonObject:
    object_path = root / "zigsched_minimal.bpf.o"
    _ = object_path.write_bytes(b"abc")
    object_sha = sha256_file(object_path)
    source_sha = sha256_file(source)
    root_value = root.relative_to(Path.cwd())
    source_value = source.relative_to(Path.cwd())
    object_value = root_value / "zigsched_minimal.bpf.o"
    return {
        "schema": "zig-scheduler/bpf-object-metadata/v1",
        "status": "built",
        "artifact_kind": "sched_ext_struct_ops_policy_object",
        "policy_name": POLICY_NAME,
        "policy_symbol": POLICY_SYMBOL,
        "object": str(object_value),
        "object_hash": "sha256:" + object_sha,
        "object_sha256": object_sha,
        "source": str(source_value),
        "source_hash": "sha256:" + source_sha,
        "source_sha256": source_sha,
        "expected_verifier_object": str(object_value),
        "abi_contract": abi_contract_fixture(header, source),
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


def run_self_test(args: Args) -> None:
    with TemporaryDirectory(prefix="zigsched-bpf-abi-", dir=".") as tmp:
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
        good = good_metadata(root, source, header)
        _ = metadata.write_text(json.dumps(good))
        local_args = Args(header, strategy, metadata, skip, False)
        _ = validate(header, strategy, metadata, skip)
        bad = clone_json_object(good); bad["host_attach_allowed"] = True
        expect_rejected(local_args, metadata, bad, "unsafe metadata")
        bad = clone_json_object(good); contract = obj(bad["abi_contract"], "abi_contract"); contract["stats_count"] = 9
        expect_rejected(local_args, metadata, bad, "stats_count drift")
        extra_map = root / "extra_map.bpf.c"
        _ = extra_map.write_text(source_text + '\nstruct {\n __uint(type, BPF_MAP_TYPE_ARRAY);\n __uint(max_entries, 1);\n __type(key, u32);\n __type(value, u64);\n} zigsched_extra SEC(".maps");\n')
        bad = clone_json_object(good); update_source_metadata(bad, extra_map)
        expect_rejected(local_args, metadata, bad, "unversioned source map")
        extra_prog = root / "extra_program.bpf.c"
        _ = extra_prog.write_text(source_text + '\nSEC("struct_ops/zigsched_extra")\nvoid BPF_PROG(zigsched_extra) {\n}\n')
        bad = clone_json_object(good); update_source_metadata(bad, extra_prog)
        expect_rejected(local_args, metadata, bad, "unversioned SEC program")
        drift = root / "struct_ops_drift.bpf.c"
        _ = drift.write_text(source_text.replace("    .init = (void *)zigsched_minimal_init,\n", "    .select_cpu = (void *)zigsched_minimal_init,\n    .init = (void *)zigsched_minimal_init,\n", 1))
        bad = clone_json_object(good); update_source_metadata(bad, drift)
        expect_rejected(local_args, metadata, bad, "struct_ops source usage drift")
        stale = clone_json_object(good); stale["source_sha256"] = "0" * 64; stale["source_hash"] = "sha256:" + "0" * 64; obj(stale["abi_contract"], "abi_contract")["source_sha256"] = "0" * 64
        expect_rejected(local_args, metadata, stale, "stale source metadata")
        misleading = clone_json_object(good); obj(misleading["struct_ops"], "struct_ops")["program_sections"] = [*PROGRAM_SECTIONS, "struct_ops/zigsched_extra"]
        expect_rejected(local_args, metadata, misleading, "misleading program metadata")
        _ = metadata.write_text("{")
        try:
            _ = validate(header, strategy, metadata, skip)
        except BpfAbiError as exc:
            print(f"PASS self-test rejected malformed metadata: {exc}")
        else:
            raise BpfAbiError("self-test failed to reject malformed metadata")
        metadata.unlink()
        skip_data = clone_json_object(good)
        skip_data.update({"schema": "zig-scheduler/bpf-build-skip/v1", "status": "SKIP", "reason": "clang unavailable", "object": None, "object_hash": None, "object_sha256": None, "expected_verifier_object": None, "release_eligible": False, "skip_is_release_eligible": False})
        _ = skip.write_text(json.dumps(skip_data))
        _ = validate(header, strategy, metadata, skip)
        skip_data["reason"] = ""
        _ = skip.write_text(json.dumps(skip_data))
        expect_rejected(local_args, metadata, skip_data, "bad skip")
