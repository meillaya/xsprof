# Native visual evidence

The browser/WebGL2 evidence lane was removed in 0.5.0. Evidence now comes from
the same native draw list that CPU, Metal, and GL consume:

- `design/screenshots/native/` — CPU snapshots of the native console routes;
- `design/screenshots/prototype/` — frozen reference captures of the design
  prototype (not built or served);
- `design/media/xsprof-native-showcase.*` and
  `design/media/xsprof-native-live-replay.*` — deterministic offscreen
  native showcase videos.

Method: `xsprof snapshot` renders frames with the CPU rasterizer; the showcase
renderer drives the same App/Canvas state; ffmpeg assembles the image sequence
into MP4/GIF. No window is opened, activated, captured, or given synthetic
input. The videos are explicitly offscreen renders, not real-window captures.

Provenance is recorded in `design/media/*.provenance.json` (source fixture,
commit, host_mutation=false, offscreen=true). Metal/GL parity is checked
separately by the native package and platform smokes; the browser is not a
target.

Regenerate with `sh qa/showcase_smoke.sh` (developer-only; needs ffmpeg).
