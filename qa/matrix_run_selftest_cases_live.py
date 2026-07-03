#!/usr/bin/env python3
"""Live-backend manifest self-test mutations for matrix-run checks."""
from __future__ import annotations

from pathlib import Path

from qa.matrix_run_json import load_json, obj, text
from qa.matrix_run_model import MatrixRunContractError
from qa.matrix_run_selftest_common import ManifestSelfTestContext, assert_invalid_manifest, write_json
from qa.matrix_run_selftest_pack import write_manifest_self_test_pack


def handle_live_manifest_case(ctx: ManifestSelfTestContext) -> bool:
    match ctx.name:  # noqa: RUF100  # noqa: MATCH_OK - self-test case names are runtime strings; false means another group may own it.
        case "live-backend-forged-pass-without-marker-proof":
            live_manifest, live_artifact_path = _live_manifest_artifact(ctx)
            live_row = load_json(live_artifact_path)
            marker = obj(live_row.get("vm_marker"), "live-backend self-test vm_marker")
            marker["checked_by"] = "qa/vm/marker-check"
            write_json(live_artifact_path, live_row)
            assert_invalid_manifest(live_manifest, ctx.name, "vm_marker.checked_by must stay under")
        case "live-backend-missing-cleanup-proof-artifact":
            live_manifest, live_artifact_path = _live_manifest_artifact(ctx)
            live_row = load_json(live_artifact_path)
            Path(text(live_row.get("cleanup_proof_path"), "live-backend cleanup_proof_path")).unlink()
            assert_invalid_manifest(live_manifest, ctx.name, "missing JSON file")
        case "live-backend-missing-host-refusal-proof-artifact":
            live_manifest, live_artifact_path = _live_manifest_artifact(ctx)
            live_row = load_json(live_artifact_path)
            Path(text(live_row.get("host_refusal_proof_path"), "live-backend host_refusal_proof_path")).unlink()
            assert_invalid_manifest(live_manifest, ctx.name, "missing JSON file")
        case "live-backend-daemon-events-outside-root":
            live_manifest, live_artifact_path = _live_manifest_artifact(ctx)
            live_row = load_json(live_artifact_path)
            live_row["daemon_event_path"] = "fixtures/matrix-run/pass.json"
            write_json(live_artifact_path, live_row)
            assert_invalid_manifest(live_manifest, ctx.name, "daemon_event_path must stay under")
        case "live-backend-dirty-summary-masked-pass":
            live_manifest, live_artifact_path = _live_manifest_artifact(ctx)
            backend_dir = live_artifact_path.parent / "backend"
            live_dir = backend_dir / "live"
            live_dir.mkdir(parents=True)
            write_json(live_dir / "summary.json", {"schema": "zig-scheduler/run-all-lab/v1", "status": "PASS", "git_sha": "abcdef012345", "git_dirty": True, "host_mutation": False})
            write_json(backend_dir / "summary.json", {"schema": "zig-scheduler/vm-backend-run/v1", "status": "PASS", "live_summary": (live_dir / "summary.json").as_posix(), "host_mutation": False})
            assert_invalid_manifest(live_manifest, ctx.name, "dirty live backend summary cannot back")
        case "live-backend-missing-live-summary-artifact":
            live_manifest, live_artifact_path = _live_manifest_artifact(ctx)
            backend_dir = live_artifact_path.parent / "backend"
            backend_dir.mkdir(parents=True, exist_ok=True)
            write_json(backend_dir / "summary.json", {"schema": "zig-scheduler/vm-backend-run/v1", "status": "PASS", "host_mutation": False})
            assert_invalid_manifest(live_manifest, ctx.name, "live-backend PASS row requires backend/live/summary.json live summary path")
        case "live-backend-noncanonical-live-summary-path":
            live_manifest, live_artifact_path = _live_manifest_artifact(ctx)
            backend_dir = live_artifact_path.parent / "backend"
            observe_dir = backend_dir / "live" / "observe-partial"
            observe_dir.mkdir(parents=True, exist_ok=True)
            write_json(observe_dir / "summary.json", {"schema": "zig-scheduler/observe-partial-summary/v1", "status": "PASS", "evidence_mode": "vm-live", "host_mutation": False})
            write_json(backend_dir / "summary.json", {"schema": "zig-scheduler/vm-backend-run/v1", "status": "PASS", "live_summary": (observe_dir / "summary.json").as_posix(), "host_mutation": False})
            assert_invalid_manifest(live_manifest, ctx.name, "canonical backend/live/summary.json bundle")
        case "live-backend-fake-unavailable-counter":
            live_manifest, live_artifact_path = _live_manifest_artifact(ctx)
            backend_dir = live_artifact_path.parent / "backend"
            live_dir = backend_dir / "live"
            from qa.live_behavior_check import write_bundle as write_live_behavior_bundle

            _ = write_live_behavior_bundle(live_dir, fake_unavailable_counter=True)
            write_json(backend_dir / "summary.json", {"schema": "zig-scheduler/vm-backend-run/v1", "status": "PASS", "live_summary": (live_dir / "summary.json").as_posix(), "host_mutation": False})
            assert_invalid_manifest(live_manifest, ctx.name, "claims numeric value while events are unavailable")
        case "extra-property":
            ctx.manifest["unexpected_field_not_in_schema"] = "reject"
            write_json(ctx.manifest_path, ctx.manifest)
            assert_invalid_manifest(ctx.manifest_path, ctx.name)
        case _:
            return False
    return True


def _live_manifest_artifact(ctx: ManifestSelfTestContext) -> tuple[Path, Path]:
    live_manifest = write_manifest_self_test_pack(ctx.run_root, ctx.good, "live-backend")
    live_rows = load_json(live_manifest).get("rows")
    if not isinstance(live_rows, list):
        raise MatrixRunContractError("live-backend self-test setup produced non-list rows")
    live_row_ref = obj(live_rows[0], "live-backend self-test manifest row")
    live_artifact_path = Path(text(live_row_ref.get("artifact_path"), "live-backend self-test artifact_path"))
    return live_manifest, live_artifact_path
