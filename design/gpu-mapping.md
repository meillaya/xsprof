# GPU rendering contract

This document maps the design tokens to a flat-instance GPU UI. The canonical
runtime contract is [`ui-spec.json`](ui-spec.json): CPU is the reference
rasterizer and native Metal/GL consume the same draw list, fractional geometry,
and staged text atlas. The HTML prototype is the design source; its
pixel diff is advisory. Formal cross-surface results live in
the committed stills under `screenshots/native/` and the CPU rasterizer's
deterministic framebuffer hashes.

The token values live in [`tokens.json`](tokens.json),
[`palettes.json`](palettes.json), and the generated [`tokens.css`](tokens.css).
The source of truth is the inline CSS/markup/script in `design/index.html`
(sha256 `0823328b3261b89ce2d8c2af53ebc61adfedd49f19706239e437b7fdb6a3de62`).

## 1. Canonical target

| Target | Size | DPR | Role |
|---|---|---|---|
| Prototype parity | 1440×900 | 1 | frozen design comparison canvas |
| Native parity | 1280×720 | 1 | current `xsprof ui` window |
| Responsive checks | 1320×900, 1140×900, 1024×768, 780×900, 420×900 | 1 | breakpoint behavior |

- One CSS logical pixel maps to one GPU logical pixel at DPR 1. At DPR 2,
  geometry and text sizes double; never scale type independently.
- The shell is `52px` topbar + `1fr` body + `30px` keybar, `100dvh`, with the
  body split into a `92px` rail and a flexible stage.
- The stage uses `16px 24px 24px` padding and caps the screen at `1600px`.
- Do not apply device scaling twice. The native window is DPR 1 in the
  prototype comparison.

## 2. Token mapping to `xsui`

The prototype has a richer color set than the current `xsui.Theme` struct.
Extend the GPU theme model (or keep a parallel design theme) before claiming
pixel parity.

| Prototype token | Role | Current `xsui.Theme` | Required action |
|---|---|---|---|
| `bg` | canvas | `bg` | present |
| `panel` | primary panel | `panel` | present |
| `raised` | hover/selected surface | `raised` | present |
| `raised-2` | active surface | — | add |
| `field` | inset field | — | add |
| `text` | primary ink | `text` | present |
| `muted` | secondary ink | `muted` | present |
| `dim` | tertiary ink | — | add |
| `faint` | quaternary ink | — | add |
| `line` | hairline | `hairline` | rename/map |
| `line-strong` | strong hairline | — | add |
| `live` | live/interactive | `live` | present |
| `pass` | PASS/READY | `pass` | present |
| `skip` | SKIP/uncollected | `skip` | present |
| `refuse` | REFUSE/loss | `refuse` | present |
| `pending` | pending | `pending` | present |
| `vm` | VM-only identity | `vm` | present |
| `tint-live/refuse/skip/pass` | translucent fills | — | add as straight-alpha colors |
| `lane-1..9`, `lane-idle`, `lane-grid` | timeline lanes | — | add |
| `focus` | focus ring | — | add |

`palettes.json` is the single source for these values. The active palette is
selected with `data-theme` (`dark`, `paper`, `latte`, `frappe`, `macchiato`,
`mocha`). `dark` is Graphite and the default; `paper` is the second core
palette; four Catppuccin flavours remap the same semantic roles.

Semantic state is always paired with a label or glyph. Color alone is not a
state signal. Do not render unsafe, lost, or refused data as success.

## 3. Instance/draw-list mapping

Current `xsui` ABI (pinned in the `xsui` draw list):

| Field | Offset | Notes |
|---|---|---|
| `rect` | 0 | x, y, w, h |
| `clip` | 16 | x0, y0, x1, y1 |
| `uv` | 32 | atlas coordinates |
| `color` | 48 | packed RGBA8 |
| `border_color` | 52 | packed RGBA8 |
| `radius` | 56 | rounded-rect radius |
| `border_width` | 60 | ring width |
| `mode` | 64 | 0 rect, 1 glyph |
| `pad` | 68 | padding |
| stride | 72 | 18 f32 lanes |
| vertices | 4 | triangle strip |
| atlas | 1024×1024 | R8 |

Metal pads each row to 80 bytes for MSL alignment; the shared Zig struct uses
the 72-byte stride. One draw call is expected for typical screens.

### Primitive recipes

| Design element | GPU primitives |
|---|---|
| Canvas | full-viewport rect `bg` |
| Panel/card/ledger/plot | rounded rect radius 5, fill `panel`, border 1 `line` |
| Brief strip | rounded rect radius 5, border, 5 child stats separated by 1px `line` rects |
| Chip/state/kbd/filter chip | rounded rect radius 3, 1px border, uppercase glyphs |
| Button/icon button | rounded rect radius 4, 1px border, 30px/28px height |
| Focus ring | rounded rect stroke radius 2, width 2, offset 2 |
| Selection inset | 2px rect at leading edge; do not use a blur/shadow |
| Divider | 1px rect in `line` |
| Timeline slice | rounded rect radius 1, opacity 0.88 (idle 1.0) |
| Timeline tick | 1.5px rect, opacity 0.75 |
| Loss band | 6px rect `refuse` at 0.16 opacity, plus 1px dashed line `2 3` and 2px ruler marker |
| Playhead | 1.25px rect `live` at 0.9 opacity |
| Brush | rect `live` at 0.1 opacity |
| Pulse dot | rounded rect radius 50%, 5px, plus 3px `tint-live` ring |
| Tooltip | rounded rect radius 4, `raised-2` fill, `line-strong` border |
| Dialog | rounded rect radius 6, `panel`, `line-strong` border; full-screen backdrop `rgba(0,0,0,0.62)` underneath |
| Toast | rounded rect radius 4, `raised-2`, 2px left border `live` (or `refuse` for error) |

There are no gradients, blurs, or decorative shadows in the prototype. The
only shadow-like effects are inset selection bars, the rail pulse ring, and the
idle legend inset.

Dashed lines do not exist in the draw list; emit repeated 1px rect segments
with 2px dash and 3px gap for the loss guide and the selected-event guide.

## 4. Color pipeline

1. Resolve the active palette from `palettes.json`.
2. Use straight-alpha RGBA8; tints already contain alpha.
3. Precompute `color-mix(in srgb, …)` borders per theme. `palettes.json`
   provides both the recipes and 8-bit convenience values under `derived`.
4. Keep float channels until final quantization. The convenience hex values
   are rounded; a shader that mixes at runtime should use the recipe and match
   the CPU reference exactly.
5. Render opacity by multiplying the instance alpha. The prototype's
   operations use both token alpha (tints) and element opacity (timeline
   slices/bands). Composite in the order listed in the screen spec.

Color-mix recipes:

| Recipe | Formula | Usage |
|---|---|---|
| `chip-source-border` | live 40% + line | SOURCE chip |
| `chip-journal-border` | pass 42% + line | JOURNAL chip |
| `chip-loss-border` | refuse 40% + line | loss chip |
| `control-pressed-border` | live 45% + line | pressed icon/button, active filter chip, open segment tag |
| `button-hover-border` | text 30% + line-strong | button hover border |
| `segment-loss-border` | refuse 45% + line | loss segment tag |
| `refuse-chip-border` | refuse 38% + line | refused-verb chip |
| `theme-option-active-border` | live 55% + line | selected theme option |
| `ledger-loss-hover-surface` | refuse 14% + panel | loss ledger hover |

Opacity constants: slice active `0.88`, idle `1.0`, thread slice `0.7`, tick
`0.75`, loss band `0.16`, loss label background `0.94`, loss ruler band `0.8`,
playhead `0.9`, brush `0.1`, minimap bars `0.55`, minimap loss `0.5`, window
box `0.7`, disabled controls `0.45`.

## 5. Typography

- Family: JetBrains Mono, fallback `ui-monospace, SFMono-Regular, Menlo,
  monospace`.
- Prototype embeds only the Bold 700 WOFF2 and relies on local JetBrains Mono
  for Regular. The `xsui` package bundles Regular 400 and Bold 700; use both
  for deterministic GPU rendering.
- Body: 13px / 1.5 / 400, tabular numerals, antialiased.
- Token scale: 10.5 / 11 / 12 / 13 / 15 / 20 / 27 px. Component extras:
  8.5 / 9 / 9.5 / 10 / 10.5 / 12.5 / 14 / 16 / 18 / 22 / 28 / 34 px.
- Uppercase labels use tracking 0.08–0.14em; bold display uses negative
  tracking -0.01 to -0.03em. Exact values are in `tokens.json`.
- Line-height roles include 1.0, 1.05, 1.1, 1.2, 1.25, 1.45, 1.5, 1.55, 1.6.
  The GPU text path must accept an explicit line height; it cannot assume one
  fixed value.

Required text extensions before pixel parity:

- fractional font sizes (8.5, 9.5, 10.5, 12.5) or an approved snapping table;
- per-glyph letter spacing;
- multiline wrapping for advisor summaries, recommendations, and panel notes;
- single-line ellipsis for task names, detail columns, rail labels where
  truncated;
- centered-aware text for ruler labels (`text-anchor: middle`) and right
  alignment for numeric columns;
- uppercase transform before atlas lookup (or precomputed strings).

## 6. Layout and responsiveness

The current `xsui` layout is a one-pass flex/column engine. The prototype uses
CSS Grid, wrapping, `max-width`, absolute positioning, hidden elements, and
media queries. Implementing the prototype therefore requires either extending
the layout engine or building screen-specific layout code from the tokens.

Breakpoints and required behavior are listed in `tokens.json` under
`layout.breakpoints` and summarized here:

| Max width | Required behavior |
|---|---|
| 1320 | 3-column grids become 2; last primary panel spans both |
| 1140 | hide brand sub; timeline to one column; inspector 190px + 1fr; events one column; event detail min-height 0 |
| 1024 | rail becomes fixed bottom bar, min 56px items; keybar hidden; app rows topbar + body; stage bottom padding 76; advisor/capture one column |
| 780 | hide session meta, safety text, palette hint; stage 14/14/84; grids one column; brief 2 columns; lead stat full row; 18px h1; restructured thread/ledger rows |
| 420 | hide brand sub/source chip; hide loss word; 22/28px stats; theme grid one column; 0.1em eyebrow |

Scroll: the stage scrolls vertically; the ledger rows scroll inside their own
max-height `min(56vh, 520px)`; the palette list `46vh`; appearance `88vh`.
Every scroll container needs its own clip rect. Native fixed-size windows
should choose a target breakpoint rather than approximate.

## 7. Timeline geometry

| Constant | Value |
|---|---|
| ruler height | 28px |
| CPU row height | 40px |
| CPU rows | 4 |
| lane gap | 20px |
| thread row height | 30px |
| max thread rows | 4 |
| label width | 78px |
| right pad | 12px |
| bottom pad | 8px |
| min plot width | 320px |
| min plot area | 40px |
| brush start | 4px horizontal |
| brush commit | 20ms range |
| playback travel | 14000ms full span |
| min zoom span | 300ms |

Ruler labels use a 1/2/5×10 step targeting `visible / 6`, 9.5px centered
labels, 1px grid, and 1px major/minor ticks. CPU labels are 10.5px at x=10;
busy percent is 9.5px at x=46. Thread labels are 10.5px at x=13, truncated to
10 characters, with a 2×12px lane swatch. `THREADS` is 8.5px with 1px letter
spacing.

## 8. Motion and focus

- Toast enter: 180ms ease-out, opacity 0 → 1, translateY 6px → 0; auto-hide
  after 3400ms.
- Playback is linear, not eased; loop at the view end.
- Zoom is immediate (no animation); `+`/`-` use 0.6/1.7 factors.
- Hover changes are immediate; there are no hover transitions.
- Focus: 2px outline, 2px offset, 2px radius; visible on keyboard focus only.
- `prefers-reduced-motion`: collapse animation/transition durations to 0.001ms
  and iterations to 1.

## 9. State and safety

- READY / DEGRADED / SKIP / REFUSE / CLEAR / WARNING / INFO / LIVE / VM keep
  their labels and glyphs; color is supplemental.
- Loss rows use `tint-refuse` plus a `■ LOSS` chip; gaps are explicit.
- Missing memory signals read `uncollected`, never `0`.
- Capture is read-only: the viewer may start/stop only its own read-only
  recorder, gated on a READY probe plus the Settings opt-in; external recorders
  are attach-only and the viewer never changes host policy.
- The native GPU picker accepts `.ndjson`, `.jsonl`, and `.json` paths; there is
  no OS file dialog and no web file input.
- The UI never writes `/proc` or `/sys`, never elevates, and sends no network
  request. All data is local replay data.
- Runtime samples never include argv, environment variables, secrets, or
  tokens.

## 10. Parity harness

Recommended capture set for every token change:

1. Graphite default at 1440×900 and 1280×720.
2. Each of the six palettes at 1440×900.
3. Overview, Timeline, Advisor, Events, Capture at 1440×900.
4. Timeline with a selected slice and a brushed window.
5. Advisor with a non-default filter and with an offline-journal SKIP card.
6. Events with a query, a type filter, and a selected loss row.
7. Command palette open, appearance open, help open.
8. Toast (info and error variants).
9. Responsive 1024, 780, and 420 widths.

For CPU rendering, compare framebuffer hashes exactly. For Metal/GL, compare
against the CPU reference using the thresholds in `ui-spec.json` (Metal/GL:
MAE ≤ 4.0, >24 ≤ 3%). CPU raster is canonical: committed stills are verified
by `./tools/zig build screenshots-check` in CI, while Metal/GL reference diffs
are advisory and not a CI gate.

## 11. Implementation checklist

- [x] Extend the GPU theme token model with `raised-2`, `field`, `dim`,
      `faint`, `line-strong`, tints, lanes, and focus. Generated six-palette
      source lives in `lib/xsui/src/design_palettes.zig`.
- [x] Add fractional font sizes and explicit line-height; glyph atlas sizes
      are fixed-point keys and composite glyphs are supported.
- [x] Add letter spacing, wrapping, ellipsis, and horizontal/vertical text
      anchoring in `xsui.Canvas`.
- [x] Precompute all derived color-mix values per palette.
- [x] Add absolute composition, column/row/grid/wrap helpers, max-width, and
      responsive 1280/1440 layouts. The current shell implements the 1280
      two-column and 1440 three-column states; the 1024 bottom-rail state is
      not yet pixel-verified.
- [x] Add line, dashed-line, inset fill, and rounded-rectangle primitives.
- [x] Add stage scroll offsets with clipping on wheel/scroll input.
- [ ] Add independent ledger/palette/appearance scroll containers; the stage
      currently scrolls as one clipped surface.
- [x] Add dialog backdrop compositing; focus return and full focus rings are
      partial.
- [x] Add explicit SKIP/REFUSE/loss fallbacks and live-vs-replay source labels.
- [x] Add snapshot fixtures for all screens, all six palettes, and overlays.
- [x] Replace platform text rasterization with the generated glyph mask atlas
      (`tools/gen_chromium_text_atlas.cjs`, checked-in binary asset) at the
      measured ¼ px x / ½ px y subpixel grid; TTF remains a documented fallback
      for unknown glyphs/phases.
- [x] Make CPU the canonical backend; native Metal/GL consume the same draw
      list and are smoke-tested with a hidden window (`qa/macos_smoke.sh`,
      `qa/xvfb_smoke.sh`), with reference diffs advisory.
- [x] Wire the 1320/1140/1024/780/420 shell, compact topbar, bottom rail,
      one-column Overview/Capture/Advisor, and stacked Events/Timeline.
- [x] Emit bounded clipboard requests; macOS uses NSPasteboard and X11 owns
      CLIPBOARD. Brush drag/zoom is wired natively.
- [x] Mobile ledger/thread rows, phone theme grid/stat sizes, focus
      traversal/trapping/return, skip-link focus, and X11 clipboard selection.
- [x] Native GPU open-journal and recorder-window picker; no OS file dialog.

The cross-surface report records actual pixel metrics and pass/fail against the
formal thresholds. Reference-progress is reported separately and is advisory.
