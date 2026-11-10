# Native visual evidence

The browser/WebGL2 evidence lane was removed in 0.5.0. Evidence now comes from
the same native draw list that CPU, Metal, and GL consume. Every artifact here
is rendered offscreen: no window is opened, activated, captured, or given
synthetic input, and no host policy is read or written
(`host_mutation=false`).

## Committed screenshots (light and dark)

`design/screenshots/native/` holds 1280x720 CPU snapshots of the eight console
routes in both core themes:

| Directory | Theme | Snapshot theme id |
|---|---|---|
| `dark/` | Graphite | `--theme dark` |
| `light/` | Paper | `--theme paper` |

Each directory contains `home.png`, `overview.png`, `timeline.png`,
`advisor.png`, `events.png`, `recorder.png`, `audit.png`, and `settings.png`.
The scene flags follow `tools/showcase.sh`'s `render_showcase_frames()` (the
timeline still is sampled at a 6.0 s playhead from the scene it animates from
0.5 s to 12.0 s):

| Route | Source | Scene flags |
|---|---|---|
| `home` | design demo model | `--demo-model fixtures/ui/design/demo.json --view home` |
| `overview` | healthy scheduler replay | `--replay fixtures/ui/healthy.ndjson --view overview` |
| `timeline` | healthy scheduler replay | `--replay fixtures/ui/healthy.ndjson --view timeline --playhead 6.0` |
| `advisor` | healthy scheduler replay | `--replay fixtures/ui/healthy.ndjson --view advisor` |
| `events` | healthy scheduler replay | `--replay fixtures/ui/healthy.ndjson --view events` |
| `recorder` | healthy replay + recorder manifest | `--replay fixtures/ui/healthy.ndjson --recorder-dir fixtures/ui/design/recorder --view capture` |
| `audit` | healthy scheduler replay | `--replay fixtures/ui/healthy.ndjson --view audit` |
| `settings` | design demo model | `--demo-model fixtures/ui/design/demo.json --view settings` |

The real VM capture (`fixtures/real/macos-vm-sched.ndjson`) drives the live
replay videos and the real-capture stances documented in `fixtures/real/`; it
is not used for these stills because its long session meta host/kernel string
overflows the fixed-width topbar chips.

## Provenance

`design/screenshots/native/provenance.json` is canonical JSON (sorted keys,
compact separators, trailing newline) with schema
`xsprof/screenshot-provenance/v1`:

- `host_mutation: false` and an offscreen CPU renderer record
  (`backend: "cpu"`, `offscreen: true`, `window: false`,
  `display_capture: false`, 1280x720);
- every input fixture with its sha256;
- one entry per PNG with theme, view, scene flags, sha256, byte size, and
  width/height;
- the compression command and the ImageMagick version used.

Raw snapshots are ~3.7 MB RGBA PNGs; they are compressed with
`magick FILE -strip -define png:compression-level=9 OUT` down to roughly
90-100 KB each. Do not hand-edit the committed PNGs: regenerate and let the
provenance change with them.

## Regenerate and verify

From the repository root (after `./tools/zig build`):

```sh
tools/screenshots.sh              # render both themes, compress, rewrite provenance
tools/screenshots.sh --check      # verify committed bytes/sha256/dimensions only
```

`--check` needs only `python3` (no ImageMagick, no renderer binary, no display
server): it re-hashes every committed PNG, compares byte sizes, reads the
1280x720 IHDR dimensions, and proves the provenance is canonical JSON.
`tools/screenshots.sh --out DIR` renders into a scratch directory, and
`XSPROF_BIN=/path/to/xsprof` selects a different binary. Rendering is
deterministic: two independent runs produce byte-identical PNGs and an
identical provenance file.

## Showcase media

- `design/screenshots/prototype/` — frozen reference captures of the design
  prototype (not built or served);
- `design/media/xsprof-native-showcase.*` and
  `design/media/xsprof-native-live-replay.*` — deterministic offscreen native
  showcase videos (MP4/GIF).

The showcase renderer drives the same App/Canvas state and ffmpeg assembles the
image sequence; no window is opened, activated, captured, or given synthetic
input. Provenance is recorded in `design/media/*.provenance.json` (source
fixtures, frame hashes, host_mutation=false, offscreen renders). Metal/GL parity
is checked separately by the native package and platform smokes; the browser is
not a target.

Regenerate the videos with `sh qa/showcase_smoke.sh` (developer-only; needs
ffmpeg). Regenerate the light/dark stills with `tools/screenshots.sh`.
