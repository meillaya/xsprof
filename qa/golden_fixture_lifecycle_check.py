#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
# ─── How to run ───
# python3 qa/golden_fixture_lifecycle_check.py --docs docs/control --control fixtures/control/golden --frontend fixtures/frontend-contract
# python3 qa/golden_fixture_lifecycle_check.py --self-test
# ──────────────────
"""Validate backend JSONL stream framing and fixture lifecycle documentation."""

from __future__ import annotations

import argparse
import json
import shlex
import shutil
import sys
from dataclasses import dataclass
from pathlib import Path
from tempfile import TemporaryDirectory
from collections.abc import Callable
from typing import Final

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from qa.daemon_golden_transcript_check import REQUIRED_SCENARIOS as CONTROL_REQUIRED
from qa.frontend_contract_pack_semantics import REQUIRED_SCENARIOS as FRONTEND_REQUIRED
from qa.frontend_contract_pack_types import ContractPackError, JsonObject, parse_json_value

CONTROL_ROOT: Final = Path("fixtures/control/golden")
FRONTEND_ROOT: Final = Path("fixtures/frontend-contract")
STREAM_DOC: Final = "stream-semantics.md"
EVENT_SCHEMA: Final = "zig-scheduler/daemon-event/v1"
REPLAY_FIXTURES: Final = {"replay-event-cursor", "replay-runtime-sample-cursor"}
REQUIRED_STREAM_TEXT: Final = (
    "UTF-8",
    "one JSON object per line",
    "newline-terminated",
    "`events.follow` is replay-equivalent",
    "not a live stream",
    "future v2",
    "lost_stream",
)


@dataclass(frozen=True, slots=True)
class Args:
    docs: Path
    control: Path
    frontend: Path
    self_test: bool


class LifecycleError(Exception):
    """Raised when stream fixture lifecycle evidence is stale or unsafe."""


class ParsedArgs(argparse.Namespace):
    docs: Path
    control: Path
    frontend: Path

    def __init__(self) -> None:
        super().__init__()
        self.docs = Path()
        self.control = Path()
        self.frontend = Path()


def parse_args(argv: list[str]) -> Args:
    if argv == ["--self-test"]:
        return Args(Path("docs/control"), CONTROL_ROOT, FRONTEND_ROOT, True)
    parser = argparse.ArgumentParser(description="Validate stream fixture lifecycle rules.")
    _ = parser.add_argument("--docs", default=Path("docs/control"), type=Path)
    _ = parser.add_argument("--control", default=CONTROL_ROOT, type=Path)
    _ = parser.add_argument("--frontend", default=FRONTEND_ROOT, type=Path)
    parsed = parser.parse_args(argv, namespace=ParsedArgs())
    return Args(parsed.docs, parsed.control, parsed.frontend, False)


def is_allowed_fixture_path(path: Path) -> bool:
    if path.is_absolute() or ".." in path.parts:
        return False
    return path.suffix == ".jsonl" and (path.is_relative_to(CONTROL_ROOT) or path.is_relative_to(FRONTEND_ROOT))


def fixture_names(root: Path) -> set[str]:
    return {path.stem for path in root.glob("*.jsonl") if path.is_file()}


def require_inventory(root: Path, required: tuple[str, ...], label: str) -> None:
    actual = fixture_names(root)
    expected = set(required)
    missing = sorted(expected - actual)
    if missing:
        raise LifecycleError(f"{label} missing documented fixture(s): {', '.join(missing)}")


def load_jsonl_frames(path: Path) -> list[JsonObject]:
    try:
        raw_text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError as exc:
        raise LifecycleError(f"{path} is not valid UTF-8") from exc
    if raw_text == "":
        raise LifecycleError(f"{path} is empty")
    if not raw_text.endswith("\n"):
        raise LifecycleError(f"{path} must be newline-terminated")
    rows: list[JsonObject] = []
    for line_number, line in enumerate(raw_text.splitlines(), start=1):
        if line.strip() == "":
            raise LifecycleError(f"{path}:{line_number} blank JSONL row")
        try:
            value = parse_json_value(line, f"{path}:{line_number}")
        except ContractPackError as exc:
            raise LifecycleError(f"{path}:{line_number} invalid one-line JSON object: {exc}") from exc
        if not isinstance(value, dict):
            raise LifecycleError(f"{path}:{line_number} is not a JSON object")
        rows.append(value)
    return rows


def validate_monotonic(path: Path, rows: list[JsonObject]) -> None:
    expected = rows[0].get("seq")
    if not isinstance(expected, int):
        raise LifecycleError(f"{path}: first seq must be an integer")
    if path.stem not in REPLAY_FIXTURES and expected != 1:
        raise LifecycleError(f"{path}: first seq must be 1")
    if path.stem == "replay-event-cursor" and expected < 2:
        raise LifecycleError(f"{path}: replay event cursor must start after seq 1")
    for row in rows:
        if row.get("schema") != EVENT_SCHEMA:
            raise LifecycleError(f"{path}: unsupported event schema")
        if row.get("seq") != expected:
            raise LifecycleError(f"{path}: nonmonotonic seq, expected {expected}")
        if row.get("host_mutation") is not False:
            raise LifecycleError(f"{path}: host_mutation must be false")
        expected += 1


def validate_fixture_file(path: Path) -> None:
    validate_monotonic(path, load_jsonl_frames(path))


def load_stream_doc(docs: Path) -> str:
    path = docs / STREAM_DOC
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError as exc:
        raise LifecycleError(f"missing stream semantics doc: {path}") from exc
    for needle in REQUIRED_STREAM_TEXT:
        if needle not in text:
            raise LifecycleError(f"{path} missing required stream semantics text: {needle}")
    return text


def validate_documented_fixtures(text: str, control: Path, frontend: Path) -> None:
    roots = ((control, CONTROL_ROOT), (frontend, FRONTEND_ROOT))
    for actual_root, documented_root in roots:
        for path in sorted(actual_root.glob("*.jsonl")):
            rel = (documented_root / path.name).as_posix()
            if rel not in text:
                raise LifecycleError(f"stale undocumented fixture: {rel}")


def command_paths(command: str) -> list[Path]:
    paths: list[Path] = []
    tokens = shlex.split(command)
    for index, token in enumerate(tokens):
        if token.endswith(".jsonl"):
            paths.append(Path(token))
        if token in {">", "1>", "--output", "--fixture", "--update-fixture"} and index + 1 < len(tokens):
            paths.append(Path(tokens[index + 1]))
    return paths


def validate_update_commands(text: str) -> None:
    commands = [line.removeprefix("fixture-update:").strip() for line in text.splitlines() if line.startswith("fixture-update:")]
    if not commands:
        raise LifecycleError("stream semantics doc has no fixture-update commands")
    for command in commands:
        paths = command_paths(command)
        if not paths:
            raise LifecycleError(f"fixture-update command has no fixture path: {command}")
        for path in paths:
            if not is_allowed_fixture_path(path):
                raise LifecycleError(f"fixture-update command writes outside allowed roots: {path}")


def validate(args: Args) -> None:
    require_inventory(args.control, CONTROL_REQUIRED, "control golden")
    require_inventory(args.frontend, FRONTEND_REQUIRED, "frontend contract")
    for root in (args.control, args.frontend):
        for path in sorted(root.glob("*.jsonl")):
            validate_fixture_file(path)
    text = load_stream_doc(args.docs)
    validate_documented_fixtures(text, args.control, args.frontend)
    validate_update_commands(text)


def expect_rejected(label: str, action: Callable[[], None]) -> None:
    try:
        action()
    except LifecycleError as exc:
        print(f"PASS self-test rejected {label}: {exc}")
        return
    raise LifecycleError(f"self-test failed to reject {label}")


def run_self_test(args: Args) -> None:
    validate(args)
    with TemporaryDirectory(prefix="zigsched-stream-lifecycle-") as tmp:
        tmp_path = Path(tmp)
        docs = tmp_path / "docs"
        control = tmp_path / "control"
        frontend = tmp_path / "frontend"
        _ = shutil.copytree(args.docs, docs)
        _ = shutil.copytree(args.control, control)
        _ = shutil.copytree(args.frontend, frontend)
        pretty = control / "queued.jsonl"
        _ = pretty.write_text('{\n  "schema": "zig-scheduler/daemon-event/v1",\n  "seq": 1\n}\n', encoding="utf-8")
        expect_rejected("pretty multiline JSONL", lambda: validate(Args(docs, control, frontend, False)))
        _ = shutil.copy2(args.control / "queued.jsonl", pretty)
        queued_row = load_jsonl_frames(pretty)[0]
        _ = pretty.write_text(
            json.dumps(queued_row, sort_keys=True) + json.dumps(queued_row, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        expect_rejected("two JSON objects in one JSONL row", lambda: validate(Args(docs, control, frontend, False)))
        _ = shutil.copy2(args.control / "queued.jsonl", pretty)
        replay = frontend / "replay-event-cursor.jsonl"
        rows = load_jsonl_frames(replay)
        rows[1]["seq"] = rows[0]["seq"]
        _ = replay.write_text("".join(json.dumps(row, sort_keys=True) + "\n" for row in rows), encoding="utf-8")
        expect_rejected("nonmonotonic replay rows", lambda: validate(Args(docs, control, frontend, False)))
        _ = shutil.copy2(args.frontend / "replay-event-cursor.jsonl", replay)
        doc_path = docs / STREAM_DOC
        _ = doc_path.write_text(doc_path.read_text(encoding="utf-8").replace("fixtures/frontend-contract/lost-stream.jsonl", "fixtures/frontend-contract/lost-stream.removed"), encoding="utf-8")
        expect_rejected("stale undocumented fixture", lambda: validate(Args(docs, control, frontend, False)))
        _ = doc_path.write_text((args.docs / STREAM_DOC).read_text(encoding="utf-8") + "\nfixture-update: python3 tools/bad.py --output /tmp/escape.jsonl\n", encoding="utf-8")
        expect_rejected("unsafe fixture update command", lambda: validate(Args(docs, control, frontend, False)))


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    try:
        if args.self_test:
            run_self_test(args)
        else:
            validate(args)
    except (OSError, UnicodeError, LifecycleError) as exc:
        print(f"FAIL golden fixture lifecycle: {exc}", file=sys.stderr)
        return 1
    print(f"PASS golden fixture lifecycle: control={args.control} frontend={args.frontend} docs={args.docs}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
