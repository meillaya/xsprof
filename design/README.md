# xsprof UI/UX design tokens

This folder is the frozen design-side contract for the optional native viewer.
The prototype [`index.html`](index.html) is design input only: it is never built
or served, and the viewer is not allowed to grow new routes/palettes without an
explicit product decision. The token set, screens, flows, keybindings, and GPU
mapping here are what the existing eight-route viewer implements.

- Source: `design/index.html` (this folder)
- Source sha256: `0823328b3261b89ce2d8c2af53ebc61adfedd49f19706239e437b7fdb6a3de62`
- Source size: 221,754 bytes
- Token set version: `1.0.0`
- Reference viewports: frozen prototype `1440x900 @1` (design input only),
  native `1280x720 @1`
- Status: implemented by the optional viewer (`src/app/design/`,
  `lib/xsui/src/canvas.zig`). The formal runtime contract is
  [`ui-spec.json`](ui-spec.json). CPU raster is canonical; Metal/GL are smoke
  tested (hidden window) and reference diffs are advisory, not a CI gate.
- Committed stills: four offscreen CPU snapshots —
  [`dark/home.png`](screenshots/native/dark/home.png),
  [`light/home.png`](screenshots/native/light/home.png),
  [`dark/overview.png`](screenshots/native/dark/overview.png),
  [`light/overview.png`](screenshots/native/light/overview.png) — with canonical
  [`provenance.json`](screenshots/native/provenance.json). Regenerate with
  `sh tools/screenshots.sh`; verify committed bytes with
  `./tools/zig build screenshots-check`. Stills render the committed real
  capture prefix; they are never window captures.

## Files

| File | Contents |
|---|---|
| [`ui-spec.json`](ui-spec.json) | canonical runtime contract: draw list, text atlas/hash, palettes, breakpoints, shell, components, interactions |
| [`tokens.json`](tokens.json) | canonical shared tokens: meta, typography, spacing, radii, borders, focus, layout, components, motion, GPU ABI |
| [`palettes.json`](palettes.json) | canonical color source: six palettes, semantic roles, state contract, color-mix recipes, per-theme derived colors |
| [`tokens.css`](tokens.css) | generated CSS custom properties for Graphite, Paper, and four Catppuccin flavours |
| [`screens.json`](screens.json) | shell, eight routes, overlays, regions, content contracts, states, responsive behavior |
| [`flows.json`](flows.json) | lifecycle, navigation, overlays, journal, timeline, advisor, events, capture, feedback, responsive flows |
| [`keybindings.json`](keybindings.json) | global, dialog, palette, rail, timeline-pointer, and native-port key/gesture maps |
| [`command-palette.json`](command-palette.json) | palette commands, appearance options, help sheet, grouping and search rules |
| [`product-shell.md`](product-shell.md) | product shell contract: routes, overlays, hit-id policy, persistence/audit/a11y, fail-closed matrix, integration hooks |
| [`gpu-mapping.md`](gpu-mapping.md) | token-to-instance mapping, color/text/layout requirements, parity notes, known gaps |
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
`colorMixRecipes` are the canonical form; derived hex values are convenience
values rounded from the same recipe.

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
keyboard help, onboarding, GPU picker, confirm, toast. The native GPU picker is
the only source-picker surface.

`design/index.html` is responsive at 1320, 1140, 1024, 780, and 420 CSS px. The
1024px breakpoint turns the rail into a bottom bar and hides the keybar. The
native viewer implements the 1280 two-column and 1440 three-column states; the
1024 bottom-rail state is not pixel-verified.

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
./tools/zig build design-check     # runs: python3 design/validate.py
sh tools/screenshots.sh --check    # committed stills + provenance (also in check-ci)
```

The validator checks that the source hash in the JSON matches `design/index.html`,
every JSON parses, all six palettes expose the same 33 color tokens, the CSS
export matches each palette token, and the screens/flows are present. It prints
`design: PASS` on success.

## Updating

1. Change the prototype first (`design/index.html`).
2. Re-extract palettes and CSS, or update the JSON/CSS by hand for non-color
   changes.
3. Update `meta.sourceSha256` / `sourceBytes` in `palettes.json`,
   `tokens.json`, `screens.json`, `flows.json`, `keybindings.json`, and
   `command-palette.json`.
4. Run `python3 design/validate.py`.
5. Update `gpu-mapping.md` if the change affects ABI, text, layout, or parity.
6. Regenerate the four committed stills and provenance (`sh tools/screenshots.sh`).

Do not add a token that only exists in this folder but not in the prototype
without marking it as a proposed extension. The design folder describes the
desired UI; it is not a second source of truth for behavior.

## Relationship to `lib/xsui`

The GPU UI package lives in [`lib/xsui`](../lib/xsui/README.md). This folder is
design input for that package: palette maps are generated into
`lib/xsui/src/design_palettes.zig` by `tools/gen_design_tokens.py`, component
metrics are encoded in `src/app/design/`, and `gpu-mapping.md` tracks renderer
mapping. There is no WebGL/WASM backend and no browser target; `lib/xsui` is
native-only (CPU, Metal, GL).
