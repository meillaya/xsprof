#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
# ─── How to run ───
# python3 qa/zig_api_usage_check.py --doc docs/zig-0.16-api-usage.md --changed src/control/protocol.zig src/control/daemon.zig src/control/stream.zig
"""Check changed Zig files have targeted local Zig 0.16 stdlib citations."""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass
from pathlib import Path
from tempfile import TemporaryDirectory
from typing import Final

REFERENCE_PREFIX: Final = "docs/vendor/zig-0.16.0/zig-0.16.0-stdlib-reference.txt:"
SOURCE_PREFIX: Final = "docs/vendor/zig-0.16.0/zig-0.16.0-stdlib-sources.txt:"
KNOWN_APIS: Final = ("std.json.parseFromSlice", "std.ArrayList", "std.Io.Writer.Allocating.fromArrayList")


@dataclass(frozen=True, slots=True)
class Args:
    doc: Path
    changed: tuple[Path, ...]
    self_test: bool


class ZigApiUsageError(Exception):
    """Raised when a changed Zig file lacks local Zig 0.16 citations."""


def parse_args(argv: list[str]) -> Args:
    if argv == ["--self-test"]:
        return Args(Path("docs/zig-0.16-api-usage.md"), (), True)
    if len(argv) >= 4 and argv[0] == "--doc" and argv[2] == "--changed":
        return Args(Path(argv[1]), tuple(Path(item) for item in argv[3:]), False)
    raise ZigApiUsageError("usage: zig_api_usage_check.py --doc <ledger.md> --changed <file.zig>... | --self-test")


def cited_lines(text: str) -> set[str]:
    return set(re.findall(r"docs/vendor/zig-0\.16\.0/zig-0\.16\.0-stdlib-(?:reference|sources)\.txt:\d+", text))


def validate_doc(doc: Path, changed: tuple[Path, ...]) -> None:
    text = doc.read_text()
    citations = cited_lines(text)
    if not any(item.startswith(REFERENCE_PREFIX) for item in citations):
        raise ZigApiUsageError("ledger missing stdlib reference citation")
    if not any(item.startswith(SOURCE_PREFIX) for item in citations):
        raise ZigApiUsageError("ledger missing stdlib source citation")
    for api in KNOWN_APIS:
        if api not in text:
            raise ZigApiUsageError(f"ledger missing API: {api}")
    for path in changed:
        path_text = path.as_posix()
        if path_text not in text:
            raise ZigApiUsageError(f"changed Zig file missing from ledger: {path_text}")
        if not re.search(rf"`{re.escape(path_text)}`[^\n]*\|[^\n]*{re.escape(REFERENCE_PREFIX)}\d+", text):
            raise ZigApiUsageError(f"changed Zig file lacks reference citation: {path_text}")


def run_self_test() -> None:
    with TemporaryDirectory(prefix="zigsched-zig-api-") as tmp:
        doc = Path(tmp) / "ledger.md"
        doc.write_text(
            "| `src/control/protocol.zig` | `std.ArrayList` | "
            "`docs/vendor/zig-0.16.0/zig-0.16.0-stdlib-reference.txt:84706` | ok |\n"
            "docs/vendor/zig-0.16.0/zig-0.16.0-stdlib-sources.txt:260047\n"
            "std.json.parseFromSlice\nstd.Io.Writer.Allocating.fromArrayList\n"
        )
        validate_doc(doc, (Path("src/control/protocol.zig"),))
        doc.write_text("std.ArrayList without local citation")
        try:
            validate_doc(doc, (Path("src/control/protocol.zig"),))
        except ZigApiUsageError as exc:
            print(f"PASS self-test rejected missing citation: {exc}")
            return
    raise ZigApiUsageError("self-test failed to reject missing citation")


def run(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.self_test:
        run_self_test()
    else:
        validate_doc(args.doc, args.changed)
        print(f"PASS Zig API usage ledger: doc={args.doc} changed={len(args.changed)}")
    return 0


def main() -> int:
    try:
        return run(sys.argv[1:])
    except (OSError, UnicodeError, ZigApiUsageError) as exc:
        print(f"FAIL Zig API usage ledger: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
