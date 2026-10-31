# Console evidence

This folder holds reproducible visual evidence for the GPU console. The
production surface is not a browser DOM mock: program screenshots and the video
are captured from the WebGL2 canvas running the same Zig app used by
`xsprof ui` and `xsprof snapshot`.

## Acceptance model

[`../ui-spec.json`](../ui-spec.json) is the formal contract. CPU is the
canonical rasterizer; Metal, OpenGL, and WebGL2 must consume the same draw list,
text atlas, and fractional geometry and match CPU within the spec tolerance.
The HTML prototype is the **design source**; reference/prototype pixel diffs are
advisory and are no longer a pass/fail criterion.

| Gate | Threshold |
|---|---|
| CPU vs WebGL2 | MAE ≤ 2.5, >24 channel-delta ≤ 3% |
| CPU vs Metal | MAE ≤ 4.0, >24 channel-delta ≤ 3% |
| CPU vs OpenGL | MAE ≤ 4.0, >24 channel-delta ≤ 3% |
| Reference prototype | advisory, no pixel gate |

`qa/ui_cross_surface.py` reads these thresholds from `design/ui-spec.json` and
fails the evidence run if any state misses them. `qa/ui_parity.py` still records
the reference diff so design drift stays visible.

## Artifacts

| Path | What it is |
|---|---|
| `screenshots/prototype/` | Headless Chromium captures of `design/index.html`; design reference |
| `screenshots/xsprof/` | WebGL2 console at 1440×900 with the prototype demo fixture |
| `screenshots/live/` | WebGL2 console reading the real replay journal and recorder manifest |
| `screenshots/native/` | 1280×720 CPU offscreen snapshots of the native layout |
| `screenshots/breakpoints/` | 1024/780/420 console and prototype captures |
| `screenshots/diff/` | Amplified advisory reference/program difference images |
| `parity.json` | Advisory reference metrics (MAE, >16, >24) |
| `cross_surface.json` | Formal CPU vs WebGL2 vs Metal gate report |
| `interactions.json` | Clipboard and brush interaction gate |
| `../media/xsprof-ui-demo.mp4` | Short headless boot/use recording (H.264) |

## Method

- **Text:** glyph masks are generated from the prototype's embedded font faces
  by headless Chromium (`tools/gen_chromium_text_atlas.cjs`) at the measured
  subpixel grid (¼ px x, ½ px y). The atlas is embedded and consumed by every
  backend, so platform fonts never participate. `ui_spec.zig` hashes the atlas
  against the formal spec.
- **CPU:** `xsprof snapshot` renders the canonical frame.
- **Metal:** `xsprof snapshot --backend metal` uses `MTKView`-independent
  offscreen Metal readback.
- **WebGL2:** `xsprof serve` on loopback with token-authenticated `/api/...`;
  headless Chromium screenshots the canvas. `?demo=1` is used only for the
  comparison fixture; live evidence uses the journal and `/api/recorder`.
- **Interactions:** `qa/ui_interactions.cjs` grants clipboard permission in
  headless Chromium, clicks a real command Copy button, verifies the exact
  clipboard text, then drags the timeline brush and verifies the visual
  band/zoom changed.
- No real window is opened, activated, or captured.

## Commands

```sh
./tools/zig build
./tools/zig build web
python3 design/validate.py
NODE_PATH="$HOME/.npm/_npx/e41f203b7505f1fb/node_modules" sh qa/ui_evidence.sh
```

`ui_evidence.sh` starts the loopback server, captures WebGL2 screenshots,
records the real-data video to MP4, writes the advisory reference report, then
renders CPU and Metal snapshots and runs the formal
`qa/ui_cross_surface.py` gate. Node, Playwright-core, ffmpeg, and Python 3 are
developer/evidence dependencies only.

Native layout evidence:

```sh
for view in overview timeline advisor events capture; do
  ./zig-out/bin/xsprof snapshot --replay fixtures/ui/healthy.ndjson \
    --recorder-dir fixtures/ui/design/recorder --view "$view" \
    --width 1280 --height 720 --out "design/screenshots/native/$view.png"
done
```

For a human-visible native recording, run `xsprof ui --replay <journal>` and
use OS screen recording. That path is deliberately outside automated work.

## Remaining work

The formal contract and cross-surface gate are green. The 1024/780/420 shell,
compact topbar, one-column Overview/Capture/Advisor modes, stacked
Events/Timeline, clipboard requests, and brush zoom are wired. Remaining
polish: mobile ledger/thread rows, the complete focus-return model, and native
Linux clipboard selection. The reference diff remains advisory.
