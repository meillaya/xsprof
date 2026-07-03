#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
# ─── How to run ───
# 1. Install uv (if not installed):
#      curl -LsSf https://astral.sh/uv/install.sh | sh
# 2. Run directly:
#      uv run qa/partial_attach_check.py --evidence evidence/lab/partial/partial-attach-evidence.json
# 3. Self-test:
#      python3 qa/partial_attach_check.py --self-test
# ──────────────────
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import json
import shutil
import sys
from typing import Final

_ = sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from qa.evidence_safety_check import EvidenceSafetyError, JsonObject, JsonValue, reject_contradictions  # noqa: E402

SCHEMA: Final[str] = "zig-scheduler/partial-attach-evidence/v1"
REFUSAL_SCHEMA: Final[str] = "zig-scheduler/partial-attach-refusal/v1"
SELF_ROOT: Final[Path] = Path("evidence/lab/partial-attach-self-test")
TARGET_PREFIX: Final[str] = "/sys/fs/cgroup/zig-scheduler-lab.slice/"


@dataclass(frozen=True, slots=True)
class Args:
    evidence: Path | None
    self_test: bool


class PartialAttachError(Exception):
    pass


def parse_args(argv: list[str]) -> Args:
    if argv == ["--self-test"]:
        return Args(evidence=None, self_test=True)
    if len(argv) == 2 and argv[0] == "--evidence":
        return Args(evidence=Path(argv[1]), self_test=False)
    raise PartialAttachError("usage: partial_attach_check.py --evidence <partial-attach-evidence.json> | --self-test")


def load_object(path: Path) -> JsonObject:
    raw: JsonValue = json.loads(path.read_text())
    if not isinstance(raw, dict):
        raise PartialAttachError(f"{path} must contain a JSON object")
    return raw


def require_text(data: JsonObject, field: str) -> str:
    value = data.get(field)
    if not isinstance(value, str) or value == "":
        raise PartialAttachError(f"partial attach evidence missing text field: {field}")
    return value


def require_bool(data: JsonObject, field: str) -> bool:
    value = data.get(field)
    if not isinstance(value, bool):
        raise PartialAttachError(f"partial attach evidence missing bool field: {field}")
    return value


def validate_evidence(path: Path) -> None:
    evidence = load_object(path)
    if require_text(evidence, "schema") != SCHEMA:
        if evidence.get("schema") == REFUSAL_SCHEMA:
            raise PartialAttachError("host refusal is not partial attach evidence")
        raise PartialAttachError("unsupported partial attach evidence schema")
    reject_contradictions(evidence, "partial attach evidence")
    if require_bool(evidence, "host_mutation"):
        raise PartialAttachError("partial attach evidence host_mutation must be false")
    if require_bool(evidence, "release_eligible_live_proof"):
        raise PartialAttachError("fixture partial attach evidence must not be release eligible")
    if require_text(evidence, "ops_during_attach") != "zigsched_minimal":
        raise PartialAttachError("partial attach evidence missing zigsched_minimal ops")
    if require_text(evidence, "switch_mode") != "SCX_OPS_SWITCH_PARTIAL":
        raise PartialAttachError("partial attach evidence is not partial-switch mode")
    if require_text(evidence, "attach_command") != "bpftool struct_ops register":
        raise PartialAttachError("partial attach evidence missing bpftool struct_ops register")
    target = require_text(evidence, "target_cgroup")
    if not target.startswith(TARGET_PREFIX) or target == TARGET_PREFIX:
        raise PartialAttachError("partial attach target is outside allowlisted lab cgroup")
    if require_text(evidence, "rollback_id") == "":
        raise PartialAttachError("partial attach evidence missing rollback id")
    if require_text(evidence, "rollback_status") != "PASS":
        raise PartialAttachError("partial attach rollback did not pass")
    post_state = require_text(evidence, "post_state")
    if post_state not in {"disabled", "previous"}:
        raise PartialAttachError(f"partial attach post state is unsafe: {post_state}")
    if require_text(evidence, "object_sha256") == "0" * 64:
        raise PartialAttachError("partial attach evidence missing real object hash")
    transcript = Path(require_text(evidence, "transcript_path"))
    if transcript.is_absolute() or ".." in transcript.parts or not transcript.exists():
        raise PartialAttachError("partial attach transcript path is missing or unsafe")
    text = transcript.read_text()
    for needle in ("bpftool struct_ops register", "ops=zigsched_minimal", "rollback_status=PASS"):
        if needle not in text:
            raise PartialAttachError(f"partial attach transcript missing {needle}")


def self_test() -> None:
    shutil.rmtree(SELF_ROOT, ignore_errors=True)
    SELF_ROOT.mkdir(parents=True)
    transcript = SELF_ROOT / "partial-attach-transcript.txt"
    transcript.write_text("bpftool struct_ops register\nops=zigsched_minimal\nrollback_status=PASS\n")
    good = make_evidence(transcript)
    validate_evidence(good)
    reject_variant("bad-host-mutation.json", transcript, {"host_mutation": True}, "host mutation")
    reject_variant("bad-release.json", transcript, {"release_eligible_live_proof": True}, "release eligible")
    reject_variant("bad-ops.json", transcript, {"ops_during_attach": "other"}, "bad ops")
    reject_variant("bad-target.json", transcript, {"target_cgroup": "/sys/fs/cgroup/system.slice/escaped.service"}, "bad target")
    refusal = SELF_ROOT / "host-refusal.json"
    refusal.write_text(json.dumps({"schema": REFUSAL_SCHEMA, "host_mutation": False}) + "\n")
    reject_path(refusal, "host refusal")
    shutil.rmtree(SELF_ROOT, ignore_errors=True)
    print("PASS partial attach self-test: accepted fixture evidence and rejected unsafe variants")


def make_evidence(transcript: Path) -> Path:
    path = SELF_ROOT / "partial-attach-evidence.json"
    data = {
        "schema": SCHEMA,
        "attach_command": "bpftool struct_ops register",
        "host_mutation": False,
        "release_eligible_live_proof": False,
        "target_cgroup": "/sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope",
        "rollback_id": "RB-self-test",
        "rollback_status": "PASS",
        "ops_during_attach": "zigsched_minimal",
        "switch_mode": "SCX_OPS_SWITCH_PARTIAL",
        "post_state": "disabled",
        "object_sha256": "a" * 64,
        "transcript_path": transcript.as_posix(),
    }
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
    return path


def reject_variant(name: str, transcript: Path, updates: JsonObject, label: str) -> None:
    path = make_evidence(transcript)
    data = load_object(path)
    data.update(updates)
    bad = SELF_ROOT / name
    bad.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
    reject_path(bad, label)


def reject_path(path: Path, label: str) -> None:
    try:
        validate_evidence(path)
    except (EvidenceSafetyError, PartialAttachError) as exc:
        print(f"PASS reject {label}: {exc}")
        return
    raise PartialAttachError(f"expected rejection did not occur: {label}")


def run(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.self_test:
        self_test()
        return 0
    if args.evidence is None:
        raise PartialAttachError("internal argument parser error")
    validate_evidence(args.evidence)
    print(f"PASS partial attach evidence: {args.evidence}")
    return 0


def main() -> int:
    try:
        return run(sys.argv[1:])
    except (EvidenceSafetyError, OSError, json.JSONDecodeError, PartialAttachError) as exc:
        print(f"FAIL partial attach evidence: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
