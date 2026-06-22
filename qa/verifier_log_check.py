#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
# ─── How to run ───
# 1. Install uv (if not installed):
#      curl -LsSf https://astral.sh/uv/install.sh | sh
# 2. Run directly:
#      uv run qa/verifier_log_check.py --input evidence/lab/verifier/bpf-verifier.log --out evidence/lab/verifier/parsed.json
#      uv run qa/verifier_log_check.py --evidence evidence/lab/verifier/verifier-evidence.json
# 3. Self-test:
#      python3 qa/verifier_log_check.py --self-test
# ──────────────────
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import json
import sys
from typing import Final, Literal, TypeAlias

_ = sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from qa.evidence_safety_check import EvidenceSafetyError, JsonObject, JsonValue, reject_contradictions
from qa.verifier_refusal_check import VerifierRefusalError, parse_refusal_evidence
from qa.verifier_vm_check import VM_EVIDENCE_SCHEMA, VMVerifierError, parse_vm_evidence, parse_vm_live_log

Status: TypeAlias = Literal["PASS", "SKIP", "FAIL", "REFUSE"]

SCHEMA: Final[str] = "zig-scheduler/verifier-log-parse/v1"
REFUSAL_SCHEMA: Final[str] = "zig-scheduler/verifier-only-refusal/v1"
EVIDENCE_SCHEMA: Final[str] = "zig-scheduler/verifier-only-evidence/v1"
STATUSES: Final[frozenset[str]] = frozenset({"PASS", "SKIP", "FAIL", "REFUSE"})


@dataclass(frozen=True, slots=True)
class Args:
    input_path: Path | None
    evidence_path: Path | None
    out_path: Path | None
    allow_refusal: bool
    self_test: bool


@dataclass(frozen=True, slots=True)
class ParsedLog:
    values: dict[str, str]
    errors: list[str]
    skip_reason: str
    bpftool_rc: int | None


class VerifierLogError(Exception):
    """Raised when verifier evidence is malformed or policy-failing."""


def parse_args(argv: list[str]) -> Args:
    if argv == ["--self-test"]:
        return Args(input_path=None, evidence_path=None, out_path=None, allow_refusal=False, self_test=True)
    input_path: Path | None = None
    evidence_path: Path | None = None
    out_path: Path | None = None
    allow_refusal = False
    index = 0
    while index < len(argv):
        arg = argv[index]
        if arg == "--input" and index + 1 < len(argv):
            input_path = Path(argv[index + 1]); index += 2
        elif arg == "--evidence" and index + 1 < len(argv):
            evidence_path = Path(argv[index + 1]); index += 2
        elif arg == "--out" and index + 1 < len(argv):
            out_path = Path(argv[index + 1]); index += 2
        elif arg == "--allow-refusal":
            allow_refusal = True; index += 1
        else:
            raise VerifierLogError("usage: verifier_log_check.py --input <log-or-json> [--out <json>] [--allow-refusal] | --evidence <verifier-evidence.json> [--out <json>] | --self-test")
    if input_path is None and evidence_path is None:
        raise VerifierLogError("--input or --evidence is required")
    if input_path is not None and evidence_path is not None:
        raise VerifierLogError("--input and --evidence are mutually exclusive")
    return Args(input_path=input_path, evidence_path=evidence_path, out_path=out_path, allow_refusal=allow_refusal, self_test=False)


def parse_lines(text: str) -> ParsedLog:
    values: dict[str, str] = {}
    errors: list[str] = []
    skip_reason = ""
    bpftool_rc: int | None = None
    for raw in text.splitlines():
        line = raw.strip()
        lower = line.lower()
        if "skip:" in lower:
            skip_reason = line.split(":", 1)[-1].strip()
        if is_verifier_error(lower):
            errors.append(line)
        if line.startswith("bpftool_rc="):
            value = line.split("=", 1)[1]
            if not value.isdigit():
                raise VerifierLogError(f"invalid bpftool_rc: {value}")
            bpftool_rc = int(value)
        if "=" in line and not line.startswith("COMMAND:"):
            key, value = line.split("=", 1)
            values[key] = value
    return ParsedLog(values=values, errors=errors, skip_reason=skip_reason, bpftool_rc=bpftool_rc)


def is_verifier_error(lower: str) -> bool:
    needles = ("invalid mem access", "unknown func", "invalid func", "relocation", "program rejected", "permission denied")
    return any(needle in lower for needle in needles)


def reason_from(parsed: ParsedLog) -> str:
    if parsed.skip_reason != "":
        lower = parsed.skip_reason.lower()
        if "bpftool" in lower:
            return "BPFTOOL_UNAVAILABLE"
        if "/sys/fs/bpf" in lower:
            return "BPF_FS_UNAVAILABLE"
        return "UNKNOWN_SKIPPED"
    joined = "\n".join(parsed.errors).lower()
    if "invalid mem access" in joined:
        return "INVALID_MEM_ACCESS"
    if "relocation" in joined or "unknown func" in joined or "invalid func" in joined:
        return "HELPER_OR_RELOCATION_FAILURE"
    if state_changed(parsed.values):
        return "SCHED_EXT_STATE_CHANGED"
    if cgroup_changed(parsed.values):
        return "CGROUP_MEMBERSHIP_CHANGED"
    if parsed.bpftool_rc is None:
        return "UNKNOWN_SKIPPED"
    if parsed.bpftool_rc != 0:
        return "VERIFIER_REJECTED"
    if missing_state_evidence(parsed.values):
        return "MISSING_STATE_EVIDENCE"
    return "VERIFIER_ACCEPTED"


def state_changed(values: dict[str, str]) -> bool:
    state_before = values.get("sched_ext_state_before", "")
    state_after = values.get("sched_ext_state_after", state_before)
    seq_before = values.get("sched_ext_enable_seq_before", "")
    seq_after = values.get("sched_ext_enable_seq_after", seq_before)
    return state_before != state_after or seq_before != seq_after


def cgroup_changed(values: dict[str, str]) -> bool:
    before = values.get("cgroup_membership_before", "")
    after = values.get("cgroup_membership_after", before)
    return before != after


def missing_state_evidence(values: dict[str, str]) -> bool:
    required = ("sched_ext_state_before", "sched_ext_state_after", "sched_ext_enable_seq_before", "sched_ext_enable_seq_after", "cgroup_membership_before", "cgroup_membership_after")
    return any(values.get(field, "") == "" for field in required)


def status_from(reason: str) -> Status:
    if reason == "VERIFIER_ACCEPTED":
        return "PASS"
    if reason in {"BPFTOOL_UNAVAILABLE", "BPF_FS_UNAVAILABLE", "UNKNOWN_SKIPPED"}:
        return "SKIP"
    return "FAIL"


def parse_log(path: Path) -> JsonObject:
    text = path.read_text()
    parsed = parse_lines(text)
    try:
        vm_live_result = parse_vm_live_log(path, parsed.values, text)
    except VMVerifierError as exc:
        raise VerifierLogError(str(exc)) from exc
    if vm_live_result is not None:
        return vm_live_result
    reason = reason_from(parsed)
    status = status_from(reason)
    verifier_errors: list[JsonValue] = [error for error in parsed.errors]
    if status == "PASS" and (state_changed(parsed.values) or cgroup_changed(parsed.values)):
        raise VerifierLogError("clean verifier logs must preserve sched_ext and cgroup state")
    if status == "PASS" and (len(parsed.values.get("object_sha256", "")) != 64 or len(parsed.values.get("bpf_metadata_object_sha256", "")) != 64):
        raise VerifierLogError("clean verifier logs require object and metadata sha")
    return {
        "schema": SCHEMA,
        "status": status,
        "reason": reason,
        "input": path.as_posix(),
        "object": parsed.values.get("object", ""),
        "object_sha256": parsed.values.get("object_sha256", ""),
        "bpf_metadata_path": parsed.values.get("bpf_metadata_path", ""),
        "bpf_metadata_object_sha256": parsed.values.get("bpf_metadata_object_sha256", ""),
        "bpftool_rc": parsed.bpftool_rc,
        "verifier_errors": verifier_errors,
        "sched_ext_state_before": parsed.values.get("sched_ext_state_before", ""),
        "sched_ext_state_after": parsed.values.get("sched_ext_state_after", ""),
        "enable_seq_before": parsed.values.get("sched_ext_enable_seq_before", ""),
        "enable_seq_after": parsed.values.get("sched_ext_enable_seq_after", ""),
        "cgroup_membership_before": parsed.values.get("cgroup_membership_before", ""),
        "cgroup_membership_after": parsed.values.get("cgroup_membership_after", ""),
        "host_mutation": False,
    }


def parse_evidence(path: Path) -> JsonObject:
    raw: JsonValue = json.loads(path.read_text())
    if isinstance(raw, dict) and raw.get("schema") == VM_EVIDENCE_SCHEMA:
        try:
            return parse_vm_evidence(path, raw)
        except VMVerifierError as exc:
            raise VerifierLogError(str(exc)) from exc
    if not isinstance(raw, dict) or raw.get("schema") != EVIDENCE_SCHEMA:
        raise VerifierLogError("JSON input is not verifier-only evidence")
    if raw.get("host_mutation") is not False:
        raise VerifierLogError("verifier evidence must have host_mutation=false")
    reject_contradictions(raw, "verifier evidence")
    status = require_text(raw, "parsed_verifier_status")
    reason = require_text(raw, "parsed_verifier_reason")
    if status not in STATUSES:
        raise VerifierLogError(f"verifier evidence has invalid parsed status: {status}")
    if len(require_text(raw, "object_sha256")) != 64 or len(require_text(raw, "bpf_metadata_object_sha256")) != 64:
        raise VerifierLogError("verifier evidence requires object and metadata sha")
    if require_text(raw, "sched_ext_state_before") != require_text(raw, "sched_ext_state_after"):
        raise VerifierLogError("verifier evidence changed sched_ext state")
    if require_text(raw, "enable_seq_before") != require_text(raw, "enable_seq_after"):
        raise VerifierLogError("verifier evidence changed sched_ext enable_seq")
    if require_text(raw, "cgroup_membership_before") != require_text(raw, "cgroup_membership_after"):
        raise VerifierLogError("verifier evidence changed cgroup membership")
    return {
        "schema": SCHEMA,
        "status": status,
        "reason": reason,
        "input": path.as_posix(),
        "object": require_text(raw, "object"),
        "object_sha256": require_text(raw, "object_sha256"),
        "bpf_metadata_path": require_text(raw, "bpf_metadata_path"),
        "bpf_metadata_object_sha256": require_text(raw, "bpf_metadata_object_sha256"),
        "bpftool_rc": None,
        "verifier_errors": [],
        "sched_ext_state_before": require_text(raw, "sched_ext_state_before"),
        "sched_ext_state_after": require_text(raw, "sched_ext_state_after"),
        "enable_seq_before": require_text(raw, "enable_seq_before"),
        "enable_seq_after": require_text(raw, "enable_seq_after"),
        "cgroup_membership_before": require_text(raw, "cgroup_membership_before"),
        "cgroup_membership_after": require_text(raw, "cgroup_membership_after"),
        "host_mutation": False,
    }


def require_text(data: JsonObject, field: str) -> str:
    value = data.get(field)
    if not isinstance(value, str) or value == "":
        raise VerifierLogError(f"verifier evidence missing text field: {field}")
    return value


def parse_refusal(path: Path, allow_refusal: bool) -> JsonObject:
    try:
        return parse_refusal_evidence(path, allow_refusal)
    except VerifierRefusalError as exc:
        raise VerifierLogError(str(exc)) from exc


def parse_input(path: Path, allow_refusal: bool) -> JsonObject:
    if path.suffix == ".json":
        return parse_refusal(path, allow_refusal)
    return parse_log(path)


def write_result(result: JsonObject, out_path: Path | None) -> None:
    text = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if out_path is None:
        print(text, end="")
    else:
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(text)


def self_test() -> None:
    import importlib

    module = importlib.import_module("verifier_log_selftest")
    module.run_self_test()


def run(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.self_test:
        self_test()
        return 0
    if args.evidence_path is not None:
        result = parse_evidence(args.evidence_path)
    elif args.input_path is not None:
        result = parse_input(args.input_path, args.allow_refusal)
    else:
        raise VerifierLogError("internal parser error")
    write_result(result, args.out_path)
    if result["status"] == "FAIL":
        return 1
    return 0


def main() -> int:
    try:
        return run(sys.argv[1:])
    except (OSError, json.JSONDecodeError, EvidenceSafetyError, VerifierLogError) as exc:
        print(f"FAIL verifier log check: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
