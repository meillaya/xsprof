#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
# ─── How to run ───
# python3 tools/tui_live_vm_cleanup.py --scan
"""Owned-process and scratch cleanup helpers for the live VM TUI PTY harness."""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from typing import Final

ARTIFACT_FIELD_PREFIX: Final[str] = '"artifact":"'
OWNER_MARKER_NAME: Final[str] = "zig-scheduler-owner-out-dir"
LAB_ARTIFACT_PREFIX: Final[str] = "evidence/lab/run-all/"


def cleanup_launched_live_processes(state_dir: str) -> None:
    terminate_matching_processes("zig-scheduler-daemon", state_dir)
    cleanup_live_artifacts_without_daemon_kill(state_dir)


def cleanup_live_artifacts_without_daemon_kill(state_dir: str) -> None:
    owned_scratch_dirs = owned_microvm_scratch_dirs(state_dir)
    terminate_owned_microvm_processes(owned_scratch_dirs)
    remove_owned_scratch_dirs(owned_scratch_dirs)


def owned_microvm_scratch_dirs(state_dir: str) -> list[Path]:
    return owned_microvm_scratch_dirs_for_out_dirs(journal_artifact_dirs(state_dir))


def journal_artifact_dirs(state_dir: str) -> set[str]:
    journal = Path(state_dir) / "events.jsonl"
    try:
        lines = journal.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return set()
    artifacts: set[str] = set()
    for line in lines:
        artifact = artifact_from_event_line(line)
        if artifact is None:
            continue
        artifacts.add(artifact)
    return artifacts


def artifact_from_event_line(line: str) -> str | None:
    start = line.find(ARTIFACT_FIELD_PREFIX)
    if start < 0:
        return None
    value_start = start + len(ARTIFACT_FIELD_PREFIX)
    value_end = line.find('"', value_start)
    if value_end < 0:
        return None
    artifact = line[value_start:value_end]
    if not artifact.startswith(LAB_ARTIFACT_PREFIX):
        return None
    if artifact.endswith("/summary.json"):
        return artifact[: -len("/summary.json")]
    return artifact


def terminate_owned_microvm_processes(scratch_dirs: list[Path]) -> None:
    if not scratch_dirs:
        return
    completed = subprocess.run(  # noqa: S603
        ["ps", "-eo", "pid=,comm=,args="],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    pids = owned_microvm_process_ids(completed.stdout, scratch_dirs)
    terminate_process_ids(pids)


def owned_microvm_process_ids(raw_processes: bytes, scratch_dirs: list[Path]) -> list[int]:
    pids: list[int] = []
    scratch_tokens = [str(path) for path in scratch_dirs]
    for line in raw_processes.decode("utf-8", errors="replace").splitlines():
        parts = line.strip().split(maxsplit=2)
        if len(parts) != 3 or not parts[0].isdigit():
            continue
        pid, command, args = int(parts[0]), parts[1], parts[2]
        if ("qemu-system-" in command or "qemu-system-" in args) and any(token in args for token in scratch_tokens):
            pids.append(pid)
    return pids


def remove_owned_scratch_dirs(scratch_dirs: list[Path]) -> None:
    for path in scratch_dirs:
        marker = path / OWNER_MARKER_NAME
        if not marker.exists():
            continue
        shutil.rmtree(path, ignore_errors=True)


def cleanup_owned_microvm_tmpdirs_for_out_dir(out_dir: str) -> list[Path]:
    owned_scratch_dirs = owned_microvm_scratch_dirs_for_out_dirs({out_dir})
    terminate_owned_microvm_processes(owned_scratch_dirs)
    remove_owned_scratch_dirs(owned_scratch_dirs)
    return owned_scratch_dirs


def cleanup_owned_lab_microvm_tmpdirs() -> list[Path]:
    owned_scratch_dirs = owned_lab_microvm_scratch_dirs()
    terminate_owned_microvm_processes(owned_scratch_dirs)
    remove_owned_scratch_dirs(owned_scratch_dirs)
    return owned_scratch_dirs


def owned_lab_microvm_scratch_dirs() -> list[Path]:
    roots: list[Path] = []
    tmp_root = Path(os.environ.get("TMPDIR", "/tmp"))
    for candidate in tmp_root.glob("zigsched-microvm-live.*"):
        marker_value = scratch_owner_out_dir(candidate)
        if marker_value is not None and is_lab_artifact_dir(marker_value):
            roots.append(candidate)
    return roots


def owned_microvm_scratch_dirs_for_out_dirs(owned_out_dirs: set[str]) -> list[Path]:
    if not owned_out_dirs:
        return []
    roots: list[Path] = []
    tmp_root = Path(os.environ.get("TMPDIR", "/tmp"))
    for candidate in tmp_root.glob("zigsched-microvm-live.*"):
        marker_value = scratch_owner_out_dir(candidate)
        if marker_value in owned_out_dirs:
            roots.append(candidate)
    return roots


def scratch_owner_out_dir(candidate: Path) -> str | None:
    marker = candidate / OWNER_MARKER_NAME
    try:
        marker_value = marker.read_text(encoding="utf-8").strip()
    except (FileNotFoundError, OSError, UnicodeDecodeError):
        return None
    if not is_lab_artifact_dir(marker_value):
        return None
    return marker_value


def is_lab_artifact_dir(value: str) -> bool:
    if not value.startswith(LAB_ARTIFACT_PREFIX):
        return False
    if value.endswith("/summary.json"):
        return False
    if value.startswith("/") or ".." in Path(value).parts:
        return False
    if "\n" in value or "\r" in value or not value.removeprefix(LAB_ARTIFACT_PREFIX):
        return False
    return True


def wait_for_event_journal(state_dir: str) -> None:
    journal = Path(state_dir) / "events.jsonl"
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline:
        if journal.exists():
            return
        time.sleep(0.1)


def terminate_matching_processes(command_token: str, args_token: str) -> None:
    completed = subprocess.run(  # noqa: S603
        ["ps", "-eo", "pid=,comm=,args="],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    pids = matching_process_ids(completed.stdout, command_token, args_token)
    terminate_process_ids(pids)


def terminate_process_ids(pids: list[int]) -> None:
    if not pids:
        return
    for sig in (signal.SIGTERM, signal.SIGKILL):
        for pid in pids:
            if pid == os.getpid():
                continue
            try:
                os.kill(pid, sig)
            except ProcessLookupError:
                pass
        time.sleep(0.2)


def matching_process_ids(raw_processes: bytes, command_token: str, args_token: str) -> list[int]:
    pids: list[int] = []
    for line in raw_processes.decode("utf-8", errors="replace").splitlines():
        parts = line.strip().split(maxsplit=2)
        if len(parts) != 3 or not parts[0].isdigit():
            continue
        pid, command, args = int(parts[0]), parts[1], parts[2]
        if command_token in command and args_token in args:
            pids.append(pid)
    return pids


def print_cleanup_scan() -> None:
    tmp_root = Path(os.environ.get("TMPDIR", "/tmp"))
    for candidate in sorted(tmp_root.glob("zigsched-microvm-live.*")):
        marker_value = scratch_owner_out_dir(candidate)
        if marker_value is None:
            print(f"IGNORED unmarked {candidate}")
        else:
            print(f"OWNED {candidate} marker={marker_value}")


def main(argv: list[str]) -> int:
    if argv == ["--self-test"]:
        return run_self_test()
    if argv == ["--scan"]:
        print_cleanup_scan()
        return 0
    if argv == ["--cleanup-owned-lab-tmpdirs"]:
        removed = cleanup_owned_lab_microvm_tmpdirs()
        for path in removed:
            print(f"REMOVED owned {path}")
        print_cleanup_scan()
        return 0
    if len(argv) == 2 and argv[0] == "--cleanup-owned-out-dir":
        out_dir = argv[1]
        if not is_lab_artifact_dir(out_dir):
            print(f"FAIL: refused non-lab owner out-dir: {out_dir}")
            return 1
        removed = cleanup_owned_microvm_tmpdirs_for_out_dir(out_dir)
        for path in removed:
            print(f"REMOVED owned {path} marker={out_dir}")
        print_cleanup_scan()
        return 0
    print("usage: tui_live_vm_cleanup.py --self-test | --scan | --cleanup-owned-lab-tmpdirs | --cleanup-owned-out-dir <evidence/lab/run-all/name>")
    return 1


def run_self_test() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        state = tmp_path / "state"
        state.mkdir()
        events_jsonl = "\n".join((
            '{"artifact":"evidence/lab/run-all/owned"}',
            '{"artifact":"evidence/lab/run-all/owned/summary.json"}',
        ))
        _ = (state / "events.jsonl").write_text(f"{events_jsonl}\n", encoding="utf-8")
        scratch = tmp_path / "zigsched-microvm-live.owned"
        scratch.mkdir()
        _ = (scratch / OWNER_MARKER_NAME).write_text("evidence/lab/run-all/owned\n", encoding="utf-8")
        other = tmp_path / "zigsched-microvm-live.other"
        other.mkdir()
        _ = (other / OWNER_MARKER_NAME).write_text("evidence/lab/run-all/other\n", encoding="utf-8")
        unmarked = tmp_path / "zigsched-microvm-live.unmarked"
        unmarked.mkdir()
        old_tmpdir = os.environ.get("TMPDIR")
        os.environ["TMPDIR"] = str(tmp_path)
        try:
            assert owned_microvm_scratch_dirs(str(state)) == [scratch]
            assert cleanup_owned_microvm_tmpdirs_for_out_dir("evidence/lab/run-all/owned") == [scratch]
            assert not scratch.exists()
            assert other.exists()
            assert unmarked.exists()
        finally:
            if old_tmpdir is None:
                _ = os.environ.pop("TMPDIR", None)
            else:
                os.environ["TMPDIR"] = old_tmpdir
    raw = (
        b"101 qemu-system-x86_64 qemu-system-x86_64 -name zig-scheduler-microvm-live-lab\n"
        b"102 qemu-system-x86_64 qemu-system-x86_64 -initrd /tmp/zigsched-microvm-live.owned/initramfs.cpio.gz\n"
        b"103 .qemu-system-x8 /nix/store/qemu/bin/qemu-system-x86_64 -initrd /tmp/zigsched-microvm-live.owned/initramfs.cpio.gz\n"
    )
    assert owned_microvm_process_ids(raw, [Path("/tmp/zigsched-microvm-live.owned")]) == [102, 103]
    print("PASS: PTY cleanup self-test scopes qemu cleanup to owned scratch dirs")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
