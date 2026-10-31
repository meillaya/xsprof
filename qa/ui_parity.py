#!/usr/bin/env python3
"""Compare reference and program screenshots with ffmpeg raw decoding.

This is a developer evidence gate, not part of `zig build check`. It reports
mean channel error and the percentage of pixels over a channel delta of 24.
Font antialiasing differs between Chromium's DOM text and xsui's staged glyph
rasterizer; geometry/colors are asserted by the design token tests instead.
"""
from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path

SCREENS = ["overview", "timeline", "advisor", "events", "capture"]
THEMES = ["dark", "paper", "latte", "frappe", "macchiato", "mocha"]


def raw_rgb(path: Path) -> bytes:
    result = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", str(path), "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
        check=True, capture_output=True,
    )
    return result.stdout


def compare(reference: Path, program: Path, diff_out: Path) -> dict:
    a = raw_rgb(reference)
    b = raw_rgb(program)
    if len(a) != len(b):
        raise SystemExit(f"size mismatch: {reference} {len(a)} vs {program} {len(b)}")
    pixels = len(a) // 3
    total = 0
    over16 = over24 = 0
    diff = bytearray(len(a))
    for i in range(pixels):
        d = 0
        base = i * 3
        for channel in range(3):
            delta = abs(a[base + channel] - b[base + channel])
            d = max(d, delta)
        total += d
        if d > 16:
            over16 += 1
        if d > 24:
            over24 += 1
        v = min(255, d * 8)
        diff[base] = v
        diff[base + 1] = v // 3
        diff[base + 2] = 0
    diff_out.parent.mkdir(parents=True, exist_ok=True)
    width, height = (1440, 900)
    subprocess.run(
        ["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24",
         "-s", f"{width}x{height}", "-i", "-", str(diff_out)],
        input=bytes(diff), check=True,
    )
    return {
        "pixels": pixels,
        "mean_abs_channel_error": round(total / pixels, 4),
        "over16_pct": round(over16 * 100.0 / pixels, 3),
        "over24_pct": round(over24 * 100.0 / pixels, 3),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--reference", default="design/screenshots/prototype")
    parser.add_argument("--program", default="design/screenshots/xsprof")
    parser.add_argument("--diff", default="design/screenshots/diff")
    parser.add_argument("--out", default="design/evidence/parity.json")
    args = parser.parse_args()
    reference = Path(args.reference)
    program = Path(args.program)
    diff_dir = Path(args.diff)
    report = {"target": {"mean_abs_channel_error": 2.0, "over24_pct": 3.0}, "screens": {}, "themes": {}}
    for screen in SCREENS:
        name = f"{screen}-graphite.png"
        report["screens"][screen] = compare(reference / name, program / name, diff_dir / name)
    for theme in THEMES:
        name = f"overview-{theme}.png"
        report["themes"][theme] = compare(reference / name, program / name, diff_dir / name)
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    for group in ("screens", "themes"):
        for name, metrics in report[group].items():
            print(f"{group}/{name}: MAE={metrics['mean_abs_channel_error']} over24={metrics['over24_pct']}%")
    print(f"ui_parity: wrote {out} and {len(SCREENS) + len(THEMES)} diff images")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
