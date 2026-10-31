#!/usr/bin/env python3
"""Generate lib/xsui/src/design_palettes.zig from design/palettes.json."""
from __future__ import annotations

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "design" / "palettes.json"
OUT = ROOT / "lib" / "xsui" / "src" / "design_palettes.zig"

COLOR_FIELDS = [
    "bg", "panel", "raised", "raised-2", "field", "text", "muted", "dim",
    "faint", "line", "line-strong", "live", "pass", "skip", "refuse",
    "pending", "vm", "tint-live", "tint-refuse", "tint-skip", "tint-pass",
    "lane-1", "lane-2", "lane-3", "lane-4", "lane-5", "lane-6", "lane-7",
    "lane-8", "lane-9", "lane-idle", "lane-grid", "focus",
]
DERIVED_FIELDS = {
    "chip-source-border": "chip_source_border",
    "chip-journal-border": "chip_journal_border",
    "chip-loss-border": "chip_loss_border",
    "control-pressed-border": "control_pressed_border",
    "button-hover-border": "button_hover_border",
    "segment-loss-border": "segment_loss_border",
    "refuse-chip-border": "refuse_chip_border",
    "theme-option-active-border": "theme_option_active_border",
    "ledger-loss-hover-surface": "ledger_loss_hover",
}
FIELD_NAMES = {
    "raised-2": "raised2", "line-strong": "line_strong",
    "tint-live": "tint_live", "tint-refuse": "tint_refuse",
    "tint-skip": "tint_skip", "tint-pass": "tint_pass",
    "lane-idle": "lane_idle", "lane-grid": "lane_grid",
}


def color(name: str, value: str) -> str:
    if value.startswith("#"):
        r, g, b = (int(value[i:i+2], 16) for i in (1, 3, 5))
        return f".{{ .r = 0x{r:02x}, .g = 0x{g:02x}, .b = 0x{b:02x} }}"
    m = re.fullmatch(r"rgba\((\d+), (\d+), (\d+), (0?\.\d+)\)", value)
    if not m:
        raise SystemExit(f"{name}: unsupported color {value!r}")
    r, g, b = (int(m.group(i)) for i in (1, 2, 3))
    a = round(float(m.group(4)) * 255)
    return f".{{ .r = 0x{r:02x}, .g = 0x{g:02x}, .b = 0x{b:02x}, .a = {a} }}"


data = json.loads(SOURCE.read_text())
lines = [
    "//! Generated from design/palettes.json. Do not edit by hand.",
    "//! Regenerate with tools/gen_design_tokens.py; keep design/validate.py green.",
    "",
    'const draw = @import("draw.zig");',
    "",
    "pub const Palette = draw.Theme;",
    f'pub const design_source_sha256 = "{data["source"]["sha256"]}";',
    "",
    "pub const Preset = struct {",
    "    id: []const u8,",
    "    name: []const u8,",
    "    kind: []const u8,",
    "    group: []const u8,",
    "    theme: Palette,",
    "};",
    "",
]

const_names = []
for theme in data["themes"]:
    tid = theme["id"]
    name = ("graphite" if tid == "dark" else tid) + "_palette"
    const_names.append((tid, name))
    lines.append(f"pub const {name}: Palette = .{{")
    tokens = theme["tokens"]
    for key in COLOR_FIELDS:
        if key.startswith("lane-") and key[5:].isdigit():
            continue
        value = tokens[key]
        field = FIELD_NAMES.get(key, key.replace("-", "_"))
        lines.append(f"    .{field} = {color(key, value)},")
    lines.append("    .lanes = .{")
    for i in range(1, 10):
        lines.append(f"        {color(f'lane-{i}', tokens[f'lane-{i}'])}, // lane {i}")
    lines.append("    },")
    lines.append("    .hairline = " + color("line", tokens["line"]) + ",")
    for rid, field in DERIVED_FIELDS.items():
        lines.append(f"    .{field} = {color(rid, theme['derived'][rid])},")
    lines.append("};")
    lines.append("")

lines.append("pub const presets = [_]Preset{")
for theme in data["themes"]:
    tid = theme["id"]
    const = ("graphite" if tid == "dark" else tid) + "_palette"
    lines.append(
        f'    .{{ .id = "{tid}", .name = "{theme["name"]}", '
        f'.kind = "{theme["kind"]}", .group = "{theme["group"]}", .theme = {const} }},'
    )
lines.append("};")
lines.append("")
lines.append("pub const default = graphite_palette;")
lines.append("")
lines.append('test "all six palettes are present and distinct" {')
lines.append("    try @import(\"std\").testing.expectEqual(@as(usize, 6), presets.len);")
lines.append("    try @import(\"std\").testing.expect(graphite_palette.bg.r != paper_palette.bg.r);")
lines.append("    try @import(\"std\").testing.expect(graphite_palette.lanes[0].r == 0x58);")
lines.append("    try @import(\"std\").testing.expect(graphite_palette.chip_source_border.r == 0x3a);")
lines.append("}")

OUT.write_text("\n".join(lines) + "\n")
print(f"wrote {OUT} ({len(data['themes'])} palettes)")
