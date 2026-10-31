#!/usr/bin/env python3
"""Generate the grep-friendly Zig 0.17 reference text corpus.

This is developer tooling for refreshing docs/vendor/zig-0.17.0; it is not
required to build or run xsprof. Inputs are the official source tree and the
official language-reference HTML downloaded by tools/vendor_stdlib.sh.
"""

from __future__ import annotations

import argparse
import html
import re
from html.parser import HTMLParser
from pathlib import Path


def gen_sources(std: Path, out: Path) -> None:
    files = sorted(p for p in std.rglob("*.zig") if p.is_file())
    with out.open("w", encoding="utf-8") as f:
        f.write("// Zig 0.17.0 standard library sources (lib/std)\n")
        f.write("// Generated from https://ziglang.org/download/0.17.0/zig-0.17.0.tar.xz\n")
        f.write("// Boundary headers are comments; each section is one upstream file verbatim.\n\n")
        for path in files:
            rel = path.relative_to(std).as_posix()
            f.write(f"// ===== lib/std/{rel} =====\n")
            try:
                text = path.read_text(encoding="utf-8")
            except UnicodeDecodeError:
                text = path.read_text(encoding="utf-8", errors="replace")
            f.write(text)
            if not text.endswith("\n"):
                f.write("\n")
            f.write("\n")


def gen_reference(std: Path, out: Path) -> None:
    files = sorted(p for p in std.rglob("*.zig") if p.is_file())
    with out.open("w", encoding="utf-8") as f:
        f.write("Zig 0.17.0 standard library public API reference (source-derived)\n")
        f.write("Source: zig-0.17.0.tar.xz; line references are within each upstream file.\n")
        f.write("Entries are public declarations with adjacent /// or //! documentation.\n\n")
        for path in files:
            rel = path.relative_to(std).as_posix()
            try:
                lines = path.read_text(encoding="utf-8").splitlines()
            except UnicodeDecodeError:
                continue
            entries: list[tuple[int, list[str], str]] = []
            pending_doc: list[str] = []
            for lineno, line in enumerate(lines, 1):
                stripped = line.strip()
                if stripped.startswith("///") or stripped.startswith("//!"):
                    pending_doc.append(stripped)
                    continue
                if stripped.startswith("pub "):
                    entries.append((lineno, list(pending_doc), stripped))
                    pending_doc.clear()
                    continue
                if stripped == "":
                    continue
                pending_doc.clear()
            if not entries:
                continue
            f.write(f"// ===== lib/std/{rel} =====\n")
            for lineno, doc, decl in entries:
                f.write(f"// line {lineno}\n")
                for line in doc:
                    f.write(line + "\n")
                f.write(decl + "\n\n")


class TextExtractor(HTMLParser):
    BLOCK = {"h1", "h2", "h3", "h4", "p", "li", "pre", "tr", "br", "div", "section"}

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.parts: list[str] = []
        self.skip = 0

    def handle_starttag(self, tag: str, attrs) -> None:
        if tag in ("script", "style", "svg"):
            self.skip += 1
        if tag in self.BLOCK:
            self.parts.append("\n")

    def handle_endtag(self, tag: str) -> None:
        if tag in ("script", "style", "svg") and self.skip:
            self.skip -= 1
        if tag in self.BLOCK:
            self.parts.append("\n")

    def handle_data(self, data: str) -> None:
        if not self.skip:
            self.parts.append(data)


def gen_langref(html_path: Path, out: Path) -> None:
    parser = TextExtractor()
    parser.feed(html_path.read_text(encoding="utf-8", errors="replace"))
    text = "".join(parser.parts)
    text = "\n".join(line.strip() for line in text.splitlines())
    text = re.sub(r"\n{3,}", "\n\n", text).strip()
    out.write_text(
        "Zig 0.17.0 Language Reference (text extraction of the official HTML)\n"
        "Source: https://ziglang.org/documentation/0.17.0/\n\n" + text + "\n",
        encoding="utf-8",
    )


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--std", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--langref", type=Path)
    args = ap.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    gen_sources(args.std, args.out / "zig-0.17.0-stdlib-sources.txt")
    gen_reference(args.std, args.out / "zig-0.17.0-stdlib-reference.txt")
    if args.langref and args.langref.is_file():
        gen_langref(args.langref, args.out / "zig-0.17.0-langref.txt")


if __name__ == "__main__":
    main()
