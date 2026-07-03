#!/usr/bin/env python3
"""Live-backend summary consistency checks for matrix-run manifests."""
from __future__ import annotations

from pathlib import Path

from qa.live_behavior_check import LiveBehaviorError
from qa.live_behavior_check import validate_bundle as validate_live_behavior_bundle
from qa.matrix_run_json import load_json, obj, require, text
from qa.matrix_run_model import JsonObject, MatrixRunContractError

def validate_live_backend_summary_consistency(row: JsonObject, artifact_path: Path, context: str) -> None:
    scenario_id = text(row.get("scenario_id"), f"{context}.scenario_id")
    if scenario_id != "live-backend":
        return
    outcome = text(row.get("outcome"), f"{context}.outcome")
    evidence_mode = text(row.get("evidence_mode"), f"{context}.evidence_mode")
    if outcome != "PASS" or evidence_mode != "vm-live":
        return
    backend_summary_path = artifact_path.parent / "backend" / "summary.json"
    require(backend_summary_path.is_file(), f"{context} live-backend PASS row is missing backend summary artifact")
    backend_summary = load_json(backend_summary_path)
    require(text(backend_summary.get("schema"), f"{context}.backend_summary.schema") == "zig-scheduler/vm-backend-run/v1", f"{context} backend summary schema must be vm-backend-run/v1")
    require(text(backend_summary.get("status"), f"{context}.backend_summary.status") == "PASS", f"{context} backend summary must be PASS")
    require(backend_summary.get("host_mutation") is False, f"{context} backend summary host_mutation must be false")
    live_summary_value = backend_summary.get("live_summary")
    if not isinstance(live_summary_value, str) or live_summary_value == "":
        raise MatrixRunContractError(f"{context} live-backend PASS row requires backend/live/summary.json live summary path")
    live_summary_path = Path(live_summary_value)
    expected_live_summary_path = backend_summary_path.parent / "live" / "summary.json"
    require(live_summary_path == expected_live_summary_path, f"{context} live summary must point to the canonical backend/live/summary.json bundle")
    require(live_summary_path.is_file(), f"{context} live summary bundle is missing: {live_summary_path}")
    live_summary = load_json(live_summary_path)
    if live_summary.get("git_dirty") is True:
        require(outcome != "PASS" and evidence_mode != "vm-live", f"{context} dirty live backend summary cannot back a PASS vm-live matrix row")
    live_git_sha = live_summary.get("git_sha")
    git = obj(row.get("git"), f"{context}.git")
    actual_sha = text(git.get("actual_sha"), f"{context}.git.actual_sha")
    if isinstance(live_git_sha, str) and live_git_sha and not live_git_sha.startswith(actual_sha):
        require(outcome != "PASS" and evidence_mode != "vm-live", f"{context} stale live backend summary cannot back a PASS vm-live matrix row")
    if outcome == "PASS" and evidence_mode == "vm-live":
        try:
            validate_live_behavior_bundle(live_summary_path)
        except LiveBehaviorError as exc:
            raise MatrixRunContractError(f"{context} live backend summary failed nested live behavior validation: {exc}") from exc
