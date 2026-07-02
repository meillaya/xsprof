#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""# noqa: SIZE_OK - live evidence validator keeps schema-specific live proof checks together."""
# ─── How to run ───
# python3 qa/live_lab_evidence_check.py --file evidence/lab/<bundle>/<proof>.json
# python3 qa/live_lab_evidence_check.py --self-test
# ──────────────────
from __future__ import annotations

from pathlib import Path
import json
import shutil
import subprocess
import sys
from typing import Final, TypeAlias, assert_never

JsonValue: TypeAlias = None | bool | int | float | str | list["JsonValue"] | dict[str, "JsonValue"]
JsonObject: TypeAlias = dict[str, JsonValue]

ACTION_SCHEMA: Final[str] = "zig-scheduler/action-journal/v1"
EVENT_SCHEMA: Final[str] = "zig-scheduler/daemon-event-journal/v1"
TRANSCRIPT_SCHEMA: Final[str] = "zig-scheduler/vm-transcript-index/v1"
ATTACH_SCHEMA: Final[str] = "zig-scheduler/live-attach-proof/v1"
BEHAVIOR_SCHEMA: Final[str] = "zig-scheduler/live-behavior-proof/v1"
ROLLBACK_SCHEMA: Final[str] = "zig-scheduler/rollback-result/v1"
VM_MARKER: Final[str] = "/run/zig-scheduler-vm-lab.marker"
LIVE_MODE: Final[str] = "vm-live"
LIVE_VM_KIND: Final[str] = "qemu-vm"
EVIDENCE_MODES: Final[frozenset[str]] = frozenset({"host-safe-surrogate", "vm-configured-skip", LIVE_MODE})
FORBIDDEN_KEYS: Final[frozenset[str]] = frozenset({"cmdline", "command_line", "argv", "env", "environment", "raw_log", "private_log", "secret", "token", "hostname"})
FORBIDDEN_TEXT: Final[tuple[str, ...]] = ("--token", "password=", "api_key=", "AWS_SECRET", "BEGIN PRIVATE KEY")


class LiveEvidenceError(Exception):
    """Raised when live-lab evidence is malformed or unsafe."""


def parse_args(argv: list[str]) -> tuple[Path | None, bool]:
    if argv == ["--self-test"]:
        return None, True
    if len(argv) == 2 and argv[0] == "--file":
        return Path(argv[1]), False
    raise LiveEvidenceError("usage: live_lab_evidence_check.py --file <proof.json> | --self-test")


def load_object(path: Path) -> JsonObject:
    try:
        raw: JsonValue = json.loads(path.read_text())
    except FileNotFoundError as exc:
        raise LiveEvidenceError(f"missing JSON file: {path}") from exc
    except json.JSONDecodeError as exc:
        raise LiveEvidenceError(f"invalid JSON in {path}: {exc}") from exc
    if not isinstance(raw, dict):
        raise LiveEvidenceError(f"{path} must contain a JSON object")
    return raw


def require_string(data: JsonObject, field: str, context: str) -> str:
    value = data.get(field)
    if not isinstance(value, str) or value == "":
        raise LiveEvidenceError(f"{context} missing non-empty string field: {field}")
    return value


def require_bool(data: JsonObject, field: str, context: str) -> bool:
    value = data.get(field)
    if not isinstance(value, bool):
        raise LiveEvidenceError(f"{context} missing bool field: {field}")
    return value


def require_int(data: JsonObject, field: str, context: str) -> int:
    value = data.get(field)
    if not isinstance(value, int):
        raise LiveEvidenceError(f"{context} missing integer field: {field}")
    return value


def require_object(data: JsonObject, field: str, context: str) -> JsonObject:
    value = data.get(field)
    if not isinstance(value, dict):
        raise LiveEvidenceError(f"{context} missing object field: {field}")
    return value


def require_list(data: JsonObject, field: str, context: str) -> list[JsonValue]:
    value = data.get(field)
    if not isinstance(value, list) or len(value) == 0:
        raise LiveEvidenceError(f"{context} missing non-empty list field: {field}")
    return value


def current_git_sha() -> str:
    result = subprocess.run(["git", "rev-parse", "HEAD"], check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if result.returncode != 0:
        raise LiveEvidenceError("cannot determine current git sha")
    return result.stdout.strip()


def reject_private(value: JsonValue, context: str) -> None:
    match value:
        case dict():
            for key, child in value.items():
                lowered = key.lower()
                if lowered in FORBIDDEN_KEYS:
                    raise LiveEvidenceError(f"privacy-unsafe key in evidence: {context}.{key}")
                reject_private(child, f"{context}.{key}")
        case list():
            for index, child in enumerate(value):
                reject_private(child, f"{context}[{index}]")
        case str():
            for needle in FORBIDDEN_TEXT:
                if needle in value:
                    raise LiveEvidenceError(f"privacy-unsafe text in evidence: {context}")
        case None | bool() | int() | float():
            return
        case unreachable:
            assert_never(unreachable)


def require_safe_relative_path(raw: str, context: str) -> None:
    path = Path(raw)
    if path.is_absolute() or ".." in path.parts:
        raise LiveEvidenceError(f"{context} path escapes repository: {raw}")


def validate_common(data: JsonObject, context: str) -> None:
    reject_private(data, context)
    require_string(data, "action_id", context)
    if require_bool(data, "host_mutation", context):
        raise LiveEvidenceError(f"{context} host_mutation must be false")
    mode = require_string(data, "evidence_mode", context)
    if mode not in EVIDENCE_MODES:
        raise LiveEvidenceError(f"{context} evidence_mode is invalid: {mode}")
    private_logs = data.get("private_logs")
    if isinstance(private_logs, bool) and private_logs:
        raise LiveEvidenceError(f"{context} private logs are not allowed")



def validate_git_sha(data: JsonObject, context: str) -> None:
    if require_string(data, "git_sha", context) != current_git_sha():
        raise LiveEvidenceError(f"{context} git_sha is stale")


def validate_checked_common(data: JsonObject, context: str) -> None:
    validate_common(data, context)
    validate_git_sha(data, context)

def validate_live_gate(data: JsonObject, context: str) -> None:
    if require_string(data, "evidence_mode", context) != LIVE_MODE:
        raise LiveEvidenceError(f"{context} is not vm-live evidence")
    if require_string(data, "vm_kind", context) != LIVE_VM_KIND:
        raise LiveEvidenceError(f"{context} vm-live evidence must come from qemu-vm")
    if not require_bool(data, "vm_marker_present", context):
        raise LiveEvidenceError(f"{context} missing VM marker")
    if require_string(data, "vm_marker_path", context) != VM_MARKER:
        raise LiveEvidenceError(f"{context} VM marker path is invalid")
    kernel = require_object(data, "kernel_tuple", context)
    for field in ("release", "arch", "config_sha256"):
        require_string(kernel, field, f"{context}.kernel_tuple")


def validate_paths(values: list[JsonValue], context: str) -> None:
    for index, value in enumerate(values):
        if not isinstance(value, str) or value == "":
            raise LiveEvidenceError(f"{context}[{index}] must be non-empty path text")
        require_safe_relative_path(value, f"{context}[{index}]")


def validate_file(path: Path) -> None:
    data = load_object(path)
    schema = require_string(data, "schema", "evidence")
    match schema:  # noqa: RUF100  # noqa: MATCH_OK - schema is runtime JSON text; default raises typed rejection for unknown schemas.
        case "zig-scheduler/action-journal/v1":
            validate_action(data)
        case "zig-scheduler/daemon-event-journal/v1":
            validate_event(data)
        case "zig-scheduler/vm-transcript-index/v1":
            validate_transcript_index(data)
        case "zig-scheduler/live-attach-proof/v1":
            validate_attach(data)
        case "zig-scheduler/live-behavior-proof/v1":
            validate_behavior(data)
        case "zig-scheduler/rollback-result/v1":
            validate_rollback(data)
        case _:
            raise LiveEvidenceError(f"unsupported evidence schema: {schema}")


def validate_action(data: JsonObject) -> None:
    validate_checked_common(data, "action")
    require_string(data, "action", "action")
    require_string(data, "timestamp", "action")


def validate_event(data: JsonObject) -> None:
    validate_checked_common(data, "event")
    require_int(data, "sequence", "event")
    require_string(data, "event", "event")
    require_string(data, "status", "event")


def validate_transcript_index(data: JsonObject) -> None:
    validate_common(data, "transcript_index")
    validate_live_gate(data, "transcript_index")
    validate_git_sha(data, "transcript_index")
    validate_paths(require_list(data, "transcript_paths", "transcript_index"), "transcript_index.transcript_paths")
    validate_paths(require_list(data, "command_allowlist", "transcript_index"), "transcript_index.command_allowlist")
    cleanup = require_object(data, "cleanup", "transcript_index")
    if require_bool(cleanup, "qemu_leftovers", "transcript_index.cleanup"):
        raise LiveEvidenceError("transcript_index cleanup reports qemu leftovers")


def validate_attach(data: JsonObject) -> None:
    validate_common(data, "attach")
    validate_live_gate(data, "attach")
    validate_git_sha(data, "attach")
    for field in ("audit_id", "rollback_id", "target_cgroup", "registered_ops"):
        require_string(data, field, "attach")


def validate_behavior(data: JsonObject) -> None:
    validate_common(data, "behavior")
    validate_live_gate(data, "behavior")
    validate_git_sha(data, "behavior")
    require_string(data, "scheduler_state", "behavior")
    require_string(data, "registered_ops", "behavior")
    require_int(data, "runtime_events", "behavior")
    if not require_bool(data, "workload_alive", "behavior"):
        raise LiveEvidenceError("behavior workload must be live during observation")


def validate_rollback(data: JsonObject) -> None:
    validate_common(data, "rollback")
    validate_live_gate(data, "rollback")
    validate_git_sha(data, "rollback")
    require_string(data, "rollback_id", "rollback")
    if require_string(data, "result", "rollback") != "PASS":
        raise LiveEvidenceError("rollback result must pass for live proof")
    if not require_bool(data, "idempotent", "rollback"):
        raise LiveEvidenceError("rollback must be idempotent")



def good_base(schema: str, git_sha: str) -> JsonObject:
    return {"schema": schema, "action_id": "act-live", "evidence_mode": LIVE_MODE, "git_sha": git_sha, "host_mutation": False, "private_logs": False}


def add_live(data: JsonObject) -> JsonObject:
    data.update({"vm_kind": LIVE_VM_KIND, "vm_marker_present": True, "vm_marker_path": VM_MARKER, "kernel_tuple": {"release": "6.12.0-lab", "arch": "x86_64", "config_sha256": "sha"}})
    return data


def reject(path: Path, label: str) -> None:
    try:
        validate_file(path)
    except LiveEvidenceError as exc:
        print(f"PASS reject {label}: {exc}")
        return
    raise LiveEvidenceError(f"expected rejection did not occur: {label}")


def self_test() -> None:
    root = Path("evidence/lab/live-evidence-check-self-test")
    shutil.rmtree(root, ignore_errors=True)
    root.mkdir(parents=True)
    (root / "transcript.txt").write_text("ACTION queued run_lab_host_safe\nFAIL-CLOSED\n")
    git_sha = current_git_sha()
    cases: list[JsonObject] = [
        {**good_base(ACTION_SCHEMA, git_sha), "evidence_mode": "host-safe-surrogate", "action": "run_lab_host_safe", "timestamp": "2026-06-12T00:00:00Z"},
        {**good_base(EVENT_SCHEMA, git_sha), "sequence": 1, "event": "state_changed", "status": "queued"},
        add_live({**good_base(TRANSCRIPT_SCHEMA, git_sha), "transcript_paths": [str(root / "transcript.txt")], "command_allowlist": ["qa/vm/run_all_lab.sh"], "cleanup": {"qemu_leftovers": False}}),
        add_live({**good_base(ATTACH_SCHEMA, git_sha), "audit_id": "AUD-20990101T000000Z-deadbee-abc123", "rollback_id": "RB-demo", "target_cgroup": "/sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope", "registered_ops": "zigsched_minimal_ops"}),
        add_live({**good_base(BEHAVIOR_SCHEMA, git_sha), "scheduler_state": "enabled", "registered_ops": "zigsched_minimal_ops", "runtime_events": 3, "workload_alive": True}),
        add_live({**good_base(ROLLBACK_SCHEMA, git_sha), "rollback_id": "RB-demo", "result": "PASS", "idempotent": True}),
    ]
    for index, case in enumerate(cases):
        path = root / f"good-{index}.json"
        path.write_text(json.dumps(case, indent=2, sort_keys=True) + "\n")
        validate_file(path)
    reject(Path("fixtures/lab/live-proof-surrogate-as-live.json"), "surrogate marked vm-live")
    missing_action = root / "missing-action-id.json"
    bad = add_live({**good_base(ATTACH_SCHEMA, git_sha), "audit_id": "AUD-20990101T000000Z-deadbee-abc123", "rollback_id": "RB-demo", "target_cgroup": "/sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope", "registered_ops": "zigsched_minimal_ops"})
    del bad["action_id"]
    missing_action.write_text(json.dumps(bad, sort_keys=True) + "\n")
    reject(missing_action, "missing action id")
    missing_marker = root / "missing-vm-marker.json"
    bad = add_live({**good_base(ATTACH_SCHEMA, git_sha), "audit_id": "AUD-20990101T000000Z-deadbee-abc123", "rollback_id": "RB-demo", "target_cgroup": "/sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope", "registered_ops": "zigsched_minimal_ops"})
    bad["vm_marker_present"] = False
    missing_marker.write_text(json.dumps(bad, sort_keys=True) + "\n")
    reject(missing_marker, "missing VM marker")
    stale = root / "stale-git-sha.json"
    bad = add_live({**good_base(ATTACH_SCHEMA, "0000000"), "audit_id": "AUD-20990101T000000Z-deadbee-abc123", "rollback_id": "RB-demo", "target_cgroup": "/sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope", "registered_ops": "zigsched_minimal_ops"})
    stale.write_text(json.dumps(bad, sort_keys=True) + "\n")
    reject(stale, "stale git sha")
    private = root / "private-log.json"
    bad = {**good_base(EVENT_SCHEMA, git_sha), "sequence": 1, "event": "incident", "status": "refused", "raw_log": "password=secret"}
    private.write_text(json.dumps(bad, sort_keys=True) + "\n")
    reject(private, "private log fields")
    shutil.rmtree(root)
    print("PASS live lab evidence self-test: live schemas accept VM proof and reject surrogate/stale/private evidence")


def run(argv: list[str]) -> int:
    file_path, should_self_test = parse_args(argv)
    if should_self_test:
        self_test()
        return 0
    if file_path is None:
        raise LiveEvidenceError("internal argument parser error")
    validate_file(file_path)
    print(f"PASS live lab evidence schema: {file_path}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(run(sys.argv[1:]))
    except LiveEvidenceError as exc:
        print(f"FAIL live lab evidence schema: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
