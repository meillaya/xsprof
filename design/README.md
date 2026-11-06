# xsprof UI/UX design tokens

This folder is the design-side contract for the operator console prototype in
[`index.html`](index.html) in this folder. It captures every token,
screen, flow, keybinding, palette, and GPU mapping needed to reproduce the
prototype rather than approximating it.

- Source: `design/index.html` (this folder)
- Source sha256: `0823328b3261b89ce2d8c2af53ebc61adfedd49f19706239e437b7fdb6a3de62`
- Source size: 221,754 bytes
- Token set version: `1.0.0`
- Reference viewports: frozen prototype `1440x900 @1` (design input only), native `1280x720 @1`
- Real capture evidence: [`fixtures/real/macos-vm-sched.ndjson`](../fixtures/real/macos-vm-sched.ndjson)
  (Linux VM perf, 110,284 events) drives the live screenshots and video.
- Status: implemented as the primary GPU console (`src/app/design/`,
  `lib/xsui/src/canvas.zig`). The formal contract is
  [`ui-spec.json`](ui-spec.json); CPU is canonical and CPU/Metal/GL are
  gated by [`qa/ui_cross_surface.py`](../qa/ui_cross_surface.py). The prototype
  remains the design source, and its pixel diff is advisory.

## Files

| File | Contents |
|---|---|
| [`ui-spec.json`](ui-spec.json) | canonical runtime contract: draw list, text atlas/hash, palettes, breakpoints, shell, components, interactions, cross-surface gates |
| [`tokens.json`](tokens.json) | canonical shared tokens: meta, typography, spacing, radii, borders, focus, layout, components, motion, GPU ABI |
| [`palettes.json`](palettes.json) | canonical color source: six palettes, semantic roles, state contract, color-mix recipes, per-theme derived colors |
| [`tokens.css`](tokens.css) | generated CSS custom properties for Graphite, Paper, and four Catppuccin flavours |
| [`screens.json`](screens.json) | shell, eight routes (five analysis screens plus product shell), overlays, regions, content contracts, states, responsive behavior |
| [`flows.json`](flows.json) | lifecycle, navigation, overlays, journal, timeline, advisor, events, capture, feedback, and responsive flows |
| [`keybindings.json`](keybindings.json) | global, dialog, palette, rail, timeline-pointer, and native-port key/gesture maps |
| [`command-palette.json`](command-palette.json) | 35 exact palette commands (product shell v2), appearance options, help sheet, grouping and search rules |
| [`product-shell.md`](product-shell.md) | product shell v2 extension: Home/Audit/Settings routes, picker/confirm/onboarding overlays, hit-id policy, persistence/audit/a11y contract, fail-closed matrix and integration hooks |
| [`gpu-mapping.md`](gpu-mapping.md) | token-to-instance mapping, color/text/layout requirements, parity harness, known gaps |
| [`index.html`](index.html) | the console prototype itself; self-contained, source of truth for all tokens |
| [`validate.py`](validate.py) | checks source hash, JSON validity, palette coverage, CSS parity, screens/flows presence, atlas hash, and the formal spec |

`palettes.json` is the single source for colors. `tokens.json` references it
through `meta.paletteSource` and owns everything else. `tokens.css` is a
generated convenience export; if it disagrees with the JSON, the JSON wins.

## Palettes

| id | name | kind | group | swatches |
|---|---|---|---|---|
| `dark` | Graphite | dark | core | `#050505` `#10100e` `#58d7e8` `#f5efe4` |
| `paper` | Paper | light | core | `#f3ead7` `#f8f1e3` `#0c6776` `#1b1813` |
| `latte` | Catppuccin Latte | light | flavor | `#dce0e8` `#eff1f5` `#1753b9` `#4c4f69` |
| `frappe` | Catppuccin Frappe | dark | flavor | `#232634` `#303446` `#91adef` `#c6d0f5` |
| `macchiato` | Catppuccin Macchiato | dark | flavor | `#181926` `#24273a` `#8aadf4` `#cad3f5` |
| `mocha` | Catppuccin Mocha | dark | flavor | `#11111b` `#1e1e2e` `#89b4fa` `#cdd6f4` |

Each palette carries the same 33 color tokens: 5 surfaces, 4 inks, 2 strokes,
6 semantic states, 4 tints, 9 lanes + idle + grid, and the focus ring. The
`derived` object in each theme contains the 8-bit values for the nine
`color-mix(in srgb, …)` borders and hover surfaces. The recipes in
`colorMixRecipes` are the canonical form; the derived hex values are rounded
convenience values.

Semantic state is never color-only. READY/DEGRADED/SKIP/REFUSE/CLEAR/WARNING/
INFO/LIVE/VM always pair a color with a label and often a glyph (`● ◐ ○ ■`).
Loss rows are `LOSS` + `■` with a `tint-refuse` background.

## Screens and overlays

| id | title | key | purpose |
|---|---|---|---|
| `home` | Home | `0` | onboarding CTA, source choice (live/replay/recorder/demo), time frame, recents, capabilities, recorder strip |
| `overview` | Overview | `1` | brief, capability matrix, per-CPU lanes, advisor preview, top threads, event mix, memory/NUMA, loss ledger |
| `timeline` | Timeline | `2` | CPU/thread lanes, playback, zoom/brush, loss bands, minimap, inspector |
| `advisor` | Advisor | `3` | seven rules, severity filters, evidence jumps, suggestion-only copy |
| `events` | Events | `4` | sanitized ledger, text/type filtering, detail pane |
| `capture` | Recorder | `5` | recorder start/stop/restart, compact retention, segments, verify, exports, history, compare |
| `audit` | Audit | `6` | provenance, manifest lifecycle, verify, capability/gate evidence, operator action log, compare/export |
| `settings` | Settings | `7` / Cmd+, | appearance, capture/storage defaults, accessibility, diagnostics, advanced headless equivalents, reset/onboarding |

Shared shell: skip link, topbar (brand, current route, session meta, source/
loss/safety chips, palette/theme/help buttons), vertical route rail or bottom
route bar, stage, keybar with status. Overlays: command palette, appearance,
keyboard help, onboarding, GPU picker, confirm, toast. The native GPU picker is the only source-picker surface. Home/Recorder/Audit/Settings and
their overlays are the product-shell extension documented in
[`product-shell.md`](product-shell.md); the pinned prototype remains the
visual source for the five analysis screens.

`design/index.html` is responsive at 1320, 1140, 1024, 780, and 420 CSS px. The
1024px breakpoint turns the rail into a bottom bar and hides the keybar.

## Flows

`flows.json` covers boot, screen navigation, command palette, appearance,
keyboard help, journal open (picker and drag/drop), fixture reload, playback,
zoom/fit, brush, selection/inspector, advisor filter/evidence, events filter,
events detail actions, capture command copy, toast feedback, and responsive
relayout. Each flow lists triggers, preconditions, steps, outcomes, failures,
and source function names.

## Keyboard

The core map (full contexts in [`keybindings.json`](keybindings.json)):

- `1`–`5` screens; `/` events filter; `?` help; `w` appearance; `f` fit
- `+` / `=` zoom in; `−` / `_` zoom out; `t` playhead to end
- `space` play/pause (not captured when focus is on a button/link/tab)
- `c` copy selected slice summary; `esc` clear selection/close overlay
- `⌘K` / `Ctrl K` command palette
- palette: `↑`/`↓` move, `enter` run, `esc` close
- rail: arrow keys cycle screens
- events filter: typing filters; `esc` clears and blurs
- timeline: drag >4px brush; release >20ms zooms; click selects; double-click
  fits; minimap click centers

The command palette has exactly 17 commands in three display groups
(`screen`, `action`, `theme`). Appearance has two core themes and four
Catppuccin flavours; selection applies immediately and announces via toast.

## Pixel rules

- CSS logical pixels are the design unit. At DPR 1, one CSS px = one GPU px.
- The prototype uses no gradients, blur, or decorative shadows. The only
  shadow-like effects are a 2px inset selection bar, a 3px pulse ring, and a
  1px inset idle-legend border.
- The body is `13px/1.5` JetBrains Mono with tabular numerals and antialiased
  rendering. The prototype embeds Bold 700 only; the `xsui` package bundles
  Regular 400 and Bold 700, which is the deterministic choice for GPU output.
- Focus is always visible: 2px `focus` outline, 2px offset, 2px radius.
- Reduced motion collapses animation and transition durations to 0.001ms.
- `prefers-reduced-motion` and the state policy are part of the contract; a
  snapshot that hides loss/refusal/SKIP is wrong even if it looks cleaner.

### Fractional type

The token scale contains fractional sizes (`10.5`, `9.5`, `8.5`, `12.5`).
Current `xsui` text rounds to whole pixels. The exact CSS values are preserved
here; the GPU text path must either support fractional sizes or adopt an
explicit snapping table before claiming pixel parity.

### Color mixes

CSS `color-mix(in srgb, …)` borders are precomputed in `palettes.derived`.
Keep float channels until final quantization. A GPU implementation that mixes at
runtime must use the same sRGB recipe, not a linear-light approximation.

## Validate

```sh
python3 design/validate.py
```

The validator checks that the source hash in the JSON matches `design/index.html`,
every JSON parses, all six palettes expose the same 33 color tokens, the CSS
export matches each palette token, and the five screens and required flows are
present. It prints `design: PASS` on success.

## Updating

1. Change the prototype first (`design/index.html`).
2. Re-extract palettes and CSS, or update the JSON/CSS by hand for non-color
   changes.
3. Update `meta.sourceSha256` / `sourceBytes` in `palettes.json`,
   `tokens.json`, `screens.json`, `flows.json`, `keybindings.json`, and
   `command-palette.json`.
4. Run `python3 design/validate.py`.
5. Update `gpu-mapping.md` if the change affects ABI, text, layout, or parity.

Do not add a token that only exists in this folder but not in the prototype
without marking it as a proposed extension. The design folder describes the
desired UI; it is not a second source of truth for behavior.

## Relationship to `lib/xsui`

The GPU UI package lives in [`lib/xsui`](../lib/xsui/README.md). This folder
is design input for that package: palette maps are generated into
`lib/xsui/src/design_palettes.zig` by `tools/gen_design_tokens.py`, component
metrics are encoded in `src/app/design/`, and `gpu-mapping.md` tracks renderer
parity. Run `python3 design/validate.py` after changing the prototype or
tokens.

## Implemented console and evidence

The production surface is the native AppKit/X11 console under
`src/platform/` and `xsprof snapshot`. The old lab rail is not
part of the console; `xsprof lab` remains a headless developer tool.

Evidence lives in:

- [`screenshots/prototype/`](screenshots/prototype/) — frozen reference
  captures of the design prototype (not a shipped surface).
- [`screenshots/native/`](screenshots/native/) — native GPU snapshots of the
  analysis routes.
- [`media/xsprof-native-showcase.mp4`](media/xsprof-native-showcase.mp4) —
  deterministic native offscreen showcase.
- [`media/xsprof-native-live-replay.mp4`](media/xsprof-native-live-replay.mp4) —
  live-capture replay in the native console.
- [`evidence/README.md`](evidence/README.md) — method, caveats, and commands.

Regenerate with `sh qa/showcase_smoke.sh` after building the binary. It is
developer-only and uses the native snapshot renderer plus ffmpeg; no browser,
Playwright, or real window is involved.
