# UI screenshots

## Native console evidence (light and dark)

Committed native evidence lives in
[`design/screenshots/native/`](../../design/screenshots/native/): 1280x720 CPU
snapshots of the eight console routes in both core themes.

- `dark/` — Graphite (`--theme dark`)
- `light/` — Paper, the light core preset (`--theme paper`)
- `provenance.json` — canonical `xsprof/screenshot-provenance/v1` manifest with
  input fixture hashes, per-file scene flags/sha256/byte size/dimensions, and
  the compression command/version.

Each theme directory contains `home`, `overview`, `timeline`, `advisor`,
`events`, `recorder`, `audit`, and `settings` PNGs. They come from
`xsprof snapshot`, which renders the same draw list as the native macOS/Linux
window with the CPU rasterizer. No window is opened, activated, or captured and
no synthetic input is used: every still is an offscreen CPU snapshot.

The `overview` stills render the committed real VM capture
(`fixtures/real/macos-vm-sched.ndjson`), so they cover the real-capture session
identity and metadata; its long host/kernel/arch string is truncated with a
trailing `…` at 1280 px so the right-aligned source/loss/safety chips stay
readable. The other routes render the healthy scheduler replay or the design
demo model. Provenance records all four inputs with sha256 hashes.

Regenerate both themes and rewrite provenance with:

```sh
./tools/zig build                 # once, produces zig-out/bin/xsprof
./tools/screenshots.sh            # render + compress + provenance
./tools/screenshots.sh --check    # verify committed bytes/sha256/dimensions
```

`--check` needs only `python3`; it does not invoke the renderer or ImageMagick.
To render a single frame by hand (raw snapshots are ~3.7 MB; compress them
before use):

```sh
./zig-out/bin/xsprof snapshot --demo-model fixtures/ui/design/demo.json \
  --view home --theme dark --width 1280 --height 720 --out /tmp/xsprof-home-dark.png
magick /tmp/xsprof-home-dark.png -strip -define png:compression-level=9 \
  design/screenshots/native/dark/home.png
```

See [`design/evidence/README.md`](../../design/evidence/README.md) for the
method, exact scene flags, provenance schema, and determinism notes.

## Historical checkpoints

`p2-gallery.png` is the P2 layout checkpoint from the same `src/app/gallery.zig`
view that owns the golden framebuffer hash. It exercises the flex layout,
reusable panels/chips/stat cards, custom chart paint nodes, the bundled
JetBrains Mono rasterizer, semantic status colors, and dense operator layout.

`p6-linux.png` is a native X11/OpenGL frame rendered under Xvfb from the
healthy replay fixture (no browser, no window manager).

The browser/WebGL2 screenshots (`p3-web-*`, `p4-live-web.png`) were removed in
0.5.0 with the Web surface. Native screenshot evidence is under
`design/screenshots/native/`; native offscreen showcase videos are under
`design/media/`. The frozen design prototype captures remain under
`design/screenshots/prototype/` as design input only.
