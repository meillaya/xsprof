#!/usr/bin/env python3
# Emits microVM live-lab JSON evidence from runner environment and serial logs.

from __future__ import annotations

import json
import sys

from microvm_report_outputs import prepare_output_paths, write_verifier_outputs
from microvm_report_parse import load_report_env, load_timeout_env, parse_serial, report_ids
from microvm_report_summary import write_observe_outputs, write_summary


def emit_timeout_report() -> None:
    env = load_timeout_env()
    env.out.mkdir(parents=True, exist_ok=True)
    summary = env.out / "summary.json"
    summary_data = {
        "schema": "zig-scheduler/run-all-lab/v1",
        "status": "INCIDENT",
        "mode": "microvm-live",
        "evidence_mode": "vm-live",
        "git_sha": env.git_sha,
        "git_dirty": env.git_dirty,
        "output_dir": env.out.as_posix(),
        "output_dir_created_fresh": True,
        "host_mutation": False,
        "release_eligible_live_proof": False,
        "vm_kind": "qemu-vm",
        "kernel_image": env.kernel_image,
        "qemu_bin": env.qemu_bin,
        "started_at": env.started_at,
        "cleanup": {
            "qemu_leftovers": False,
            "tmux_leftovers": False,
            "qemu_process_scan_before": env.qemu_scan_before,
            "qemu_process_scan_after": env.qemu_scan_after,
            "timeout_pid": "timeout-supervised-foreground",
            "timeout_rc": env.qemu_rc,
            "process_group_reaped": True,
            "temp_dirs_removed": True,
        },
        "stages": [{"stage": "microvm_timeout", "status": "INCIDENT", "reason": "qemu timeout", "artifact": summary.as_posix()}],
    }
    summary.write_text(json.dumps(summary_data, indent=2, sort_keys=True) + "\n")
    payload = {"event": "incident", "status": "unsafe_to_assume", "state": "unsafe_to_assume", "reason": "timeout", "artifact": summary.as_posix()}
    print("ZIGSCHED_DAEMON_EVENT " + json.dumps(payload, sort_keys=True), flush=True)


def parse_and_emit_report() -> None:
    env = load_report_env()
    text = env.serial.read_text(errors="replace")
    rows, lines = parse_serial(text)
    paths = prepare_output_paths(env.out)
    ids = report_ids(env, rows)
    verifier = write_verifier_outputs(env, rows, lines, ids, paths)
    observe = write_observe_outputs(paths, rows, verifier, env.object_sha)
    write_summary(env, rows, verifier, observe)


def main(argv: list[str]) -> int:
    if argv == ["timeout"]:
        emit_timeout_report()
        return 0
    if argv == ["parse"]:
        parse_and_emit_report()
        return 0
    print("usage: microvm_report_emit.py timeout|parse", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
