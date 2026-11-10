# Product shell v2 (extension)

Status: **proposed extension**, approved for implementation. The five analysis
screens in [`index.html`](index.html) remain the frozen design input and are
unchanged (ids 100-104, keys 1-5, in-screen hit ids). This document defines the
UI-first product shell around them; the prototype will not be updated. The formal
contract is [`ui-spec.json`](ui-spec.json) v2, and `python3 design/validate.py`
gates this folder. There is no browser/WASM/WebGL2 lane: every runtime surface
here is native (macOS AppKit/Metal viewer, Linux X11/GL viewer, CPU snapshot).
The viewer is optional and frozen; the recorder and CLI are the product.

## Why

The viewer must stay a discoverable consumer of the same evidence: startup/
onboarding, source selection, management, audit and settings are routes, not
hidden shell steps. Every route must remain reproducible from the CLI and from
`snapshot`, so the viewer is never the only way to see a state.

## Routes

| route | rail id | key | contract |
|---|---|---|---|
| home | 105 | 0 | source cards (live/replay/recorder-window/demo), time-frame presets, capability strip, recorder strip, recents, onboarding CTA |
| overview..capture | 100-104 | 1-5 | unchanged analysis screens; capture is shown as "Recorder" and gains start/stop/restart/extract/export controls |
| audit | 106 | 6 | session/manifest provenance, lifecycle markers, retention, capability gates, bounded UI action log |
| settings | 107 | 7, Cmd/Ctrl+, | appearance, accessibility, capture defaults, storage/retention, diagnostics, about/reset |

Overlays: palette, appearance, help, toast (existing) plus **picker**, **confirm**
and **onboarding**. The native GPU picker is the only source-picker surface; no
hidden file-input utility is shipped.

## Hit ids

Ids <1000 are frozen. 1000-2999 stay the slice/data range (implementation uses
`Hit.data` where xsui exposes it; see TODO in `src/app/design/a11y.zig`). All new
controls use >=3000: 3000-3099 home, 3100-3199 recents, 3150-3153 onboarding,
3200-3299 recorder/confirm, 3300-3399 audit, 3400-3499 settings, 3500-3599 picker,
3600-3699 text fields, 3700-3799 dialogs, 3800-3899 shell extras. The authoritative
catalogue is [`src/app/design/hits.zig`](../src/app/design/hits.zig); its test
enforces non-overlap. Palette rows are modal (700-739), so legacy theme option ids
720-725 are only live inside the appearance dialog.

## Architecture

- `src/app/design/app.zig` owns the model, arena, state, effect queue and source
  loading. Keys/clicks delegate to `input.zig` / `click.zig`.
- `action.zig` is the only input vocabulary; `dispatch.zig` +
  `dispatch_source.zig` are pure reducers returning bounded `effect.Batch`.
- Native surfaces drain `App.takeEffect()` and execute or fail closed with a
  stable `surface.*` reason. `effect.zig` defines the capability matrix for
  `snapshot`, `macos` and `linux`; there is no web surface.
- Host completions call `App.recorderStarted/Stopped/Failed`,
  `App.noteSourceFailure`, `App.loadRecorderWindow`, `App.applySettingsJson`.
- Unsupported actions never mutate state: recorder control, directory browsing,
  host-path extraction and host file export are refused with stable reasons on
  surfaces that cannot perform them (e.g. `snapshot`).

## Persistence and audit

- Settings: `xsprof/ui-settings/v1`, canonical compact JSON, written by the
  native surface (Linux `$XDG_STATE_HOME/xsprof/ui-settings.json`, macOS
  `~/Library/Application Support/xsprof/ui-settings.json`). Corrupt/unknown
  input resets to defaults with a reason. Snapshots ignore user settings for
  determinism.
- Recents: bounded 10 inside settings, deduplicated by kind/path; basenames are
  shown in UI/a11y, full paths stay local and are never exported.
- Audit: 64-entry in-memory ring plus native append-only `audit.ndjson`
  (rotate 1 MiB): `{schema:"xsprof/ui-audit/v1",seq,wall_ms,action,outcome,code,source,host_mutation:false}`.

## Accessibility

`src/app/design/a11y.zig` builds a platform-neutral node tree from Canvas hits
(role, label, value, selected/disabled, focusability) and serializes canonical
`xsprof/a11y-tree/v1` JSON for tests, snapshots and native bridges. macOS bridges
it to NSAccessibility; Linux reports an explicit AT-SPI SKIP reason and ships the
JSON dump. Every focusable node must have a label (tested).
TODO(native-runtime): adopt `Canvas.node()`/`Hit.data` once xsui exposes them.

## Fail-closed matrix

| action | native Linux | macOS | snapshot |
|---|---|---|---|
| load file / list dir | yes | yes | no |
| live capture | READY-gated | SKIP | no |
| recorder control | READY + Settings opt-in | SKIP | no |
| settings persist | file | file | no |
| a11y tree | canonical JSON | NSAccessibility | JSON |
| host export | yes | yes | PNG only |

## Integration hooks (owned outside this folder)

- `src/platform/*`: drain `App.takeEffect()`: load path/demo/list_dir,
  start/stop capture, extract window, export, save settings, append audit,
  open journal, reload. Use `src/recorder/daemon.zig` +
  `src/stream/live_feed.zig` for the in-process capture (no child processes).
- `src/cli/render.zig`: snapshot flags for home/audit/settings, overlays and
  `--a11y` JSON; snapshots must not read user settings.
- No `web/`, serve, WebGL2, WASM, or network lane is part of the runtime
  contract. macOS is viewer-only; Linux owns capture.
