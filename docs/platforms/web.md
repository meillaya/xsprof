# Web frontend

The P3 web surface is a **read-only replay client**:

- `xsprof serve --journal <file> --assets-dir zig-out/web --port 8787`
- Prints a loopback URL with a random token.
- GET/HEAD only. `/api/meta` and `/api/journal` require the token; POST and
  every other method return 405. There is no mutation endpoint.
- The browser fetches the NDJSON journal, passes it into a
  `wasm32-freestanding` build, and asks Zig for a flat UI instance buffer plus
  the R8 glyph atlas.
- `web/gl.js` uploads that buffer once per frame and draws one instanced
  `TRIANGLE_STRIP` call in WebGL2. There is no JS UI framework, no external
  font/CDN, and no telemetry.
- `serve --live` keeps one perf capture open for the process lifetime. It
  exposes one-shot SSE batches with `Last-Event-ID` resume; `--live-stride`
  controls UI downsampling while loss markers report dropped events. Raw
  recorder segments remain the full-fidelity path.
- The browser appends only new NDJSON lines through a stable block store and
  an incremental session index; it no longer reparses the full journal.
- `?screen=0..4` selects Overview/Timeline/Advisor/Events/Capture;
- `p` pauses live updates, `f` toggles follow-tail, `o` opens a local
  `.ndjson`/`.jsonl`/`.json` capture, and `0` resets the timeline window;
- drag/drop a capture anywhere on the page to load it locally; nothing is
  uploaded;
  `?theme=light` selects the paper theme; `1..5` switches screens.
- `/api/meta` is `xsprof/ui-session/v1` with `host_mutation=false` and an event
  count.

## Security boundary

- `serve` refuses any address other than `127.0.0.1`/`::1`.
- Static assets are an explicit whitelist; no path traversal.
- API responses are `no-store`; the UI shell has no inline script or external
  origin.
- Assets must be built first: `./tools/zig build web`.
- If WebGL2 is unavailable, the page shows an explicit error instead of
  silently falling back to a fake renderer.

## Verification

```sh
./tools/zig build web
./tools/zig build web-smoke
```

`web_smoke` starts a loopback server, checks index/wasm/token behavior, rejects
POST, and verifies `host_mutation=false` in `/api/meta`. A Playwright headless
Chromium screenshot is the visual check used during P3; it is optional tooling,
not a build dependency.
