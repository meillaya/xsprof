# Product shell v2 (extension)

Status: **proposed extension**, approved for implementation. The five analysis
screens in [`index.html`](index.html) remain the design source and are unchanged
(ids 100-104, keys 1-5, in-screen hit ids). This document defines the UI-first
product shell around them; the prototype will be updated separately. The formal
contract is [`ui-spec.json`](ui-spec.json) v2, and `python3 design/validate.py`
gates this folder.

## Why

The product is the UI: every operator action must be discoverable and usable from
the GPU-rendered console. Startup/onboarding, source selection, management,
audit and settings are first-class routes, not command-line side effects.

## Routes

| route | rail id | key | contract |
|---|---|---|---|
| home | 105 | 0 | source cards (live/replay/recorder-window/demo), time-frame presets, capability strip, recorder strip, recents, onboarding CTA |
| overview..capture | 100-104 | 1-5 | unchanged analysis screens; capture is shown as "Recorder" and gains start/stop/restart/extract/export controls |
| audit | 106 | 6 | session/manifest provenance, lifecycle markers, retention, capability gates, bounded UI action log |
| settings | 107 | 7, Cmd/Ctrl+, | appearance, accessibility, capture defaults, storage/retention, diagnostics, about/reset |

Overlays: palette, appearance, help, toast (existing) plus **picker**, **confirm**
and **onboarding**. The hidden web file input stays a utility, never a visible
surface.

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
- Surfaces drain `App.takeEffect()` and execute or fail closed with a stable
  `surface.*` reason. `effect.zig` defines the capability matrix.
- Host completions call `App.recorderStarted/Stopped/Failed`,
  `App.noteSourceFailure`, `App.loadRecorderWindow`, `App.applySettingsJson`.
- Unsupported actions never mutate state: web recorder control, host directory
  browsing, host-path extraction and host file export are refused with reasons.

## Persistence and audit

- Settings: `xsprof/ui-settings/v1`, canonical compact JSON, written by the
  surface (Linux `$XDG_STATE_HOME/xsprof/ui-settings.json`, macOS
  `~/Library/Application Support/xsprof/ui-settings.json`, web localStorage).
  Corrupt/unknown input resets to defaults with a reason. Snapshots ignore
  user settings for determinism.
- Recents: bounded 10 inside settings, deduplicated by kind/path; basenames are
  shown in UI/a11y, full paths stay local and are never exported.
- Audit: 64-entry in-memory ring plus native append-only `audit.ndjson`
  (rotate 1 MiB): `{schema:"xsprof/ui-audit/v1",seq,wall_ms,action,outcome,code,source,host_mutation:false}`.
  Web keeps the ring in memory.

## Accessibility

`src/app/design/a11y.zig` builds a platform-neutral node tree from Canvas hits
(role, label, value, selected/disabled, focusability) and serializes canonical
`xsprof/a11y-tree/v1` JSON. Web mirrors it into a hidden DOM/ARIA tree; macOS
bridges to NSAccessibility; Linux reports an explicit AT-SPI SKIP reason. Every
focusable node must have a label (tested). TODO(native-runtime): adopt
`Canvas.node()`/`Hit.data` once xsui exposes them.

## Fail-closed matrix

| action | native Linux | macOS | web | snapshot |
|---|---|---|---|---|
| load file / list dir | yes | yes | upload only / no | no |
| live capture | READY-gated | SKIP | no (viewer) | no |
| recorder control | READY + Settings opt-in | SKIP | REFUSED | no |
| settings persist | file | file | localStorage | no |
| a11y tree | JSON | NSAccessibility | DOM/ARIA | JSON |
| host export | yes | yes | refused | PNG only |

## Integration hooks (owned outside this folder)

- `src/platform/*`: drain `App.takeEffect()`: load path/demo/list_dir,
  start/stop capture, extract window, export, save settings, append audit,
  open journal, reload. Use workspace `src/capture/lab_worker.zig` +
  `src/stream/live_feed.zig` for the in-process capture (no child processes).
- `src/web_console.zig` + `web/*.js`: export effects/settings/a11y; keep the
  read-only server (no POST control endpoint).
- `src/cli/render.zig`: snapshot flags for home/audit/settings, overlays and
  `--a11y` JSON; snapshots must not read user settings.
