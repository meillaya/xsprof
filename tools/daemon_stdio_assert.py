#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///

# ─── How to run ───
# 1. Install uv (if not installed):
#      curl -LsSf https://astral.sh/uv/install.sh | sh
# 2. Run directly (no venv, no pip install needed):
#      uv run tools/daemon_stdio_assert.py <mode>
# 3. Or make executable and run:
#      chmod +x tools/daemon_stdio_assert.py && ./tools/daemon_stdio_assert.py <mode>
# ──────────────────

from __future__ import annotations

import json
import sys
from dataclasses import dataclass
from enum import StrEnum
from typing import Final, NoReturn, TypeAlias, assert_never

JsonValue: TypeAlias = None | bool | int | float | str | list["JsonValue"] | dict[str, "JsonValue"]
JsonObject: TypeAlias = dict[str, JsonValue]


class Field(StrEnum):
    EVENT = "event"
    STATUS = "status"
    STATE = "state"
    REASON = "reason"
    ACTION_ID = "action_id"
    TARGET_ACTION_ID = "target_action_id"
    ROLLBACK_ID = "rollback_id"
    HOST_MUTATION = "host_mutation"


class Mode(StrEnum):
    LIFECYCLE_SUCCESS = "lifecycle-success"
    LIFECYCLE_FIXTURE_REJECTED = "lifecycle-fixture-rejected"
    LOST_STREAM = "lost-stream"
    TIMEOUT = "timeout"
    INCIDENT_DRILL = "incident-drill"
    DUPLICATE_TARGET = "duplicate-target"
    MISSING_TARGET = "missing-target"
    MALFORMED_DEFAULT = "malformed-default"
    FAILED_ROLLBACK_REPLAY = "failed-rollback-replay"
    FAILED_CLEANUP_REPLAY = "failed-cleanup-replay"
    FAILED_LIVE_ROLLBACK = "failed-live-rollback"
    FAILED_LIVE_CLEANUP = "failed-live-cleanup"
    JOURNAL_REPLAY = "journal-replay"
    ACTIVE_ROLLBACK = "active-rollback"
    STOP_CLEANUP = "stop-cleanup"


@dataclass(frozen=True, slots=True)
class DaemonRow:
    event: str = ""
    status: str = ""
    state: str = ""
    reason: str = ""
    action_id: str = ""
    target_action_id: str = ""
    rollback_id: str = ""
    host_mutation: bool = True

    def field(self, name: str) -> str | bool:
        try:
            field = Field(name)
        except ValueError:
            fail(f"unknown daemon row field: {name}")
        match field:
            case Field.EVENT:
                return self.event
            case Field.STATUS:
                return self.status
            case Field.STATE:
                return self.state
            case Field.REASON:
                return self.reason
            case Field.ACTION_ID:
                return self.action_id
            case Field.TARGET_ACTION_ID:
                return self.target_action_id
            case Field.ROLLBACK_ID:
                return self.rollback_id
            case Field.HOST_MUTATION:
                return self.host_mutation
            case unreachable:
                assert_never(unreachable)


MODE_LABEL: Final[str] = sys.argv[1] if len(sys.argv) == 2 else ""


def fail(message: str) -> NoReturn:
    raise SystemExit(f"FAIL: {MODE_LABEL}: {message}")


def string_field(row: JsonObject, name: str) -> str:
    value = row.get(name)
    if isinstance(value, str):
        return value
    return ""


def parse_row(raw: JsonValue) -> DaemonRow:
    if not isinstance(raw, dict):
        fail(f"daemon row is not an object: {raw}")
    host_mutation = raw.get("host_mutation")
    if not isinstance(host_mutation, bool):
        fail(f"host_mutation is not boolean: {raw}")
    return DaemonRow(
        event=string_field(raw, "event"),
        status=string_field(raw, "status"),
        state=string_field(raw, "state"),
        reason=string_field(raw, "reason"),
        action_id=string_field(raw, "action_id"),
        target_action_id=string_field(raw, "target_action_id"),
        rollback_id=string_field(raw, "rollback_id"),
        host_mutation=host_mutation,
    )


def load_rows() -> list[DaemonRow]:
    rows: list[DaemonRow] = []
    for line in sys.stdin.read().splitlines():
        stripped = line.strip()
        if stripped.startswith("{"):
            parsed: JsonValue = json.loads(stripped)
            rows.append(parse_row(parsed))
    if not rows:
        fail("no JSON daemon rows")
    for row in rows:
        if row.host_mutation is not False:
            fail(f"host_mutation is not false: {row}")
    return rows


def has(rows: list[DaemonRow], **want: str) -> bool:
    return any(all(row.field(key) == value for key, value in want.items()) for row in rows)


def matching(rows: list[DaemonRow], **want: str) -> list[DaemonRow]:
    return [row for row in rows if all(row.field(key) == value for key, value in want.items())]


def reject_incident_then_pass(rows: list[DaemonRow]) -> None:
    incident_seen = False
    for row in rows:
        if row.event == "incident":
            incident_seen = True
        if incident_seen and row.event == "stage_finished" and row.status == "PASS":
            fail(f"incident followed by PASS terminal row: {row}")


def require_non_pass_terminal(rows: list[DaemonRow]) -> None:
    terminals = matching(rows, event="stage_finished")
    if not terminals:
        fail("missing terminal stage_finished row")
    if any(row.status == "PASS" for row in terminals):
        fail(f"terminal stage_finished unexpectedly passed: {terminals}")


def assert_lifecycle_success(rows: list[DaemonRow]) -> None:
    for event in ("runtime_sample", "rollback", "cleanup"):
        if not any(row.event == event for row in rows):
            fail(f"missing {event}")
    if any(row.event == "incident" for row in rows):
        fail("unexpected incident in success lifecycle")
    if not has(rows, event="stage_finished", status="PASS", state="vm_live_complete"):
        fail("missing final vm_live_complete PASS")


def assert_active_rollback(rows: list[DaemonRow]) -> None:
    if not has(
        rows,
        event="rollback_completed",
        action_id="rb-live-rollback-1",
        target_action_id="live-rollback-1",
        rollback_id="RB-rollback-1",
        state="rolled_back",
        status="PASS",
    ):
        fail("missing semantic rollback completion for active target")
    if any(row.reason in {"stale_target", "stale_rollback_id"} for row in rows):
        fail("active rollback was refused as stale")


def assert_stop_cleanup(rows: list[DaemonRow]) -> None:
    if not has(
        rows,
        event="cleanup",
        action_id="stop-live-1",
        target_action_id="live-stop-1",
        rollback_id="RB-stop-1",
        state="clean",
        status="PASS",
    ):
        fail("missing first stop cleanup completion")
    if not has(
        rows,
        event="cleanup",
        action_id="stop-live-2",
        target_action_id="live-stop-1",
        rollback_id="RB-stop-1",
        state="clean",
        status="already_clean",
    ):
        fail("missing idempotent second stop cleanup completion")


def assert_failed_live(rows: list[DaemonRow], event: str) -> None:
    if not has(rows, event=event, status="FAIL", state="incident"):
        fail(f"missing failed live {event} event")
    if not has(rows, event="stage_finished", status="INCIDENT", state="unsafe_to_assume"):
        fail("failed live stream did not terminate as INCIDENT")
    if not has(rows, event="refusal", reason="duplicate_target_id"):
        fail("failed live terminal event cleared active target; duplicate target was not refused")


def assert_incident_terminal(rows: list[DaemonRow]) -> None:
    if not any(row.event == "incident" for row in rows):
        fail("missing incident row")
    require_non_pass_terminal(rows)


def parse_mode(raw: str) -> Mode:
    try:
        return Mode(raw)
    except ValueError:
        fail("unknown json assertion mode")


def assert_mode(rows: list[DaemonRow], mode: Mode) -> None:
    reject_incident_then_pass(rows)
    match mode:
        case Mode.LIFECYCLE_SUCCESS:
            assert_lifecycle_success(rows)
        case Mode.LIFECYCLE_FIXTURE_REJECTED:
            if not has(rows, event="incident", reason="live_bundle_rejected"):
                fail("fixture live bundle was not rejected")
            if not has(rows, event="stage_finished", status="INCIDENT", state="unsafe_to_assume"):
                fail("fixture live bundle did not terminate as INCIDENT")
            if has(rows, event="stage_finished", status="PASS", state="vm_live_complete"):
                fail("fixture live bundle emitted vm_live_complete PASS")
        case Mode.LOST_STREAM | Mode.TIMEOUT:
            assert_incident_terminal(rows)
        case Mode.INCIDENT_DRILL:
            if not has(rows, event="incident", status="INCIDENT", state="incident"):
                fail("missing incident drill incident row")
            require_non_pass_terminal(rows)
        case Mode.DUPLICATE_TARGET:
            if not has(rows, event="refusal", reason="duplicate_target_id"):
                fail("duplicate target was not refused")
        case Mode.MISSING_TARGET:
            if not has(rows, event="refusal", reason="target_id_required"):
                fail("missing target was not refused")
        case Mode.MALFORMED_DEFAULT:
            if not any(row.reason == "malformed_action" for row in rows):
                fail("malformed input was not refused")
        case Mode.FAILED_ROLLBACK_REPLAY | Mode.FAILED_CLEANUP_REPLAY:
            if not has(rows, event="refusal", reason="duplicate_target_id"):
                fail("failed terminal replay cleared active target")
        case Mode.FAILED_LIVE_ROLLBACK:
            assert_failed_live(rows, "rollback")
        case Mode.FAILED_LIVE_CLEANUP:
            assert_failed_live(rows, "cleanup")
        case Mode.JOURNAL_REPLAY:
            if any(row.reason == "duplicate_target_id" for row in rows):
                fail("successful terminal replay left target active")
        case Mode.ACTIVE_ROLLBACK:
            assert_active_rollback(rows)
        case Mode.STOP_CLEANUP:
            assert_stop_cleanup(rows)
        case unreachable:
            assert_never(unreachable)


if len(sys.argv) != 2:
    raise SystemExit("usage: daemon_stdio_assert.py <mode>")
assert_mode(load_rows(), parse_mode(sys.argv[1]))
