#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Release gate self-test and summary helpers for qa/release_gate.sh."""

# ─── How to run ───
# python3 qa/release_gate_selftest.py self-test-policy
# python3 qa/release_gate_selftest.py mutate-matrix-manifest <manifest> <run-id> <out-dir>
# python3 qa/release_gate_selftest.py write-skip-missing-live <out> <version> <bundle>
# python3 qa/release_gate_selftest.py write-no-approval-summary <out> <version> <current-run-bool>
# python3 qa/release_gate_selftest.py summary-status <summary.json>
# ──────────────────
from __future__ import annotations

from collections.abc import Callable
from pathlib import Path
import json
import shutil
import sys
from typing import Final, TypeAlias

_ = sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from qa.live_behavior_check import LiveBehaviorError, load_object as load_live_object, validate_bundle, write_bundle  # noqa: E402

JsonValue: TypeAlias = None | bool | int | float | str | list["JsonValue"] | dict[str, "JsonValue"]
JsonObject: TypeAlias = dict[str, JsonValue]
CURRENT_SELFTEST_GIT: Final[str] = "f" * 40
STALE_RELEASE_NAMES: Final[tuple[str, str]] = ("release-approval.json", "artifact-hashes.json")


class ReleaseGateSelftestError(Exception):
    """Raised when release gate helper validation fails."""


def load_object(path: Path) -> JsonObject:
    try:
        return load_live_object(path)
    except LiveBehaviorError as exc:
        raise ReleaseGateSelftestError(str(exc)) from exc


def write_object(path: Path, data: JsonObject) -> None:
    _ = path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")


def remove_stale_release_claims(out: Path) -> None:
    for name in STALE_RELEASE_NAMES:
        stale_path = out / name
        if stale_path.exists() or stale_path.is_symlink():
            stale_path.unlink()


def mutate_matrix_manifest(manifest: Path, run_id: str, out_dir: str) -> None:
    data = load_object(manifest)
    data["matrix_run_id"] = run_id
    data["out_dir"] = out_dir
    data["release_eligible"] = True
    write_object(manifest, data)
    for row_path in manifest.parent.joinpath("rows").glob("*/matrix-run.json"):
        row = load_object(row_path)
        row["matrix_run_id"] = run_id
        write_object(row_path, row)


def reject(label: str, func: Callable[[], None]) -> None:
    try:
        func()
    except SystemExit as exc:
        print(f"PASS reject {label}: {exc}")
        return
    raise ReleaseGateSelftestError(f"expected rejection did not occur: {label}")


def check_dsq(dsq: JsonObject) -> None:
    if dsq.get("status") != "PASS":
        raise SystemExit("dsq summary not PASS")
    if dsq.get("rollback_success") is not True:
        raise SystemExit("dsq rollback_success is not true")
    if dsq.get("starvation_breach") is not False:
        raise SystemExit("dsq starvation threshold breached")
    if dsq.get("repeated_fallback_or_reject_counters") is not False:
        raise SystemExit("dsq fallback/reject counters repeated")
    if dsq.get("release_eligible") is not True:
        raise SystemExit("dsq is not release eligible")
    if dsq.get("vm_kind") != "disposable-vm-marker-present":
        raise SystemExit("dsq evidence is not disposable VM evidence")
    bpf_sha = dsq.get("bpf_metadata_object_sha256")
    if not isinstance(bpf_sha, str) or bpf_sha == "":
        raise SystemExit("dsq missing BPF metadata sha")
    if dsq.get("verifier_metadata_object_sha256") != bpf_sha:
        raise SystemExit("dsq verifier metadata sha mismatch")


def check_stress(stress: JsonObject) -> None:
    if stress.get("status") != "PASS":
        raise SystemExit("stress summary not PASS")


def check_existing_approval(approval: JsonObject) -> None:
    if approval.get("git_sha") and approval.get("git_sha") != CURRENT_SELFTEST_GIT and approval.get("historical") is not True:
        raise SystemExit("stale current release approval git_sha")
    reviewer = str(approval.get("reviewer") or "")
    if reviewer.lower() in {"todo", "tbd", "placeholder", "unknown", "repository-owner-operator"}:
        raise SystemExit("placeholder release reviewer")
    att_value = approval.get("signed_attestation")
    att: JsonObject = att_value if isinstance(att_value, dict) else {}
    for key in ("kind", "signed_by", "signed_at", "statement", "authorized_status", "scope"):
        if approval and not att.get(key):
            raise SystemExit("missing signed release attestation")
    if approval and att.get("signed_by") != reviewer:
        raise SystemExit("release attestation signer mismatch")
    if approval and att.get("authorized_status") != approval.get("status"):
        raise SystemExit("release attestation status mismatch")
    if approval.get("historical") is True and not approval.get("historical_reason"):
        raise SystemExit("historical approval missing reason")
    manifest = approval.get("artifact_hash_manifest")
    if isinstance(manifest, str) and not Path(manifest).is_file() and approval.get("historical") is not True:
        raise SystemExit("missing artifact hash manifest")


def check_summary(summary: JsonObject) -> None:
    if summary.get("status") == "PASS" and summary.get("release_status") == "skipped_no_vm":
        raise SystemExit("summary/status contradiction")


def check_live_behavior_gate() -> None:
    root = Path("evidence/lab/run-all/release-gate-live-behavior-self-test")
    shutil.rmtree(root, ignore_errors=True)
    good = write_bundle(root / "good")
    validate_bundle(good)
    bad = write_bundle(root / "attach-only", include_observe=False)
    try:
        validate_bundle(bad)
    except LiveBehaviorError as exc:
        print(f"PASS reject surrogate attach-only live behavior: {exc}")
    else:
        raise ReleaseGateSelftestError("expected rejection did not occur: surrogate attach-only live behavior")
    shutil.rmtree(root, ignore_errors=True)


def check_skip_cleanup() -> None:
    out = Path("evidence/releases/self-test-skip-cleanup")
    out.mkdir(parents=True, exist_ok=True)
    for name in STALE_RELEASE_NAMES:
        _ = (out / name).write_text("stale release claim\n")
    remove_stale_release_claims(out)
    if any((out / name).exists() for name in STALE_RELEASE_NAMES):
        raise SystemExit("stale skip approval/hash cleanup failed")
    for child in out.iterdir():
        child.unlink()
    out.rmdir()


def run_self_test_policy() -> None:
    reject("rollback_success=false", lambda: check_dsq({"status": "PASS", "rollback_success": False}))
    reject("starvation breach", lambda: check_dsq({"status": "PASS", "rollback_success": True, "starvation_breach": True}))
    reject("fallback reject counters", lambda: check_dsq({"status": "PASS", "rollback_success": True, "starvation_breach": False, "repeated_fallback_or_reject_counters": True}))
    reject("host-safe dsq release eligible", lambda: check_dsq({"status": "PASS", "rollback_success": True, "starvation_breach": False, "repeated_fallback_or_reject_counters": False, "release_eligible": True, "vm_kind": "host-safe-disposable-sysroot", "bpf_metadata_object_sha256": "abc", "verifier_metadata_object_sha256": "abc"}))
    reject("missing verifier metadata", lambda: check_dsq({"status": "PASS", "rollback_success": True, "starvation_breach": False, "repeated_fallback_or_reject_counters": False, "release_eligible": True, "vm_kind": "disposable-vm-marker-present", "bpf_metadata_object_sha256": "abc"}))
    reject("stale current approval", lambda: check_existing_approval({"git_sha": "0" * 40, "historical": False}))
    approval_att: JsonObject = {"kind": "owner-override-release-attestation", "signed_by": "owner-override:repo", "signed_at": "2026-06-11T00:00:00Z", "authorized_status": "controlled_lab_pilot_candidate", "scope": "controlled-lab-only", "statement": "current"}
    reject("missing hash manifest", lambda: check_existing_approval({"git_sha": CURRENT_SELFTEST_GIT, "reviewer": "owner-override:repo", "status": "controlled_lab_pilot_candidate", "artifact_hash_manifest": "evidence/releases/missing-hashes.json", "signed_attestation": approval_att}))
    reject("placeholder release reviewer", lambda: check_existing_approval({"git_sha": CURRENT_SELFTEST_GIT, "reviewer": "TODO", "status": "controlled_lab_pilot_candidate"}))
    reject("unsigned release approval", lambda: check_existing_approval({"git_sha": CURRENT_SELFTEST_GIT, "reviewer": "owner-override:repo", "status": "controlled_lab_pilot_candidate"}))
    historical_att: JsonObject = {"kind": "owner-override-release-attestation", "signed_by": "owner-override:repo", "signed_at": "2026-06-11T00:00:00Z", "authorized_status": "controlled_lab_pilot_candidate", "scope": "controlled-lab-only", "statement": "historical"}
    reject("historical missing reason", lambda: check_existing_approval({"git_sha": "0" * 40, "historical": True, "reviewer": "owner-override:repo", "status": "controlled_lab_pilot_candidate", "signed_attestation": historical_att}))
    reject("stress summary not PASS", lambda: check_stress({"status": "SKIP", "release_ready": True}))
    reject("summary contradiction", lambda: check_summary({"status": "PASS", "release_status": "skipped_no_vm"}))
    check_existing_approval({"git_sha": "0" * 40, "historical": True, "historical_reason": "archived approval only", "reviewer": "owner-override:repo", "status": "controlled_lab_pilot_candidate", "signed_attestation": historical_att})
    check_dsq({"status": "PASS", "rollback_success": True, "starvation_breach": False, "repeated_fallback_or_reject_counters": False, "release_eligible": True, "vm_kind": "disposable-vm-marker-present", "bpf_metadata_object_sha256": "abc", "verifier_metadata_object_sha256": "abc"})
    check_live_behavior_gate()
    check_skip_cleanup()
    print("PASS release gate self-test: reviewer policy, stale SHA, rollback, DSQ policy, live behavior proof, skip cleanup, hash manifest, non-PASS stress summaries, and contradictions rejected")


def skip_summary(out: Path, version: str, bundle: str, current_run: bool) -> JsonObject:
    return {"schema": "zig-scheduler/release-gate-summary/v1", "version": version, "status": "SKIP", "release_status": "skipped_no_vm", "reason": "VM-live release evidence missing: " + bundle, "production_ready": False, "arbitrary_host_safe": False, "required_artifacts_present": current_run, "artifact_count": 0, "artifact_hash_manifest": "", "evidence_dir": str(out), "current_run_evidence": current_run, "evidence_retention": "ignored-current-run-not-for-commit" if current_run else "tracked-release-snapshot"}


def write_skip_missing_live(out: Path, version: str, bundle: str) -> None:
    remove_stale_release_claims(out)
    summary = skip_summary(out, version, bundle, True)
    summary["required_artifacts_present"] = False
    tmp = out / "summary.json.tmp"
    write_object(tmp, summary)
    _ = tmp.replace(out / "summary.json")


def write_no_approval_summary(out: Path, version: str, current_run_text: str) -> None:
    current_run = current_run_text == "true"
    remove_stale_release_claims(out)
    summary: JsonObject = {"schema": "zig-scheduler/release-gate-summary/v1", "version": version, "status": "SKIP", "release_status": "non_approval_dry_run", "reason": "non-approval release gate path used by run-all harness recursion guard", "production_ready": False, "arbitrary_host_safe": False, "required_artifacts_present": True, "artifact_count": 0, "artifact_hash_manifest": "", "evidence_dir": str(out), "no_host_gate": "not_required_non_approval_dry_run", "current_run_evidence": current_run, "evidence_retention": "ignored-current-run-not-for-commit" if current_run else "tracked-release-snapshot"}
    tmp = out / "summary.json.tmp"
    write_object(tmp, summary)
    _ = tmp.replace(out / "summary.json")


def summary_status(path: Path) -> str:
    if not path.is_file():
        return "missing"
    value = load_object(path).get("status")
    return value if isinstance(value, str) else "missing"


def run(argv: list[str]) -> int:
    if argv == ["self-test-policy"]:
        run_self_test_policy()
    elif len(argv) == 4 and argv[0] == "mutate-matrix-manifest":
        mutate_matrix_manifest(Path(argv[1]), argv[2], argv[3])
    elif len(argv) == 4 and argv[0] == "write-skip-missing-live":
        write_skip_missing_live(Path(argv[1]), argv[2], argv[3])
    elif len(argv) == 4 and argv[0] == "write-no-approval-summary":
        write_no_approval_summary(Path(argv[1]), argv[2], argv[3])
    elif len(argv) == 2 and argv[0] == "summary-status":
        print(summary_status(Path(argv[1])))
    else:
        raise ReleaseGateSelftestError("usage: release_gate_selftest.py <self-test-policy|mutate-matrix-manifest|write-skip-missing-live|write-no-approval-summary|summary-status> ...")
    return 0


def main() -> int:
    try:
        return run(sys.argv[1:])
    except ReleaseGateSelftestError as exc:
        print(f"FAIL release gate helper: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
