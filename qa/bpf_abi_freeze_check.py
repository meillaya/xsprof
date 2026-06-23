#!/usr/bin/env python3
"""Check the frozen sched_ext BPF ABI contract and metadata evidence."""

from __future__ import annotations

import json
import sys
from dataclasses import dataclass
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


@dataclass(frozen=True, slots=True)
class Args:
    header: Path
    strategy: Path
    metadata: Path
    skip_json: Path | None
    self_test: bool


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


def str_list(value: JsonValue | None, context: str) -> set[str]:
    if not isinstance(value, list):
        raise BpfAbiError(f"{context} must be a list")
    out: set[str] = set()
    for item in value:
        if not isinstance(item, str):
            raise BpfAbiError(f"{context} contains a non-string")
        out.add(item)
    return out


def require(condition: bool, message: str) -> None:
    if not condition:
        raise BpfAbiError(message)


def require_text(path: Path, needles: tuple[str, ...], context: str) -> None:
    text = path.read_text()
    missing = [needle for needle in needles if needle not in text]
    if missing:
        raise BpfAbiError(f"{context} missing text: {', '.join(missing)}")


def load_json(path: Path) -> JsonObject:
    try:
        raw = json.loads(path.read_text())
    except FileNotFoundError as exc:
        raise BpfAbiError(f"missing JSON evidence: {path}") from exc
    except json.JSONDecodeError as exc:
        raise BpfAbiError(f"invalid JSON evidence {path}: {exc}") from exc
    return obj(raw, str(path))


def common_checks(data: JsonObject) -> None:
    require(data.get("policy_name") == POLICY_NAME, "bad policy name")
    require(data.get("policy_symbol") == POLICY_SYMBOL, "bad policy symbol")
    require(data.get("vm_only") is True, "metadata must be VM-only")
    require(data.get("vm_marker_required") == VM_MARKER, "VM marker mismatch")
    require(data.get("vm_contract") == VM_CONTRACT, "VM contract mismatch")
    require(data.get("host_mutation") is False, "host_mutation must be false")
    require(data.get("host_attach_allowed") is False, "host attach must be refused")
    require(data.get("verification_claimed") is False, "metadata must not claim verification")
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
    require(str_list(struct_ops.get("expected_callbacks"), "expected_callbacks") == {"init", "enqueue", "dispatch"}, "callback ABI drifted")
    sections = str_list(struct_ops.get("program_sections"), "program_sections")
    missing_sections = sorted(set(PROGRAM_SECTIONS) - sections)
    require(not missing_sections, "program sections missing: " + ", ".join(missing_sections))


def check_object(data: JsonObject) -> str:
    require(data.get("schema") == "zig-scheduler/bpf-object-metadata/v1", "bad object metadata schema")
    require(data.get("status") == "built", "object metadata status must be built")
    require(data.get("artifact_kind") == "sched_ext_struct_ops_policy_object", "bad object artifact kind")
    for key in ("object", "object_hash", "object_sha256", "source", "source_hash", "source_sha256", "expected_verifier_object"):
        require(isinstance(data.get(key), str) and data[key] != "", f"object metadata missing {key}")
    common_checks(data)
    return "object"


def check_skip(data: JsonObject) -> str:
    require(data.get("schema") == "zig-scheduler/bpf-build-skip/v1", "bad skip schema")
    require(data.get("status") == "SKIP", "skip status must be SKIP")
    require(isinstance(data.get("reason"), str) and data["reason"] != "", "skip reason missing")
    require(data.get("object") is None, "skip must not name an object")
    require(data.get("object_hash") is None, "skip must not include object hash")
    require(data.get("expected_verifier_object") is None, "skip must not include verifier object")
    require(data.get("release_eligible") is False, "skip cannot be release eligible")
    require(data.get("skip_is_release_eligible") is False, "skip release flag must be false")
    common_checks(data)
    return "skip"


def validate(args: Args) -> str:
    require_text(args.header, REQUIRED_HEADER_TEXT, "BPF header")
    require_text(args.strategy, REQUIRED_ADR_TEXT, "BPF ABI ADR")
    if args.metadata.is_file():
        return check_object(load_json(args.metadata))
    if args.skip_json is not None and args.skip_json.is_file():
        return check_skip(load_json(args.skip_json))
    raise BpfAbiError("neither object metadata nor SKIP JSON evidence exists")


def run_self_test(args: Args) -> None:
    with TemporaryDirectory(prefix="zigsched-bpf-abi-") as tmp:
        root = Path(tmp)
        header = root / "zigsched_common.h"
        strategy = root / "adr.md"
        metadata = root / "meta.json"
        skip = root / "skip.json"
        header.write_text(args.header.read_text())
        strategy.write_text(args.strategy.read_text())
        good = {
            "schema": "zig-scheduler/bpf-object-metadata/v1",
            "status": "built",
            "artifact_kind": "sched_ext_struct_ops_policy_object",
            "policy_name": POLICY_NAME,
            "policy_symbol": POLICY_SYMBOL,
            "object": "zig-out/bpf/zigsched_minimal.bpf.o",
            "object_hash": "sha256:abc",
            "object_sha256": "abc",
            "source": "bpf/zigsched_minimal.bpf.c",
            "source_hash": "sha256:def",
            "source_sha256": "def",
            "expected_verifier_object": "zig-out/bpf/zigsched_minimal.bpf.o",
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
        metadata.write_text(json.dumps(good))
        validate(Args(header, strategy, metadata, skip, False))
        bad = dict(good)
        bad["host_attach_allowed"] = True
        metadata.write_text(json.dumps(bad))
        try:
            validate(Args(header, strategy, metadata, skip, False))
        except BpfAbiError as exc:
            print(f"PASS self-test rejected unsafe metadata: {exc}")
        else:
            raise BpfAbiError("self-test failed to reject host_attach_allowed=true")
        metadata.unlink()
        skip_data = dict(good)
        skip_data.update({"schema": "zig-scheduler/bpf-build-skip/v1", "status": "SKIP", "reason": "clang unavailable", "object": None, "object_hash": None, "object_sha256": None, "expected_verifier_object": None, "release_eligible": False, "skip_is_release_eligible": False})
        skip.write_text(json.dumps(skip_data))
        validate(Args(header, strategy, metadata, skip, False))
        skip_data["reason"] = ""
        skip.write_text(json.dumps(skip_data))
        try:
            validate(Args(header, strategy, metadata, skip, False))
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
        print(f"PASS BPF ABI freeze check: mode={mode} header={args.header} strategy={args.strategy}")
    return 0


def main() -> int:
    try:
        return run(sys.argv[1:])
    except (OSError, UnicodeError, BpfAbiError) as exc:
        print(f"FAIL BPF ABI freeze check: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
