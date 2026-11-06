#!/usr/bin/env python3
"""Generate typed renderer constants from design/ui-spec.json.

The JSON is the canonical contract; this file is committed so builds do not
need Python. Run `python3 design/validate.py` after editing the spec.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SPEC = ROOT / "design/ui-spec.json"
OUT = ROOT / "src/app/design/ui_spec.zig"


def main() -> int:
    spec = json.loads(SPEC.read_text())
    if spec.get("$schema") != "xsprof/ui-spec/v1":
        raise SystemExit("ui-spec: unexpected schema")
    atlas = ROOT / spec["render"]["text_atlas"]["file"]
    digest = hashlib.sha256(atlas.read_bytes()).hexdigest()
    if digest != spec["render"]["text_atlas"]["sha256"]:
        raise SystemExit("ui-spec: atlas hash is stale")
    bps = spec["breakpoints"]
    shell = spec["shell"]
    canvas = spec["canvas"]
    lines = [
        "//! GENERATED from design/ui-spec.json by tools/gen_ui_spec.py. Do not edit.",
        "//! The formal contract every native CPU/Metal/GL surface consumes.",
        "",
        "const std = @import(\"std\");",
        "",
        f'pub const schema = "{spec["$schema"]}";',
        f"pub const version: u32 = {spec['version']};",
        f'pub const prototype_sha256 = "{spec["design_source"]["sha256"]}";',
        f"pub const reference_width: f32 = {canvas['reference']['width']}.0;",
        f"pub const reference_height: f32 = {canvas['reference']['height']}.0;",
        f"pub const native_width: f32 = {canvas['native']['width']}.0;",
        f"pub const native_height: f32 = {canvas['native']['height']}.0;",
        f"pub const shell_top: f32 = {shell['topbar_h']}.0;",
        f"pub const shell_bottom: f32 = {shell['keybar_h']}.0;",
        f"pub const rail_width: f32 = {shell['rail_w']}.0;",
        f"pub const rail_item_h: f32 = {shell['rail_item_h']};",
        f"pub const stage_pad_top: f32 = {shell['stage_pad_top']}.0;",
        f"pub const stage_pad_x: f32 = {shell['stage_pad_x']}.0;",
        f"pub const stage_pad_bottom: f32 = {shell['stage_pad_bottom']}.0;",
        f"pub const cross_mae_max: f32 = {spec['acceptance']['cross_surface']['cpu_vs_metal']['mae_max']};",
        f"pub const cross_over24_max: f32 = {spec['acceptance']['cross_surface']['cpu_vs_metal']['over24_max']};",
        "pub const text_atlas_sha256: [32]u8 = .{",
    ]
    raw = bytes.fromhex(digest)
    for i in range(0, 32, 8):
        lines.append("    " + ", ".join(f"0x{b:02x}" for b in raw[i:i + 8]) + ",")
    lines += [
        "};",
        "pub const Breakpoint = struct { max_width: u32, id: []const u8 };",
        "pub const breakpoints = [_]Breakpoint{",
    ]
    for bp in bps:
        width = bp.get("max_width", 1 << 20)
        lines.append(f'    .{{ .max_width = {width}, .id = "{bp["id"]}" }},')
    lines += [
        "};",
        "",
        "pub fn modeForWidth(width: f32) []const u8 {",
        "    for (breakpoints) |bp| {",
        "        if (width <= @as(f32, @floatFromInt(bp.max_width))) return bp.id;",
        "    }",
        "    return \"wide\";",
        "}",
        "",
        "test \"formal spec atlas hash is embedded\" {",
        "    const xsui = @import(\"xsui\");",
        "    var digest: [32]u8 = undefined;",
        "    std.crypto.hash.sha2.Sha256.hash(xsui.text_atlas, &digest, .{});",
        "    try std.testing.expectEqualSlices(u8, &text_atlas_sha256, &digest);",
        "}",
        "",
    ]
    OUT.write_text("\n".join(lines))
    print(f"ui_spec: wrote {OUT.relative_to(ROOT)} from {SPEC.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
