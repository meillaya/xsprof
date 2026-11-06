# Native showcase media

Committed video evidence for the native GPU console. Everything here is
rendered **headlessly** from the CPU rasterizer through `xsprof snapshot` (the
same draw list the macOS/Linux window consumes) and encoded with ffmpeg. No
real window is opened, activated, or captured; there is no x11grab, compositor
screencast, or display-server path.

| File | What it is |
|---|---|
| `xsprof-native-showcase.mp4` | 1280x720 H.264 tour: Home, onboarding, GPU picker, Overview, Timeline replay, Advisor, Events, Recorder, Audit, Settings, accessibility focus, export palette, real VM capture |
| `xsprof-native-showcase.gif` | 640-wide palette preview of the tour (README/issue-friendly) |
| `xsprof-native-showcase.provenance.json` | Canonical inputs, scene flags, frame hash, and output hashes for the tour |
| `xsprof-native-live-replay.mp4` | 1280x720 H.264 replay of the committed podman Linux-VM perf capture, marked REPLAY, host_mutation=false |
| `xsprof-native-live-replay.gif` | 640-wide palette preview of the live replay |
| `xsprof-native-live-replay.provenance.json` | Canonical provenance for the live replay |

The WebGL2-era videos were removed in 0.5.0 with the browser surface.

## Regenerate

```sh
./tools/zig build
tools/showcase.sh                 # deterministic render + encode into design/media
tools/showcase.sh --check         # verify committed artifacts + provenance only
tools/showcase.sh --smoke --out /tmp/showcase   # tiny pipeline/determinism check
tools/showcase.sh --frames-only --out /tmp/frames
tools/record_native_showcase.sh   # human-run convenience wrapper (still headless)
qa/showcase_smoke.sh              # gate: committed provenance + smoke determinism
```

Requirements: `zig-out/bin/xsprof`, `ffmpeg`/`ffprobe`, `python3`,
`sha256sum`, `awk`. The scripts SKIP cleanly with a reason when ffmpeg is
missing.

## Provenance schema

Each pair of outputs has a canonical (sorted keys, compact) JSON file with
`schema: "xsprof/media-provenance/v1"`:

- `renderer`: CPU backend, offscreen, `window: false`;
- `no_display_capture: true` and `host_mutation: false`;
- `frame`: width/height/fps/count and a sha256 over the ordered PNG frames;
- `scenes`: ids, start frames, frame counts, and captions;
- `inputs`: fixture paths plus sha256 (demo model, healthy capture, real
  `macos-vm-sched.ndjson`, recorder manifest fixture);
- `outputs`: mp4/gif path, bytes, sha256, codec, resolution, duration;
- `ffmpeg`: the exact encoder version string.

The live-replay video animates a bounded excerpt of the committed real capture
(`head -n 12000`) so regeneration stays fast; the excerpt is derived data from
the same sha256-pinned fixture and the video is labeled REPLAY. Full-capture
frames are still rendered for the overview stills.

## Honesty rules

- CPU snapshots are canonical; no Metal/GL window is needed for media.
- REPLAY is explicit; live capture is not simulated in these files.
- Every loss/refusal state renders through the same semantic gates as the app.
- Provenance is canonical JSON so `qa/showcase_smoke.sh` can verify it byte for
  byte and fail on drift.
