#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///

# ─── How to run ───
# 1. Install uv (optional):
#      curl -LsSf https://astral.sh/uv/install.sh | sh
# 2. Run the RED self-test:
#      python3 qa/live_bundle_freshness_check.py --self-test
# 3. Future implementation mode:
#      python3 qa/live_bundle_freshness_check.py --bundle evidence/lab/run-all/<vm-live>/summary.json
# ──────────────────
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import hashlib
import json
import shutil
import subprocess
import sys
from typing import Final, TypeAlias

JsonValue: TypeAlias = None | bool | int | float | str | list["JsonValue"] | dict[str, "JsonValue"]
JsonObject: TypeAlias = dict[str, JsonValue]

SELF_ROOT: Final[Path] = Path("evidence/lab/run-all/live-bundle-freshness-self-test")
CURRENT_GIT_SHA: Final[str] = "f" * 40
CURRENT_BPF_SHA: Final[str] = "a" * 64


@dataclass(frozen=True, slots=True)
class Args:
    bundle: Path | None
    self_test: bool


@dataclass(frozen=True, slots=True)
class FreshnessCase:
    label: str
    path: Path
    should_pass: bool


class FreshnessCheckError(Exception):
    pass


def parse_args(argv: list[str]) -> Args:
    if argv == ["--self-test"]:
        return Args(bundle=None, self_test=True)
    if len(argv) == 2 and argv[0] == "--bundle":
        return Args(bundle=Path(argv[1]), self_test=False)
    raise FreshnessCheckError("usage: live_bundle_freshness_check.py --self-test | --bundle <summary.json>")


def load_object(path: Path) -> JsonObject:
    try:
        raw: JsonValue = json.loads(path.read_text())
    except FileNotFoundError as exc:
        raise FreshnessCheckError(f"missing JSON file: {path}") from exc
    except json.JSONDecodeError as exc:
        raise FreshnessCheckError(f"invalid JSON file: {path}: {exc}") from exc
    if not isinstance(raw, dict):
        raise FreshnessCheckError(f"JSON root must be object: {path}")
    return raw


def validate_fresh_bundle(path: Path, *, current_git_sha: str, current_bpf_sha: str) -> None:
    summary = load_object(path)
    require_equal(require_text(summary, "schema"), "zig-scheduler/run-all-lab/v1", "schema")
    require_equal(require_text(summary, "status"), "PASS", "status")
    require_equal(require_text(summary, "evidence_mode"), "vm-live", "evidence_mode")
    require_equal(require_text(summary, "git_sha"), current_git_sha, "git_sha")
    require_equal(require_text(summary, "bpf_object_sha256"), current_bpf_sha, "bpf_object_sha256")
    if require_bool(summary, "git_dirty"):
        raise FreshnessCheckError("bundle was generated from a dirty worktree")
    if require_bool(summary, "host_mutation"):
        raise FreshnessCheckError("host_mutation must be false")
    if not require_bool(summary, "output_dir_created_fresh"):
        raise FreshnessCheckError("output directory was reused")
    output_dir = Path(require_text(summary, "output_dir"))
    if output_dir != path.parent:
        raise FreshnessCheckError("output_dir must match summary parent")
    validate_cleanup(require_object(summary, "cleanup"), path.parent)


def self_test() -> None:
    shutil.rmtree(SELF_ROOT, ignore_errors=True)
    try:
        cases = (
            FreshnessCase("fresh-clean-bundle", write_bundle(SELF_ROOT / "fresh-clean"), True),
            FreshnessCase("stale-git-sha", write_bundle(SELF_ROOT / "stale-git", git_sha="0" * 40), False),
            FreshnessCase("mismatched-bpf-sha", write_bundle(SELF_ROOT / "bad-bpf", bpf_sha="b" * 64), False),
            FreshnessCase("missing-cleanup-receipt", write_bundle(SELF_ROOT / "missing-cleanup", cleanup=False), False),
            FreshnessCase("reused-output-directory", write_bundle(SELF_ROOT / "reused-output", reused=True), False),
            FreshnessCase("dirty-worktree", write_bundle(SELF_ROOT / "dirty-worktree", git_dirty=True), False),
            FreshnessCase("failed-status", write_bundle(SELF_ROOT / "failed-status", status="FAIL"), False),
            FreshnessCase("list-only-process-scans", write_bundle(SELF_ROOT / "list-scan", list_scan=True), False),
        )
        for case in cases:
            run_case(case)
    finally:
        shutil.rmtree(SELF_ROOT, ignore_errors=True)
    print("PASS live bundle freshness self-test")


def run_case(case: FreshnessCase) -> None:
    if case.should_pass:
        validate_fresh_bundle(case.path, current_git_sha=CURRENT_GIT_SHA, current_bpf_sha=CURRENT_BPF_SHA)
        print(f"PASS accept {case.label}")
        return
    try:
        validate_fresh_bundle(case.path, current_git_sha=CURRENT_GIT_SHA, current_bpf_sha=CURRENT_BPF_SHA)
    except FreshnessCheckError as exc:
        print(f"PASS reject {case.label}: {exc}")
        return
    raise FreshnessCheckError(f"expected rejection did not occur: {case.label}")


def write_bundle(
    root: Path,
    *,
    git_sha: str = CURRENT_GIT_SHA,
    bpf_sha: str = CURRENT_BPF_SHA,
    cleanup: bool = True,
    reused: bool = False,
    git_dirty: bool = False,
    status: str = "PASS",
    list_scan: bool = False,
) -> Path:
    root.mkdir(parents=True)
    summary = root / "summary.json"
    if cleanup:
        (root / "qemu-process-scan-before.txt").write_text("")
        (root / "qemu-process-scan-after.txt").write_text("")
    summary.write_text(json.dumps(bundle_summary(root, git_sha, bpf_sha, cleanup, reused, git_dirty, status, list_scan), indent=2, sort_keys=True) + "\n")
    return summary


def bundle_summary(root: Path, git_sha: str, bpf_sha: str, cleanup: bool, reused: bool, git_dirty: bool, status: str, list_scan: bool) -> JsonObject:
    return {
        "schema": "zig-scheduler/run-all-lab/v1",
        "status": status,
        "evidence_mode": "vm-live",
        "git_dirty": git_dirty,
        "git_sha": git_sha,
        "bpf_object_sha256": bpf_sha,
        "output_dir": root.as_posix(),
        "output_dir_created_fresh": not reused,
        "cleanup": cleanup_receipt(root, cleanup, list_scan),
        "host_mutation": False,
    }


def cleanup_receipt(root: Path, cleanup: bool, list_scan: bool) -> JsonObject:
    if cleanup:
        return {
            "qemu_process_scan_before": [] if list_scan else (root / "qemu-process-scan-before.txt").as_posix(),
            "qemu_process_scan_after": [] if list_scan else (root / "qemu-process-scan-after.txt").as_posix(),
            "tmux_sessions_after": [],
            "timeout_pid": "timeout-supervised-foreground",
            "timeout_rc": 0,
            "process_group_reaped": True,
            "temp_dirs_removed": True,
        }
    return {}


def require_text(data: JsonObject, field: str) -> str:
    value = data.get(field)
    if not isinstance(value, str) or value == "":
        raise FreshnessCheckError(f"missing text field: {field}")
    return value


def require_bool(data: JsonObject, field: str) -> bool:
    value = data.get(field)
    if not isinstance(value, bool):
        raise FreshnessCheckError(f"missing bool field: {field}")
    return value


def require_object(data: JsonObject, field: str) -> JsonObject:
    value = data.get(field)
    if not isinstance(value, dict):
        raise FreshnessCheckError(f"missing object field: {field}")
    return value


def require_equal(found: str, expected: str, field: str) -> None:
    if found != expected:
        raise FreshnessCheckError(f"{field} mismatch")


def validate_cleanup(cleanup: JsonObject, bundle_root: Path) -> None:
    if cleanup.get("temp_dirs_removed") is not True:
        raise FreshnessCheckError("cleanup missing temp dir removal receipt")
    if cleanup.get("process_group_reaped") is not True:
        raise FreshnessCheckError("cleanup missing process group receipt")
    if not isinstance(cleanup.get("timeout_pid"), str) or cleanup.get("timeout_pid") == "":
        raise FreshnessCheckError("cleanup missing timeout pid receipt")
    if not isinstance(cleanup.get("timeout_rc"), int):
        raise FreshnessCheckError("cleanup missing timeout rc receipt")
    validate_qemu_scan(cleanup.get("qemu_process_scan_before"), bundle_root, "qemu_process_scan_before")
    validate_qemu_scan(cleanup.get("qemu_process_scan_after"), bundle_root, "qemu_process_scan_after")
    tmux = cleanup.get("tmux_sessions_after")
    if not isinstance(tmux, list):
        raise FreshnessCheckError("cleanup missing tmux session scan")


def validate_qemu_scan(value: JsonValue, bundle_root: Path, field: str) -> None:
    if not isinstance(value, str) or value == "":
        raise FreshnessCheckError(f"cleanup missing process scan: {field}")
    path = Path(value)
    if path.is_absolute() or ".." in path.parts or not path.exists():
        raise FreshnessCheckError(f"cleanup process scan path is unsafe or missing: {field}")
    if bundle_root not in (path, *path.parents):
        raise FreshnessCheckError(f"cleanup process scan must be inside bundle: {field}")
    if "zig-scheduler-microvm-live-lab" in path.read_text(errors="replace"):
        raise FreshnessCheckError(f"cleanup process scan still contains lab qemu process: {field}")


def current_git_sha() -> str:
    try:
        result = subprocess.run(("git", "rev-parse", "HEAD"), check=True, capture_output=True, text=True)
    except (FileNotFoundError, subprocess.CalledProcessError) as exc:
        raise FreshnessCheckError("could not read current git SHA") from exc
    return result.stdout.strip()


def current_git_dirty() -> bool:
    try:
        result = subprocess.run(("git", "status", "--porcelain"), check=True, capture_output=True, text=True)
    except (FileNotFoundError, subprocess.CalledProcessError) as exc:
        raise FreshnessCheckError("could not read current git state") from exc
    return result.stdout.strip() != ""


def current_bpf_sha(path: Path = Path("zig-out/bpf/zigsched_minimal.bpf.o")) -> str:
    try:
        return hashlib.sha256(path.read_bytes()).hexdigest()
    except FileNotFoundError as exc:
        raise FreshnessCheckError(f"missing current BPF object: {path}") from exc


def run(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.self_test:
        self_test()
        return 0
    if args.bundle is None:
        raise FreshnessCheckError("internal argument parser error")
    if current_git_dirty():
        raise FreshnessCheckError("current worktree is dirty; commit or stash before validating live bundle freshness")
    validate_fresh_bundle(args.bundle, current_git_sha=current_git_sha(), current_bpf_sha=current_bpf_sha())
    print(f"PASS live bundle freshness: {args.bundle}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(run(sys.argv[1:]))
    except (FreshnessCheckError, OSError) as exc:
        print(f"FAIL live bundle freshness: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
