#!/usr/bin/env python3
"""Validate the design token set against design/index.html."""

from __future__ import annotations

import hashlib
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DESIGN = ROOT / "design"
SOURCE = DESIGN / "index.html"
COLOR_KEYS = [
    "bg", "panel", "raised", "raised-2", "field",
    "text", "muted", "dim", "faint",
    "line", "line-strong",
    "live", "pass", "skip", "refuse", "pending", "vm",
    "tint-live", "tint-refuse", "tint-skip", "tint-pass",
    "lane-1", "lane-2", "lane-3", "lane-4", "lane-5", "lane-6", "lane-7", "lane-8", "lane-9",
    "lane-idle", "lane-grid", "focus",
]
THEME_IDS = ["dark", "paper", "latte", "frappe", "macchiato", "mocha"]
SCREEN_IDS = ["overview", "timeline", "advisor", "events", "capture"]
ROUTE_IDS = ["home", "overview", "timeline", "advisor", "events", "capture", "audit", "settings"]
FLOW_IDS = [
    "boot", "screen-navigation", "command-palette", "appearance-theme",
    "keyboard-help", "open-journal", "reload-fixture", "timeline-playback",
    "timeline-zoom-fit", "timeline-brush", "timeline-select",
    "advisor-filter-evidence", "events-filter", "events-detail",
    "capture-copy", "toast-feedback", "responsive-relayout",
    "home-source-select", "source-loading", "onboarding", "recorder-lifecycle",
    "extract-window", "export", "audit-verify", "settings-persist", "a11y-focus",
]

errors: list[str] = []


def load(name: str) -> dict:
    try:
        return json.loads((DESIGN / name).read_text())
    except Exception as exc:  # noqa: BLE001 - report every malformed file
        errors.append(f"{name}: invalid JSON: {exc}")
        return {}


def check(condition: bool, message: str) -> None:
    if not condition:
        errors.append(message)


def source_meta() -> tuple[str, int]:
    raw = SOURCE.read_bytes()
    return hashlib.sha256(raw).hexdigest(), len(raw)


def check_source(label: str, sha: str, size: int) -> None:
    check(sha == source_sha, f"{label}: source sha256 mismatch")
    check(size == source_bytes, f"{label}: source byte count mismatch")


source_sha, source_bytes = source_meta()
palettes = load("palettes.json")
tokens = load("tokens.json")
screens = load("screens.json")
flows = load("flows.json")
keys = load("keybindings.json")
commands = load("command-palette.json")

# Sources and schema names.
check(palettes.get("$schema") == "xsprof/design-palettes/v1", "palettes.json: schema")
check(tokens.get("$schema") == "xsprof/design-tokens/v1", "tokens.json: schema")
check(screens.get("$schema") == "xsprof/design-screens/v1", "screens.json: schema")
check(flows.get("$schema") == "xsprof/design-flows/v1", "flows.json: schema")
check(keys.get("$schema") == "xsprof/design-keybindings/v1", "keybindings.json: schema")
check(commands.get("$schema") == "xsprof/design-commands/v1", "command-palette.json: schema")

check_source("palettes.json", palettes.get("source", {}).get("sha256", ""), palettes.get("source", {}).get("bytes", -1))
check_source("tokens.json", tokens.get("meta", {}).get("sourceSha256", ""), tokens.get("meta", {}).get("sourceBytes", -1))
for label, doc in [("screens.json", screens), ("flows.json", flows), ("keybindings.json", keys), ("command-palette.json", commands)]:
    check_source(label, doc.get("source", {}).get("sha256", ""), doc.get("source", {}).get("bytes", -1))

check(tokens.get("meta", {}).get("paletteSource") == "palettes.json", "tokens.json: paletteSource")

# Palette coverage and consistency.
themes = palettes.get("themes", [])
check([t.get("id") for t in themes] == THEME_IDS, "palettes.json: theme order/ids")
check(palettes.get("defaultTheme") == "dark", "palettes.json: default theme")
check(palettes.get("attribute") == "data-theme", "palettes.json: theme attribute")
seen_keys: set[str] | None = None
for theme in themes:
    tid = theme.get("id")
    values = theme.get("tokens", {})
    keyset = set(values)
    if seen_keys is None:
        seen_keys = keyset
    check(keyset == set(COLOR_KEYS), f"palettes.json: {tid} color key set")
    check(keyset == {k for k in COLOR_KEYS if k in values}, f"palettes.json: {tid} has unknown tokens")
    for key, value in values.items():
        if value.startswith("#"):
            check(re.fullmatch(r"#[0-9a-fA-F]{6}", value) is not None, f"palettes.json: {tid}.{key} invalid hex")
        elif value.startswith("rgba("):
            check(re.fullmatch(r"rgba\(\d{1,3}, \d{1,3}, \d{1,3}, 0?\.\d+\)", value) is not None,
                  f"palettes.json: {tid}.{key} invalid rgba")
        else:
            errors.append(f"palettes.json: {tid}.{key} has unsupported color {value!r}")
    check(len(theme.get("derived", {})) == 9, f"palettes.json: {tid} derived color count")

# tokens.css must match the palette values for every theme.
css = (DESIGN / "tokens.css").read_text()
check(f"source sha256: {source_sha}" in css, "tokens.css: missing source hash")

def css_block(selector: str) -> dict[str, str]:
    found = {}
    pattern = re.compile(re.escape(selector) + r"\s*\{(.*?)\}", re.S)
    match = pattern.search(css)
    if not match:
        return found
    for line in match.group(1).splitlines():
        line = line.strip()
        if line.startswith("--") and ":" in line:
            key, value = line.split(":", 1)
            found[key.strip()[2:]] = value.strip().rstrip(";")
    return found

root_colors = css_block(":root")
for key in COLOR_KEYS:
    if key in root_colors:
        check(root_colors[key] == palettes["themes"][0]["tokens"][key],
              f"tokens.css: :root --{key} differs from palettes.json")

# Shared typography / spacing / shell variables must mirror tokens.json.
def px(value: float) -> str:
    return f"{int(value)}px" if float(value).is_integer() else f"{value}px"

scale = tokens.get("typography", {}).get("scale", {})
for token_name, spec in scale.items():
    css_var = spec.get("cssVar", "").lstrip("-")
    check(root_colors.get(css_var) == px(spec.get("px", 0)),
          f"tokens.css: --{css_var} differs from tokens.json")
for token_name, value in tokens.get("spacing", {}).get("tokens", {}).items():
    check(root_colors.get(token_name) == px(value),
          f"tokens.css: --{token_name} differs from tokens.json")
shell = tokens.get("layout", {}).get("shell", {})
check(root_colors.get("topbar-h") == px(shell.get("topbar", {}).get("height", 0)),
      "tokens.css: --topbar-h differs")
check(root_colors.get("keybar-h") == px(shell.get("keybar", {}).get("height", 0)),
      "tokens.css: --keybar-h differs")
check(root_colors.get("rail-w") == px(tokens.get("layout", {}).get("rail", {}).get("width", 0)),
      "tokens.css: --rail-w differs")
stack = tokens.get("typography", {}).get("family", {}).get("stack", [])
expected_mono = f'"{stack[0]}", ' + ", ".join(stack[1:]) if stack else ""
check(root_colors.get("mono") == expected_mono, "tokens.css: --mono differs from tokens.json")
check(root_colors.get("focus") == palettes["themes"][0]["tokens"]["focus"],
      "tokens.css: --focus differs from palettes.json")
check(root_colors.get("focus-offset") == "2px", "tokens.css: --focus-offset")
for theme in themes:
    if theme["id"] == "dark":
        continue
    block = css_block(f'html[data-theme="{theme["id"]}"]')
    for key in COLOR_KEYS:
        check(block.get(key) == theme["tokens"].get(key),
              f"tokens.css: {theme['id']} --{key} differs from palettes.json")

# Screen/flow/keymap/command coverage.
screen_ids = [s.get("id") for s in screens.get("screens", [])]
check(screen_ids == ROUTE_IDS, "screens.json: product routes")
check(len(screens.get("overlays", [])) >= 6, "screens.json: overlays")
check(all(o.get("id") != "file-input" for o in screens.get("overlays", [])), "screens.json: no web file-input utility")
route_ids = [s.get("id") for s in screens.get("screens", [])]
for route_id in ROUTE_IDS:
    check(route_id in route_ids, f"screens.json: missing route {route_id}")
flow_ids = [f.get("id") for f in flows.get("flows", [])]
for flow_id in FLOW_IDS:
    check(flow_id in flow_ids, f"flows.json: missing {flow_id}")
for context_id in ["global", "dialog-open", "palette-input", "events-filter-input", "rail-tablist", "timeline-pointer", "native-port"]:
    check(context_id in [c.get("id") for c in keys.get("contexts", [])], f"keybindings.json: missing {context_id}")
cmds = commands.get("commands", [])
check(len(cmds) == 35, "command-palette.json: 35 commands")
check([c.get("group") for c in cmds].count("theme") == 6, "command-palette.json: six theme commands")
check([c.get("group") for c in cmds].count("go") == 8, "command-palette.json: eight routes")
check(commands.get("palette", {}).get("focusReturn") == "palette button", "command-palette.json: focus return")

# Component/layout sanity anchors used by the GPU map.
typo = tokens.get("typography", {})
check(typo.get("body", {}).get("size") == "13px", "tokens.json: body 13px")
check(typo.get("body", {}).get("lineHeight") == 1.5, "tokens.json: body line-height")
check(tokens.get("layout", {}).get("shell", {}).get("rows") == ["52px", "minmax(0, 1fr)", "30px"], "tokens.json: shell rows")
gpu = tokens.get("gpu", {}).get("instanceAbi", {})
check(gpu.get("bytes") == 72 and gpu.get("lanesF32") == 18, "tokens.json: instance ABI")
check(tokens.get("gpu", {}).get("parity", {}).get("primaryViewport") == "1440x900 @ DPR 1", "tokens.json: primary viewport")


# Formal runtime contract: the canonical spec must match the embedded assets,
# screens, breakpoints, and generated Zig constants.
spec_path = DESIGN / "ui-spec.json"
check(spec_path.exists(), "ui-spec.json: missing")
spec = json.loads(spec_path.read_text()) if spec_path.exists() else {}
check(spec.get("$schema") == "xsprof/ui-spec/v1", "ui-spec.json: schema")
check(spec.get("version") == 2, "ui-spec.json: version")
check(spec.get("render", {}).get("platform_fonts") is False, "ui-spec.json: platform_fonts must be false")
check(spec.get("canvas", {}).get("reference", {}).get("width") == 1440, "ui-spec.json: reference width")
check(spec.get("canvas", {}).get("reference", {}).get("height") == 900, "ui-spec.json: reference height")
check([s.get("max_width") for s in spec.get("breakpoints", []) if "max_width" in s] == [1320, 1140, 1024, 780, 420],
      "ui-spec.json: breakpoints")
check(spec.get("screens") == ROUTE_IDS, "ui-spec.json: screens")
check(spec.get("extension", {}).get("status") == "proposed", "ui-spec.json: extension marked proposed")
backends = spec.get("render", {}).get("backends", [])
check("webgl2" not in backends and "wasm" not in backends, "ui-spec.json: web backends removed")
check("cpu_vs_webgl2" not in spec.get("acceptance", {}).get("cross_surface", {}), "ui-spec.json: webgl2 cross-surface gate removed")
check(len(spec.get("overlays", [])) >= 7, "ui-spec.json: overlays")
atlas_meta = spec.get("render", {}).get("text_atlas", {})
atlas_path = ROOT / atlas_meta.get("file", "")
check(atlas_path.exists(), "ui-spec.json: text atlas missing")
if atlas_path.exists():
    atlas_bytes = atlas_path.read_bytes()
    check(hashlib.sha256(atlas_bytes).hexdigest() == atlas_meta.get("sha256"),
          "ui-spec.json: text atlas hash is stale")
    check(len(atlas_bytes) == atlas_meta.get("bytes"), "ui-spec.json: text atlas size")
gen_path = ROOT / "src/app/design/ui_spec.zig"
check(gen_path.exists(), "ui_spec.zig: generated file missing")
if gen_path.exists() and atlas_meta.get("sha256"):
    generated = gen_path.read_text()
    digest = bytes.fromhex(atlas_meta["sha256"])
    byte_lines = ",\n".join(
        "    " + ", ".join(f"0x{b:02x}" for b in digest[i:i + 8])
        for i in range(0, 32, 8)
    )
    check(byte_lines in generated, "ui_spec.zig: atlas hash does not match ui-spec.json")
    check('pub const shell_top: f32 = 52.0;' in generated, "ui_spec.zig: shell_top")
    check('pub const rail_width: f32 = 92.0;' in generated, "ui_spec.zig: rail_width")
backends = spec.get("render", {}).get("backends", [])
metal_gate = spec.get("acceptance", {}).get("cross_surface", {}).get("cpu_vs_metal", {})
check(metal_gate.get("mae_max", 0) > 0 and metal_gate.get("over24_max", 0) > 0, "ui-spec.json: cpu-vs-metal gate")
check(spec.get("acceptance", {}).get("reference", {}).get("pixel_gate") is False,
      "ui-spec.json: reference must be advisory")

if errors:
    print("design: FAIL", file=sys.stderr)
    for error in errors:
        print(f"  - {error}", file=sys.stderr)
    sys.exit(1)
print(f"design: PASS ({len(themes)} palettes, {len(screen_ids)} screens, {len(flow_ids)} flows, {len(cmds)} commands)")
