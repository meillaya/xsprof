# Console evidence

This folder holds the reproducible visual evidence for the GPU console. The
production surface is not a browser DOM mock: the program screenshots and
video are captured from the WebGL2 canvas running the same Zig app used by
`xsprof ui` and `xsprof snapshot`.

## Artifacts

| Path | What it is |
|---|---|
| `design/screenshots/prototype/` | Headless Chromium captures of `design/index.html`; the visual reference |
| `design/screenshots/xsprof/` | The GPU console at 1440×900 with the prototype demo fixture, same viewport/content for comparison |
| `design/screenshots/live/` | The GPU console at 1440×900 reading the real replay journal and recorder manifest (no demo fixture) |
| `design/screenshots/native/` | 1280×720 CPU offscreen snapshots of the native layout |
| `design/screenshots/diff/` | Amplified reference/program difference images |
| `design/evidence/parity.json` | Mean channel error and >16/>24 channel-delta percentages |
| `design/media/xsprof-ui-demo.mp4` | Short headless boot/use recording of the real console (H.264) |

## Method

- Reference: `file://…/design/index.html` in headless Chromium at 1440×900,
  DPR 1. Screens, all six themes, palette/appearance/help overlays.
- Program: `xsprof serve` on loopback, token-authenticated, with
  `zig-out/web` assets. Screenshots use `?demo=1` only for the prototype
  content comparison; the live folder and video use `fixtures/ui/healthy.ndjson`
  plus `fixtures/ui/design/recorder/manifest.json` through the real
  `/api/journal` and `/api/recorder` routes.
- No real window is opened, activated, or captured. Chromium runs headless;
  the native folder is produced by the CPU offscreen snapshot path.
- `qa/ui_parity.py` decodes both PNGs to raw RGB with ffmpeg. It reports the
  mean absolute maximum-channel error and the fraction of pixels whose maximum
  channel delta is over 16 and 24.

## Current parity

The structural contract is implemented: tokens, palettes, shell geometry,
screens, overlays, clipping, hit targets, and responsive 1280/1440 layouts.
The reference and program share content only in the `xsprof/` set; the live
set intentionally shows different values.

The color and geometry checks pass at the token level. The pixel report is
**not at the original target** (MAE ≤2, >24 ≤3%). Text antialiasing is the
dominant residual: Chromium shapes/hints glyphs with its own rasterizer while
xsui uses a staged TrueType coverage rasterizer. The report records the actual
numbers rather than hiding them. The difference images make the residual
visible; non-text surfaces, borders, and palette colors should be compared
with the token tests and the unamplified screenshots.

## Commands

```sh
./tools/zig build
./tools/zig build web
NODE_PATH="$HOME/.npm/_npx/e41f203b7505f1fb/node_modules" sh qa/ui_evidence.sh
```

`qa/ui_evidence.sh` starts a token-protected loopback server, captures the
reference-equivalent console states, records the real-data video, converts it
to MP4, and writes the parity report. It requires Node, Playwright-core with
Chromium, ffmpeg, and Python 3; none are runtime dependencies of xsprof.

Native offscreen layout evidence:

```sh
for view in overview timeline advisor events capture; do
  ./zig-out/bin/xsprof snapshot --replay fixtures/ui/healthy.ndjson \
    --recorder-dir fixtures/ui/design/recorder --view "$view" \
    --width 1280 --height 720 --out "design/screenshots/native/$view.png"
done
```

For a human-visible native recording, run `xsprof ui --replay <journal>` and
use OS screen recording. That path is deliberately outside automated work.
