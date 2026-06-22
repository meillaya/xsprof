#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# ///
# ─── How to run ───
# python3 tools/live_vm_desktop_failure_matrix.py --app zig-out/bin/zig-scheduler-live-vm-desktop
from __future__ import annotations

import json
import re
import shutil
import subprocess
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Final, TypeAlias

EVIDENCE_DIR: Final[Path] = Path(".omo/evidence/task-08-failure-matrix")
HOST_MUTATION_EVIDENCE: Final[Path] = Path(".omo/evidence/task-08-host-mutation-refused.json")
FAKE_DAEMON: Final[str] = "tools/live_vm_desktop_failure_daemon.py"
ANSI_RE: Final[re.Pattern[str]] = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")
BRIDGE_STATUS_RE: Final[re.Pattern[str]] = re.compile(r"controller_status=(?P<status>[a-z_]+)")
INCIDENT_REASONS: Final[frozenset[str]] = frozenset({"lost_stream_non_json", "stream_timeout", "rollback_failure", "cleanup_residue"})
REFUSAL_REASONS: Final[frozenset[str]] = frozenset({"verifier_reject", "duplicate_action_id", "stale_or_unknown_target_action_id", "host_mutation_not_false"})
FailMode: TypeAlias = str
JsonValue: TypeAlias = None | bool | int | float | str | list["JsonValue"] | dict[str, "JsonValue"]
JsonObject: TypeAlias = dict[str, JsonValue]


@dataclass(frozen=True, slots=True)
class Case:
    name: str
    expected_reason: str
    expected_mode: FailMode
    bridge_method: str = "run"
    reject_accepted_status: bool = True
    final_active_must_be_false: bool = True


@dataclass(frozen=True, slots=True)
class ObservedFailure:
    mode: FailMode
    reason: str
    source: str


@dataclass(frozen=True, slots=True)
class CaseResult:
    name: str
    command: list[str]
    returncode: int
    visible_text: str
    transcript_path: str
    screenshot_path: str
    host_mutation_false: bool
    actual_failure_mode: FailMode
    actual_reason: str
    controller_statuses: list[str]
    accepted_status_forbidden: bool
    final_active: bool | None
    visible_failure_state: bool
    expected_reason_visible: bool
    passed: bool


CASES: Final[tuple[Case, ...]] = (
    Case("qemu_unavailable", "qemu_unavailable", "SKIP"),
    Case("verifier_reject", "verifier_reject", "REFUSE"),
    Case("lost_stream", "lost_stream_non_json", "INCIDENT"),
    Case("timeout", "stream_timeout", "INCIDENT", "timeout-run"),
    Case("rollback_failure", "rollback_failure", "INCIDENT", reject_accepted_status=False),
    Case("cleanup_residue", "cleanup_residue", "INCIDENT"),
    Case("duplicate_action_id", "duplicate_action_id", "REFUSE", "duplicate-run", reject_accepted_status=False),
    Case("stale_target_id", "stale_or_unknown_target_action_id", "REFUSE", "stale-rollback", reject_accepted_status=False),
)


@dataclass(frozen=True, slots=True)
class CliArgs:
    app: str
    out_dir: Path


class MatrixError(Exception):
    """Raised when visible failure evidence cannot be rendered truthfully."""


def parse_cli(argv: list[str]) -> CliArgs:
    app = ""
    out_dir = EVIDENCE_DIR
    index = 0
    while index < len(argv):
        arg = argv[index]
        if arg == "--app":
            if index + 1 >= len(argv):
                raise SystemExit("missing --app value")
            app = argv[index + 1]
            index += 2
        elif arg == "--out":
            if index + 1 >= len(argv):
                raise SystemExit("missing --out value")
            out_dir = Path(argv[index + 1])
            index += 2
        elif arg in {"--help", "-h"}:
            print("usage: live_vm_desktop_failure_matrix.py --app <path> [--out .omo/evidence/task-08-failure-matrix]")
            raise SystemExit(0)
        else:
            raise SystemExit(f"unknown argument: {arg}")
    if not app:
        raise SystemExit("missing --app value")
    return CliArgs(app=app, out_dir=out_dir)


def strip_ansi(text: str) -> str:
    return ANSI_RE.sub("", text)


def command_for(app: str, case: Case, out_dir: Path) -> list[str]:
    state_dir = out_dir / case.name / "state"
    return [app, "--fake-daemon", FAKE_DAEMON, "--state-dir", str(state_dir), "--bridge-test", case.bridge_method]


def event_mode(event: JsonObject) -> FailMode | None:
    reason = str(event.get("reason", ""))
    status = str(event.get("status", ""))
    name = str(event.get("event", ""))
    if reason in REFUSAL_REASONS:
        return "REFUSE"
    if reason in INCIDENT_REASONS or name == "incident" or status == "incident":
        return "INCIDENT"
    if status == "SKIP":
        return "SKIP"
    if name == "refusal" or status in {"REFUSE", "refused"}:
        return "REFUSE"
    return None


def json_events(transcript: str) -> list[JsonObject]:
    events: list[JsonObject] = []
    for line in transcript.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            raw: JsonValue = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(raw, dict):
            events.append(raw)
    return events


def observe_failure(transcript: str, expected_reason: str) -> ObservedFailure:
    for event in json_events(transcript):
        if str(event.get("reason", "")) == expected_reason:
            mode = event_mode(event)
            if mode is not None:
                return ObservedFailure(mode=mode, reason=expected_reason, source=json.dumps(event, sort_keys=True))
    for event in json_events(transcript):
        mode = event_mode(event)
        if mode is not None:
            return ObservedFailure(mode=mode, reason=str(event.get("reason", "")), source=json.dumps(event, sort_keys=True))
    return ObservedFailure(mode="NONE", reason="", source="no failure event parsed from controller output")


def controller_statuses(transcript: str) -> list[str]:
    return [match.group("status") for match in BRIDGE_STATUS_RE.finditer(transcript)]


def final_active(transcript: str) -> bool | None:
    statuses = [event for event in json_events(transcript) if event.get("schema") == "zig-scheduler/live-vm-desktop-controller/v1"]
    if not statuses:
        return None
    active = statuses[-1].get("active")
    return active if isinstance(active, bool) else None


def visible_text(case: Case, observed: ObservedFailure, transcript: str, statuses: list[str], active: bool | None) -> str:
    clean = strip_ansi(transcript)
    return "\n".join((
        f"CASE {case.name}",
        f"ACTUAL_MODE {observed.mode}",
        f"ACTUAL_REASON {observed.reason or 'none'}",
        f"CONTROLLER_STATUSES {','.join(statuses) if statuses else 'none'}",
        f"FINAL_ACTIVE {active if active is not None else 'unknown'}",
        "VISIBLE_SOURCE " + observed.source[:420],
        "--- ACTUAL TRANSCRIPT TAIL ---",
        clean[-2500:],
    ))


def write_png_text(path: Path, text: str) -> None:
    renderer = shutil.which("magick") or shutil.which("convert")
    if renderer is None:
        raise MatrixError("ImageMagick magick/convert is required to render legible PNG text evidence")
    text_path = path.with_suffix(".visible.txt")
    text_path.write_text(text, encoding="utf-8")
    base = [renderer]
    if Path(renderer).name == "magick":
        base.append("convert")
    command = [*base, "-background", "#05070a", "-fill", "#d6ecff", "-font", "DejaVu-Sans-Mono", "-pointsize", "18", "-size", "1200x900", f"caption:@{text_path}", str(path)]
    completed = subprocess.run(command, capture_output=True, text=True, check=False, timeout=5)
    if completed.returncode != 0:
        raise MatrixError(f"failed to render {path}: {completed.stderr.strip()}")


def run_case(app: str, case: Case, out_dir: Path) -> CaseResult:
    case_dir = out_dir / case.name
    case_dir.mkdir(parents=True, exist_ok=True)
    command = command_for(app, case, out_dir)
    completed = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False, timeout=8)
    transcript = completed.stdout + completed.stderr
    transcript_path = case_dir / f"{case.name}.transcript.txt"
    transcript_path.write_text(transcript, encoding="utf-8")
    observed = observe_failure(transcript, case.expected_reason)
    statuses = controller_statuses(transcript)
    active = final_active(transcript)
    visible = visible_text(case, observed, transcript, statuses, active)
    screenshot_path = case_dir / f"{case.name}.png"
    write_png_text(screenshot_path, visible)
    clean = strip_ansi(transcript)
    host_mutation_false = "host_mutation=false" in clean or '"host_mutation":false' in clean
    accepted_status_forbidden = case.reject_accepted_status and "accepted" in statuses
    visible_failure_state = observed.mode in {"INCIDENT", "REFUSE", "SKIP"}
    expected_reason_visible = observed.reason == case.expected_reason and case.expected_reason in clean
    active_ok = not case.final_active_must_be_false or active is False
    passed = all((host_mutation_false, visible_failure_state, expected_reason_visible, observed.mode == case.expected_mode, not accepted_status_forbidden, active_ok))
    result = CaseResult(
        name=case.name,
        command=command,
        returncode=completed.returncode,
        visible_text=visible,
        transcript_path=str(transcript_path),
        screenshot_path=str(screenshot_path),
        host_mutation_false=host_mutation_false,
        actual_failure_mode=observed.mode,
        actual_reason=observed.reason,
        controller_statuses=statuses,
        accepted_status_forbidden=accepted_status_forbidden,
        final_active=active,
        visible_failure_state=visible_failure_state,
        expected_reason_visible=expected_reason_visible,
        passed=passed,
    )
    (case_dir / f"{case.name}.json").write_text(json.dumps(asdict(result), indent=2, sort_keys=True), encoding="utf-8")
    return result


def write_host_mutation_self_test(app: str, out_dir: Path) -> CaseResult:
    result = run_case(app, Case("host_mutation_true", "host_mutation_not_false", "REFUSE"), out_dir)
    HOST_MUTATION_EVIDENCE.parent.mkdir(parents=True, exist_ok=True)
    HOST_MUTATION_EVIDENCE.write_text(json.dumps(asdict(result), indent=2, sort_keys=True), encoding="utf-8")
    return result


def main(argv: list[str]) -> int:
    args = parse_cli(argv)
    args.out_dir.mkdir(parents=True, exist_ok=True)
    results = [run_case(args.app, case, args.out_dir) for case in CASES]
    host_result = write_host_mutation_self_test(args.app, args.out_dir)
    summary = {
        "schema": "zig-scheduler/live-vm-desktop-failure-matrix/v2",
        "host_mutation": False,
        "results": [asdict(result) for result in results],
        "host_mutation_self_test": asdict(host_result),
        "passed": all(result.passed for result in (*results, host_result)),
    }
    (args.out_dir / "summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True), encoding="utf-8")
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except MatrixError as exc:
        print(f"FAIL live-vm-desktop-failure-matrix: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
