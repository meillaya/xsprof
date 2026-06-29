#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
# ─── How to run ───
# 1. Install uv (if not installed):
#      curl -LsSf https://astral.sh/uv/install.sh | sh
# 2. Run directly:
#      uv run qa/runtime_sample_check.py --input evidence/lab/observe-partial/runtime-samples.jsonl
# 3. Or with system Python (no dependencies):
#      python3 qa/runtime_sample_check.py --self-test
# ──────────────────
from __future__ import annotations

from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from qa.runtime_sample_core import JsonObject, JsonValue, RuntimeSampleError, good_sample, validate_alert_order, validate_file

__all__ = ("JsonObject", "JsonValue", "RuntimeSampleError", "good_sample", "validate_alert_order", "validate_file")


def parse_args(argv: list[str]) -> tuple[Path | None, bool]:
    if argv == ["--self-test"]:
        return None, True
    if len(argv) == 2 and argv[0] == "--input":
        return Path(argv[1]), False
    raise RuntimeSampleError("usage: runtime_sample_check.py --input <runtime-samples.jsonl> | --self-test")


def self_test() -> None:
    from qa.runtime_sample_selftest import self_test as runtime_sample_self_test

    runtime_sample_self_test()


def run(argv: list[str]) -> int:
    input_path, should_self_test = parse_args(argv)
    if should_self_test:
        self_test()
        return 0
    if input_path is None:
        raise RuntimeSampleError("internal argument parser error")
    validate_file(input_path)
    print(f"PASS runtime sample schema: {input_path}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(run(sys.argv[1:]))
    except RuntimeSampleError as exc:
        print(f"FAIL runtime sample schema: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
