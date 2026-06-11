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
# 3. Self-test:
#      python3 qa/verifier_log_check.py --self-test
# ──────────────────
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import json
import shutil
import sys
from typing import Final, Literal, TypeAlias

JsonValue: TypeAlias = None | bool | int | float | str | list[str] | list["JsonValue"] | dict[str, "JsonValue"]
JsonObject: TypeAlias = dict[str, JsonValue]
Status: TypeAlias = Literal["PASS", "SKIP", "FAIL", "REFUSE"]

SCHEMA: Final[str] = "zig-scheduler/verifier-log-parse/v1"
REFUSAL_SCHEMA: Final[str] = "zig-scheduler/verifier-only-refusal/v1"
SELF_ROOT: Final[Path] = Path("evidence/lab/verifier-log-self-test")


@dataclass(frozen=True, slots=True)
class Args:
    input_path: Path | None
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
        return Args(input_path=None, out_path=None, allow_refusal=False, self_test=True)
    input_path: Path | None = None
    out_path: Path | None = None
    allow_refusal = False
    index = 0
    while index < len(argv):
        arg = argv[index]
        if arg == "--input" and index + 1 < len(argv):
            input_path = Path(argv[index + 1]); index += 2
        elif arg == "--out" and index + 1 < len(argv):
            out_path = Path(argv[index + 1]); index += 2
        elif arg == "--allow-refusal":
            allow_refusal = True; index += 1
        else:
            raise VerifierLogError("usage: verifier_log_check.py --input <log-or-json> [--out <json>] [--allow-refusal] | --self-test")
    if input_path is None:
        raise VerifierLogError("--input is required")
    return Args(input_path=input_path, out_path=out_path, allow_refusal=allow_refusal, self_test=False)


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
    parsed = parse_lines(path.read_text())
    reason = reason_from(parsed)
    status = status_from(reason)
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
        "verifier_errors": parsed.errors,
        "sched_ext_state_before": parsed.values.get("sched_ext_state_before", ""),
        "sched_ext_state_after": parsed.values.get("sched_ext_state_after", ""),
        "enable_seq_before": parsed.values.get("sched_ext_enable_seq_before", ""),
        "enable_seq_after": parsed.values.get("sched_ext_enable_seq_after", ""),
        "cgroup_membership_before": parsed.values.get("cgroup_membership_before", ""),
        "cgroup_membership_after": parsed.values.get("cgroup_membership_after", ""),
        "host_mutation": False,
    }


def parse_refusal(path: Path, allow_refusal: bool) -> JsonObject:
    raw: JsonValue = json.loads(path.read_text())
    if not isinstance(raw, dict) or raw.get("schema") != REFUSAL_SCHEMA:
        raise VerifierLogError("JSON input is not a verifier refusal")
    if not allow_refusal:
        raise VerifierLogError("host refusal evidence requires --allow-refusal")
    if raw.get("host_mutation") is not False:
        raise VerifierLogError("refusal evidence must have host_mutation=false")
    return {
        "schema": SCHEMA,
        "status": "REFUSE",
        "reason": str(raw.get("reason", "UNKNOWN_REFUSAL")),
        "input": path.as_posix(),
        "object": str(raw.get("object", "")),
        "object_sha256": str(raw.get("object_sha256", "")),
        "bpf_metadata_path": str(raw.get("bpf_metadata_path", "")),
        "bpf_metadata_object_sha256": str(raw.get("bpf_metadata_object_sha256", "")),
        "bpftool_rc": None,
        "verifier_errors": [],
        "host_mutation": False,
    }


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
    shutil.rmtree(SELF_ROOT, ignore_errors=True)
    SELF_ROOT.mkdir(parents=True)
    bad = write_log("bad.log", "invalid mem access 'scalar'\nbpftool_rc=255")
    skip = write_log("skip.log", "SKIP: bpftool unavailable inside VM; verifier load not attempted")
    clean = write_log("clean.log", "bpftool_rc=0")
    missing = SELF_ROOT / "missing-state.log"
    missing.write_text("schema=zig-scheduler/bpf-verifier-log/v1\nobject=zig-out/bpf/min.o\nobject_sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nbpftool_rc=0\n")
    state_delta = SELF_ROOT / "state-delta.log"
    state_delta.write_text("\n".join((
        "schema=zig-scheduler/bpf-verifier-log/v1",
        "object=zig-out/bpf/zigsched_minimal.bpf.o",
        "object_sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nbpf_metadata_path=zig-out/bpf/zigsched_minimal.bpf.meta.json\nbpf_metadata_object_sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "sched_ext_state_before=enabled",
        "sched_ext_enable_seq_before=1",
        "bpftool_rc=0",
        "sched_ext_state_after=disabled",
        "sched_ext_enable_seq_after=1",
        "cgroup_membership_before=abc",
        "cgroup_membership_after=abc",
    )) + "\n")
    assert_result(parse_log(bad), "FAIL", "INVALID_MEM_ACCESS")
    assert_result(parse_log(skip), "SKIP", "BPFTOOL_UNAVAILABLE")
    assert_result(parse_log(clean), "PASS", "VERIFIER_ACCEPTED")
    assert_result(parse_log(missing), "FAIL", "MISSING_STATE_EVIDENCE")
    assert_result(parse_log(state_delta), "FAIL", "SCHED_EXT_STATE_CHANGED")
    refusal = SELF_ROOT / "host-refusal.json"
    refusal.write_text(json.dumps({"schema": REFUSAL_SCHEMA, "status": "refused-host", "reason": "marker required", "object": "obj.o", "host_mutation": False}) + "\n")
    assert_result(parse_refusal(refusal, allow_refusal=True), "REFUSE", "marker required")
    try:
        parse_refusal(refusal, allow_refusal=False)
    except VerifierLogError:
        pass
    else:
        raise VerifierLogError("refusal without --allow-refusal was accepted")
    shutil.rmtree(SELF_ROOT, ignore_errors=True)
    print("PASS verifier log self-test: fail/skip/pass/refusal cases classified")


def write_log(name: str, tail: str) -> Path:
    path = SELF_ROOT / name
    body = "\n".join((
        "schema=zig-scheduler/bpf-verifier-log/v1",
        "object=zig-out/bpf/zigsched_minimal.bpf.o",
        "object_sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nbpf_metadata_path=zig-out/bpf/zigsched_minimal.bpf.meta.json\nbpf_metadata_object_sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "sched_ext_state_before=enabled",
        "sched_ext_enable_seq_before=1",
        tail,
        "sched_ext_state_after=enabled",
        "sched_ext_enable_seq_after=1",
        "cgroup_membership_before=abc",
        "cgroup_membership_after=abc",
    ))
    path.write_text(body + "\n")
    return path


def assert_result(result: JsonObject, status: Status, reason: str) -> None:
    if result.get("status") != status or result.get("reason") != reason:
        raise VerifierLogError(f"expected {status}/{reason}, got {result}")


def run(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.self_test:
        self_test()
        return 0
    if args.input_path is None:
        raise VerifierLogError("internal parser error")
    result = parse_input(args.input_path, args.allow_refusal)
    write_result(result, args.out_path)
    if result["status"] == "FAIL":
        return 1
    return 0


def main() -> int:
    try:
        return run(sys.argv[1:])
    except (OSError, json.JSONDecodeError, VerifierLogError) as exc:
        print(f"FAIL verifier log check: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
