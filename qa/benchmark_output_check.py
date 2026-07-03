#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
# ─── How to run ───
# python3 qa/benchmark_output_check.py --self-test
# python3 qa/benchmark_output_check.py --fixtures fixtures/benchmark-output --schema schemas/control/benchmark-output.v1.schema.json
# python3 qa/benchmark_output_check.py --parse --tool fio --input fixtures/benchmark-output/raw/fio.json --output-path evidence/lab/run/bench/fio.json --vm-evidence evidence/lab/run/summary.json --out /tmp/fio.benchmark-output.json
"""Validate and normalize record-only VM benchmark output evidence."""
from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import assert_never

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from qa.benchmark_output_io import write_json
from qa.benchmark_output_model import Args, BenchmarkOutputError, family
from qa.benchmark_output_parse import build_record
from qa.benchmark_output_selftest import self_test
from qa.benchmark_output_validate import run_fixtures, validate_record


def parse_args(argv: list[str]) -> Args:
    if argv == ["--self-test"]:
        return Args("self-test")
    if len(argv) == 4 and argv[0] == "--fixtures" and argv[2] == "--schema":
        return Args("fixtures", fixtures=Path(argv[1]), schema=Path(argv[3]))
    if len(argv) == 11 and argv[0] == "--parse" and argv[1] == "--tool" and argv[3] == "--input" and argv[5] == "--output-path" and argv[7] == "--vm-evidence" and argv[9] == "--out":
        return Args("parse", tool=family(argv[2]), input_path=Path(argv[4]), output_path=argv[6], vm_evidence=argv[8], out=Path(argv[10]))
    raise BenchmarkOutputError("usage: benchmark_output_check.py --self-test | --fixtures <dir> --schema <schema.json> | --parse --tool <family> --input <raw> --output-path <relative> --vm-evidence <relative> --out <json>")


def run(argv: list[str]) -> int:
    args = parse_args(argv)
    match args.mode:
        case "self-test":
            self_test()
        case "fixtures":
            if args.fixtures is None or args.schema is None:
                raise BenchmarkOutputError("fixtures/schema required")
            run_fixtures(args.fixtures, args.schema)
        case "parse":
            if args.tool is None or args.input_path is None or args.output_path is None or args.vm_evidence is None or args.out is None:
                raise BenchmarkOutputError("parse arguments required")
            record = build_record(args.tool, args.input_path, args.output_path, args.vm_evidence)
            validate_record(record)
            write_json(args.out, record)
            print(f"PASS benchmark output parsed: {args.out}")
        case unreachable:
            assert_never(unreachable)
    return 0


def main() -> int:
    try:
        return run(sys.argv[1:])
    except (OSError, UnicodeError, json.JSONDecodeError, BenchmarkOutputError) as exc:
        print(f"FAIL benchmark output: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
