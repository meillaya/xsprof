# Native showcase renderer

`tools/showcase.sh` renders the committed native showcase media. It is a
headless renderer: each frame is a deterministic `xsprof snapshot` (CPU
rasterizer on the same draw list as the native macOS/Linux console), then
ffmpeg assembles H.264 MP4 and palette GIF outputs. There is no window,
no display capture, and no x11grab path in the pipeline.

## Pipeline

1. `tools/showcase.sh` builds a numbered PNG sequence in a temp directory
   using scene commands such as:
   - `snapshot --demo-model fixtures/ui/design/demo.json --view home`
   - `snapshot --... --overlay onboarding --onboarding-step N`
   - `snapshot --... --overlay picker --picker-dir fixtures/ui/design`
   - `snapshot --replay fixtures/ui/healthy.ndjson --view timeline --playhead T`
   - `snapshot --replay fixtures/real/macos-vm-sched.ndjson --view overview`
   - `snapshot --... --view settings --focus 3412` (accessibility focus ring)
   - `snapshot --... --palette-query export` (export command palette)
2. Stills are held by hard-linking one rendered PNG (`ln`), so deterministic
   hold frames cost no extra rendering or disk.
3. `ffmpeg` applies per-scene drawtext captions and a persistent
   `NATIVE - OFFSCREEN CPU RENDER` watermark, then encodes H.264
   (`-pix_fmt yuv420p -movflags +faststart`) and a 640-wide palette GIF.
4. A canonical `*.provenance.json` records the scene list, input sha256s,
   frame hash, output hashes, and encoder version.

## Determinism

`snapshot` uses fixed `--now` values and no user settings; PNG output and the
frame hash are reproducible. `qa/showcase_smoke.sh` renders the smoke scene
twice and fails if `frame.sha256` differs, then verifies the committed
provenance and output hashes with `tools/showcase.sh --check`.

## Committed media

- `design/media/xsprof-native-showcase.{mp4,gif}` + provenance
- `design/media/xsprof-native-live-replay.{mp4,gif}` + provenance

The live-replay file animates a bounded excerpt of
`fixtures/real/macos-vm-sched.ndjson` (labeled REPLAY,
`host_mutation=false`); full-capture frames are used for the overview stills.
`design/media/README.md` is the artifact catalogue.

## Commands

```sh
./tools/zig build
tools/showcase.sh --check
tools/showcase.sh --smoke --out /tmp/showcase-smoke
tools/showcase.sh                       # regenerate design/media
tools/record_native_showcase.sh         # human-run wrapper (headless)
sh qa/showcase_smoke.sh
```

The human-run wrapper refuses to regenerate media in CI unless `FORCE=1`.
