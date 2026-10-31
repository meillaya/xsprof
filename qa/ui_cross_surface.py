#!/usr/bin/env python3
"""Cross-surface gate: CPU is canonical; WebGL2 must match within the formal
ui-spec tolerance. Reference/prototype diffs are deliberately not part of this
gate. Developer-only; requires ffmpeg."""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SPEC = json.loads((ROOT / "design/ui-spec.json").read_text())
GATE = SPEC["acceptance"]["cross_surface"]["cpu_vs_webgl2"]
METAL_GATE = SPEC["acceptance"]["cross_surface"]["cpu_vs_metal"]
MAE_MAX = float(GATE["mae_max"])
OVER24_MAX = float(GATE["over24_max"])
PAIRS = [
    ("overview-graphite", "overview-graphite"),
    ("timeline-graphite", "timeline-graphite"),
    ("advisor-graphite", "advisor-graphite"),
    ("events-graphite", "events-graphite"),
    ("capture-graphite", "capture-graphite"),
    ("overview-dark", "overview-dark"),
    ("overview-paper", "overview-paper"),
    ("overview-latte", "overview-latte"),
    ("overview-frappe", "overview-frappe"),
    ("overview-macchiato", "overview-macchiato"),
    ("overview-mocha", "overview-mocha"),
]


def raw(path: Path) -> bytes:
    return subprocess.run(
        ["ffmpeg", "-v", "error", "-i", str(path), "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
        check=True,
        capture_output=True,
    ).stdout


def compare(cpu: Path, web: Path) -> dict:
    a, b = raw(cpu), raw(web)
    if len(a) != len(b):
        raise SystemExit(f"ui_cross_surface: size mismatch {cpu} {web}")
    total = 0
    bad = 0
    pixels = len(a) // 3
    for i in range(pixels):
        d = max(abs(a[i * 3 + k] - b[i * 3 + k]) for k in range(3))
        total += d
        if d > 24:
            bad += 1
    return {"mae": total / pixels, "over24": bad / pixels * 100.0, "pixels": pixels}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--cpu", required=True)
    ap.add_argument("--web", required=True)
    ap.add_argument("--metal", default="")
    ap.add_argument("--out", default="design/evidence/cross_surface.json")
    args = ap.parse_args()
    cpu_dir, web_dir = Path(args.cpu), Path(args.web)
    metal_dir = Path(args.metal) if args.metal else None
    rows = []
    failed = False
    for name, _ in PAIRS:
        cpu, web = cpu_dir / f"{name}.png", web_dir / f"{name}.png"
        if not cpu.exists() or not web.exists():
            print(f"ui_cross_surface: missing {cpu} or {web}", file=sys.stderr)
            return 2
        m = compare(cpu, web)
        ok = m["mae"] <= MAE_MAX and m["over24"] <= OVER24_MAX
        failed |= not ok
        rows.append({"state": name, "candidate": "webgl2", **m, "pass": ok})
        print(f"cross/webgl2/{name}: MAE={m['mae']:.3f} over24={m['over24']:.3f}% {'PASS' if ok else 'FAIL'}")
    metal_mae = float(METAL_GATE["mae_max"])
    metal_over = float(METAL_GATE["over24_max"])
    if metal_dir is not None:
        for name, _ in PAIRS[:5]:
            cpu, metal = cpu_dir / f"{name}.png", metal_dir / f"{name}.png"
            if not cpu.exists() or not metal.exists():
                print(f"ui_cross_surface: missing {cpu} or {metal}", file=sys.stderr)
                return 2
            m = compare(cpu, metal)
            ok = m["mae"] <= metal_mae and m["over24"] <= metal_over
            failed |= not ok
            rows.append({"state": name, "candidate": "metal", **m, "pass": ok})
            print(f"cross/metal/{name}: MAE={m['mae']:.3f} over24={m['over24']:.3f}% {'PASS' if ok else 'FAIL'}")
    report = {
        "schema": "xsprof/cross-surface/v1",
        "canonical": "cpu",
        "candidates": ["webgl2"] + (["metal"] if metal_dir else []),
        "thresholds": {
            "webgl2": {"mae_max": MAE_MAX, "over24_max": OVER24_MAX},
            "metal": {"mae_max": metal_mae, "over24_max": metal_over},
        },
        "states": rows,
        "pass": not failed,
    }
    out = ROOT / args.out
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(report, indent=2) + "\n")
    print(f"ui_cross_surface: {'PASS' if not failed else 'FAIL'} ({len(rows)} states)")
    return 0 if not failed else 1


if __name__ == "__main__":
    raise SystemExit(main())
