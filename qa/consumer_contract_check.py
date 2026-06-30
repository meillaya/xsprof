#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
# ─── How to run ───
# python3 qa/consumer_contract_check.py --fixtures fixtures/frontend-contract --schemas schemas/control --docs docs/control
from __future__ import annotations

import argparse
import json
import shutil
import sys
from collections.abc import Callable, Iterable
from dataclasses import dataclass
from pathlib import Path
from tempfile import TemporaryDirectory
from typing import Final

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from qa.frontend_contract_pack_check import load_codes, load_jsonl, validate as validate_pack
from qa.frontend_contract_matrix_ref import validate_referenced_matrix_manifest
from qa.frontend_contract_pack_semantics import REQUIRED_SCENARIOS
from qa.frontend_contract_pack_types import Args as PackArgs
from qa.frontend_contract_pack_types import ContractPackError, JsonObject
from qa.matrix_run_contract_check import MatrixRunContractError

TERMINAL_BAD: Final = {"INCIDENT", "REFUSE", "refused", "unsafe_to_assume", "FAIL", "SKIP"}
TERMINAL_OK: Final = {"PASS", "already_clean"}
FAILURE_EVENTS: Final = {"rollback", "cleanup"}
ALLOWED_STATES_BY_EVENT: Final = {
    "state_changed": frozenset({"read_only", "rollback_ready"}),
    "stage_started": frozenset({"vm_only_pending"}),
    "lab_run_active": frozenset({"partial_switch_lab"}),
    "boot": frozenset({"vm_live"}),
    "verifier": frozenset({"verified"}),
    "attach": frozenset({"zigsched_minimal"}),
    "runtime_sample": frozenset({"observing"}),
    "rollback": frozenset({"rollback_active", "incident"}),
    "rollback_completed": frozenset({"rolled_back"}),
    "cleanup": frozenset({"clean", "incident"}),
    "validation": frozenset({"perf_gate_failed", "matrix_artifact_referenced", "release_ineligible"}),
    "incident": frozenset({"unsafe_to_assume"}),
    "refusal": frozenset({"refused_host", "unsafe_to_assume"}),
    "stage_finished": frozenset({"vm_live_complete", "unsafe_to_assume"}),
}
REQUIRED_DOC_TEXT: Final = (
    "events.follow",
    "one-shot follow equivalent to replay",
    "lost stream",
    "matrix artifact reference",
    "dotted labels",
    "not v1 wire values",
)


@dataclass(frozen=True, slots=True)
class Args:
    fixtures: Path
    schemas: Path
    docs: Path
    self_test: bool


class ConsumerContractError(Exception):
    pass


class ParsedArgs(argparse.Namespace):
    fixtures: Path
    schemas: Path
    docs: Path

    def __init__(self) -> None:
        super().__init__()
        self.fixtures = Path()
        self.schemas = Path()
        self.docs = Path()


def parse_args(argv: list[str]) -> Args:
    if argv == ["--self-test"]:
        return Args(Path("fixtures/frontend-contract"), Path("schemas/control"), Path("docs/control"), True)
    parser = argparse.ArgumentParser(description="Validate backend-only future-consumer contract expectations.")
    _ = parser.add_argument("--fixtures", required=True, type=Path)
    _ = parser.add_argument("--schemas", required=True, type=Path)
    _ = parser.add_argument("--docs", required=True, type=Path)
    parsed = parser.parse_args(argv, namespace=ParsedArgs())
    return Args(parsed.fixtures, parsed.schemas, parsed.docs, False)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ConsumerContractError(message)


def text(row: JsonObject, field: str, context: str) -> str:
    value = row.get(field)
    if not isinstance(value, str) or value == "":
        raise ConsumerContractError(f"{context} missing text field {field}")
    return value


def status(row: JsonObject) -> str:
    raw = row.get("status")
    return raw if isinstance(raw, str) else ""


def reason(row: JsonObject) -> str:
    raw = row.get("reason")
    return raw if isinstance(raw, str) else ""


def event(row: JsonObject, context: str) -> str:
    return text(row, "event", context)


def rows_with_reason(rows: Iterable[JsonObject], wanted: str) -> list[JsonObject]:
    return [row for row in rows if reason(row) == wanted]


def require_docs(docs: Path) -> None:
    pack = docs / "frontend-api-pack.md"
    try:
        lower = " ".join(pack.read_text().lower().split())
    except FileNotFoundError as exc:
        raise ConsumerContractError(f"missing frontend API pack: {pack}") from exc
    for needle in REQUIRED_DOC_TEXT:
        require(needle.lower() in lower, f"frontend API pack missing consumer semantic: {needle}")


def validate_lifecycle_row(name: str, row: JsonObject) -> None:
    context = f"{name}:{row.get('seq', '?')}"
    row_event = event(row, context)
    row_state = row.get("state")
    if row_state is None:
        return
    if not isinstance(row_state, str) or row_state == "":
        raise ConsumerContractError(f"{context} has non-text lifecycle state")
    allowed = ALLOWED_STATES_BY_EVENT.get(row_event)
    if allowed is None:
        raise ConsumerContractError(f"{context} uses undocumented lifecycle event {row_event}")
    require(row_state in allowed, f"{context} has unknown lifecycle transition {row_event}->{row_state}")


def validate_reason(name: str, row: JsonObject, codes: set[str]) -> None:
    row_reason = reason(row)
    if row_reason == "":
        return
    require("." not in row_reason, f"{name} uses dotted namespace label as v1 wire reason: {row_reason}")
    if row_reason != "microvm_live_runner_start":
        require(row_reason in codes, f"{name} has undocumented incident/refusal reason: {row_reason}")


def validate_failure_terminal(name: str, rows: list[JsonObject]) -> None:
    for index, row in enumerate(rows):
        row_event = event(row, name)
        row_reason = reason(row)
        if row_event not in FAILURE_EVENTS or status(row) != "FAIL":
            continue
        later = rows[index + 1 :]
        require(row_reason != "", f"{name} failed {row_event} must carry a reason")
        require(
            any(event(item, name) == "incident" and reason(item) == row_reason and status(item) in TERMINAL_BAD for item in later),
            f"{name} missing terminal incident after failed {row_event}",
        )


def validate_stale_duplicate(name: str, rows: list[JsonObject]) -> None:
    for row in rows_with_reason(rows, "stale_target") + rows_with_reason(rows, "duplicate_target") + rows_with_reason(rows, "duplicate_target_id"):
        row_status = status(row)
        require(row_status not in TERMINAL_OK, f"{name} accepted stale/duplicate target as success")
        require(event(row, name) == "refusal" and row_status in TERMINAL_BAD, f"{name} did not visibly refuse stale/duplicate target")


def validate_runtime_samples(name: str, rows: list[JsonObject]) -> None:
    rejected_seen = False
    workload_dead_seen = False
    sample_loss_seen = False
    for row in rows:
        if event(row, name) == "runtime_sample":
            require(status(row) == "accepted", f"{name} runtime sample was not accepted before deriving alerts")
            nr_rejected = row.get("nr_rejected")
            rejected_seen = rejected_seen or (isinstance(nr_rejected, str) and nr_rejected not in {"", "0"})
            workload_dead_seen = workload_dead_seen or row.get("workload_alive") is False
            sample_loss_seen = sample_loss_seen or row.get("sample_sequence") == 7
        if reason(row) == "runtime_nr_rejected_nonzero":
            require(rejected_seen, f"{name} nr_rejected incident preceded sample")
        if reason(row) == "runtime_workload_dead":
            require(workload_dead_seen, f"{name} workload-dead incident preceded sample")
        if reason(row) == "runtime_sample_loss":
            require(sample_loss_seen, f"{name} sample-loss incident lacked prior accepted sample")


def validate_lost_stream(rows: list[JsonObject]) -> None:
    statuses = [status(row) for row in rows]
    require(statuses == ["queued", "unsafe_to_assume", "INCIDENT"], "lost-stream fixture must queue, incident, then terminal INCIDENT")
    require(not any(item == "PASS" for item in statuses), "lost-stream fixture must not claim PASS")


def validate_replay(rows_by_name: dict[str, list[JsonObject]], docs: Path) -> None:
    event_rows = rows_by_name["replay-event-cursor"]
    follow_text = (docs / "frontend-api-pack.md").read_text().lower()
    require("events.follow" in follow_text and "replay" in follow_text, "events.follow must remain replay-equivalent in docs")
    require(event_rows[0].get("seq") == 2, "event replay cursor must preserve source event seq")
    require(all(row.get("replay_cursor") == "event_seq" for row in event_rows), "event replay rows must advertise event_seq cursor")


def validate_matrix(name: str, rows: list[JsonObject]) -> None:
    for row in rows:
        if reason(row) != "matrix_artifact_referenced":
            continue
        artifact = text(row, "artifact", name)
        require(artifact.endswith("/manifest.json"), f"{name} matrix artifact must reference manifest.json")
        try:
            validate_referenced_matrix_manifest(Path(artifact))
        except MatrixRunContractError as exc:
            raise ConsumerContractError(f"{name} matrix artifact failed deep validation: {exc}") from exc
        return
    raise ConsumerContractError(f"{name} missing matrix artifact validation handoff")


def validate_consumer(args: Args) -> None:
    validate_pack(PackArgs(args.fixtures, args.schemas, args.docs, False))
    require_docs(args.docs)
    codes = load_codes(args.docs)
    rows_by_name: dict[str, list[JsonObject]] = {}
    for scenario in REQUIRED_SCENARIOS:
        rows = load_jsonl(args.fixtures / f"{scenario}.jsonl")
        rows_by_name[scenario] = rows
        for row in rows:
            validate_lifecycle_row(scenario, row)
            validate_reason(scenario, row, codes)
        validate_failure_terminal(scenario, rows)
        validate_stale_duplicate(scenario, rows)
        validate_runtime_samples(scenario, rows)
    validate_lost_stream(rows_by_name["lost-stream"])
    validate_matrix("matrix-artifact-reference", rows_by_name["matrix-artifact-reference"])
    validate_replay(rows_by_name, args.docs)


def write_rows(path: Path, rows: list[JsonObject]) -> None:
    _ = path.write_text("".join(json.dumps(row, sort_keys=True) + "\n" for row in rows))


def run_self_test(args: Args) -> None:
    validate_consumer(args)
    with TemporaryDirectory(prefix="zigsched-consumer-contract-") as tmp:
        root = Path(tmp)

        def reject(label: str, fixture_name: str, mutate: Callable[[list[JsonObject]], None]) -> None:
            fixtures = root / f"fixtures-{label}"
            _ = shutil.copytree(args.fixtures, fixtures)
            rows = load_jsonl(fixtures / fixture_name)
            mutate(rows)
            write_rows(fixtures / fixture_name, rows)
            try:
                validate_consumer(Args(fixtures, args.schemas, args.docs, False))
            except (ConsumerContractError, ContractPackError) as exc:
                print(f"PASS consumer self-test rejected {label}: {exc}")
            else:
                raise ConsumerContractError(f"self-test failed to reject {label}")

        def miss_terminal(rows: list[JsonObject]) -> None:
            rows[:] = rows[:2]

        def no_matrix_deep_validation(rows: list[JsonObject]) -> None:
            rows[0]["artifact"] = "evidence/lab/matrix/missing-consumer/manifest.json"
            rows[0]["artifact_paths"] = ["evidence/lab/matrix/missing-consumer/manifest.json"]

        reject("unknown lifecycle transition", "queued.jsonl", lambda rows: rows[0].__setitem__("state", "teleported"))
        reject("missing rollback terminal", "rollback-failure.jsonl", miss_terminal)
        reject("missing cleanup terminal", "cleanup-residue.jsonl", miss_terminal)
        reject("undocumented incident reason", "incident.jsonl", lambda rows: rows[0].__setitem__("reason", "new_unknown_reason"))
        reject("dotted namespace wire reason", "rpc-invalid-version.jsonl", lambda rows: rows[0].__setitem__("reason", "rpc.invalid_version"))
        reject("stale target success", "stale-target.jsonl", lambda rows: rows[0].__setitem__("status", "PASS"))
        reject("duplicate target success", "duplicate-target.jsonl", lambda rows: rows[0].__setitem__("status", "PASS"))
        reject("matrix artifact without deep validation", "matrix-artifact-reference.jsonl", no_matrix_deep_validation)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    try:
        if args.self_test:
            run_self_test(args)
        else:
            validate_consumer(args)
    except (OSError, ContractPackError, ConsumerContractError) as exc:
        print(f"FAIL backend consumer contract: {exc}", file=sys.stderr)
        return 1
    print(f"PASS backend consumer contract: fixtures={args.fixtures} docs={args.docs}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
