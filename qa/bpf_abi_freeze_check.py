#!/usr/bin/env python3
"""Check the frozen sched_ext BPF ABI contract and metadata evidence."""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from qa.bpf_abi_model import ABI_VERSION, EVENTS_COUNT, STATS_COUNT, Args, BpfAbiError
from qa.bpf_abi_selftest import run_self_test
from qa.bpf_abi_validate import validate


def parse_args(argv: list[str]) -> Args:
    if argv == ["--self-test"]:
        return Args(Path("bpf/include/zigsched_common.h"), Path("docs/adr/0004-bpf-abi-strategy.md"), Path("zig-out/bpf/zigsched_minimal.bpf.meta.json"), Path("zig-out/bpf/zigsched_minimal.bpf.skip.json"), True)
    if len(argv) in (6, 8) and argv[:1] == ["--header"] and argv[2] == "--strategy" and argv[4] == "--metadata":
        skip_path = Path(argv[7]) if len(argv) == 8 and argv[6] == "--skip-json" else None
        if len(argv) == 8 and argv[6] != "--skip-json":
            raise BpfAbiError("expected --skip-json before skip path")
        return Args(Path(argv[1]), Path(argv[3]), Path(argv[5]), skip_path, False)
    raise BpfAbiError("usage: bpf_abi_freeze_check.py --header <h> --strategy <adr> --metadata <meta.json> [--skip-json <skip.json>] | --self-test")


def run(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.self_test:
        run_self_test(args)
    else:
        mode = validate(args.header, args.strategy, args.metadata, args.skip_json)
        print(f"PASS BPF ABI freeze check: mode={mode} abi=v{ABI_VERSION} stats={STATS_COUNT} events={EVENTS_COUNT} header={args.header} strategy={args.strategy}")
    return 0


def main() -> int:
    try:
        return run(sys.argv[1:])
    except (OSError, UnicodeError, BpfAbiError) as exc:
        print(f"FAIL BPF ABI freeze check: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
