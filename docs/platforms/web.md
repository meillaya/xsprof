# Web surface (removed in 0.5.0)

The browser/WASM/WebGL2 lane is **not shipped**. 0.5.0 removed the web runtime
and its serving bridge; the native GPU console (macOS, Linux) and the headless
`snapshot` renderer are the only product surfaces.

## What was removed

- `xsprof serve` and the loopback HTTP/SSE bridge, including `/api/meta`,
  `/api/journal`, `/api/recorder`, `/api/events`, and `/api/window`.
- The wasm32 build, WebGL2 renderer, browser assets, and the `web_smoke` /
  `web_ui_smoke` / `web_lab_smoke` QA gates.
- The `xsprof/ui-session/v1` schema, web-asset checks in `doctor`, and the
  `XSPROF_WEB_DIR` packaged-runtime override.
- `xsprof demo` no longer starts a loopback server: it opens the bundled
  capture in the native console and fails with an explicit reason when no
  display is available.

The design prototype under `design/` remains design input for the native
console and is not runtime code.

## Headless and automated use

Automated work never opens a window:

```sh
xsprof snapshot --replay capture.ndjson --out frame.png
xsprof snapshot --demo-model fixtures/ui/design/demo.json --view home --a11y tree.json
xsprof capture --last 5m --dir /var/lib/xsprof --out window.ndjson
xsprof verify --dir /var/lib/xsprof --json
```

The native console makes no external requests and sends no telemetry; there is
no network listener, no token, and no browser asset lane to configure.
