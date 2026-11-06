# Changelog

## Unreleased

### Fixed

- Recorder probe SKIP/REFUSE is no longer displayed as FAILED; the reason is
  shown with the capture permission requirement and the Recorder screen keeps
  in-app export/verify actions instead of shell snippets.
- Capture permission guidance added in docs/guides/capture-permissions.md
  (setcap, privileged daemon + follow-recorder, systemd service).

## 0.5.0 — 2026-11-06

### Removed

- The shipped browser surface: `xsprof serve`, the loopback HTTP/SSE bridge,
  `/api/*`, wasm32/WebGL2, `web/` assets, the web CLI/help/completions
  entries, `ui-session` schema, Playwright evidence scripts, and browser
  packaging installs.
- The standalone xsui package's WebGL2/wasm backend; CPU, Metal, and GL remain.
- `xsprof demo`'s browser fallback; it now opens the bundled capture in the
  native console and fails with a native-only reason when headless.
- `xsprof serve` fails closed as a removed 0.5.0 verb.

### Added

- A tested AppImage artifact (native binary, desktop/icon, fixtures, AppRun; no
  bundled X11/GL drivers; `--appimage-extract-and-run` smoke).
- Native offscreen showcase media covering Home/onboarding, live-capture
  replay, recorder, audit, replay, settings, picker, and accessibility, with
  canonical provenance and no real-window capture.
- KVM podman VM evidence for live/service/retention gates under
  `docs/evidence/v0.5.0-vm/`.

### Changed

- The design prototype is frozen non-runtime design input; native snapshots and
  native media replace browser screenshots/videos.
- Version 0.5.0 across manifest, runtime, tests, release workflow, and docs.

## 0.4.0 — 2026-11-06

### Added

- UI-first product console: Home, Recorder, Audit, and Settings routes plus
  first-run onboarding, GPU picker/text entry, settings/recents/audit
  persistence, and action/effect dispatch on native and web surfaces.
- Native live capture: Linux in-process compact recorder (cooperative stop,
  no signal-handler theft), recorder tail for live view, macOS/any-OS
  follow-recorder, bounded feed/index, 4 Hz model rebuild, stable selection
  remap, explicit sample/feed loss, and fail-closed READY/SKIP/REFUSE states.
- Native window resize and pointer work on macOS (AppKit/Metal) and Linux
  (X11/GLX), including size hints, ConfigureNotify, motion/drag/release,
  dirty ticking, and hidden resize smokes.
- Platform-neutral `xsprof/a11y-tree/v1` accessibility tree from the same
  draw/hit pass; web DOM/ARIA mirror and macOS NSAccessibility proxies. Linux
  emits canonical tree JSON and reports AT-SPI2 as DEGRADED with a reason.
- Compact raw segments (`.xsraw`, `xsprof/raw-segment/v1`): 64-byte header,
  CRC-32C 32 KiB blocks, footer clean-close proof, varint/zigzag records,
  block-local string tables, privacy-at-rest, streaming reader, bounded window
  loader, `verify`, and legacy NDJSON compatibility. The 2 GiB budget now
  covers the ten-minute age cap instead of about 94 seconds of canonical JSON.
- Bounded recorder-window sampling and `capture --markers-only`/
  `--max-events`/`--max-window-bytes`; `incident` refuses oversized windows
  rather than silently truncating.
- Simplified CLI: bare `xsprof` opens the console only on an interactive
  graphical TTY; visible help/completions are ui/record/top/why/incident/
  doctor; every automation verb remains a hidden working alias; `help --all`
  and `completions <shell> --all` list everything.
- Nix flake for Linux x86_64/aarch64 and macOS arm64/x86_64, hash-pinned Zig
  0.17.0, Linux runtime wrapper, Darwin SDK/sign hook, opt-in NixOS recorder
  module, checks, and devShell.
- Fail-closed macOS release tooling: notarization result capture, canonical
  `xsprof/macos-notarization/v1` attestation verifier, artifact/Gatekeeper/
  staple/arch checks, attestation-gated Homebrew cask, unsigned preview names,
  and local tap dry-run tests.
- Linux packaging polish: desktop entry/icon, sysusers, completions,
  reproducible tarball, hardened .deb fields/arch, layout and checksum gates.

### Changed

- Recorder raw segments are compact by default; `capture`, `incident`,
  `why`, and the UI still emit canonical `xsprof/event/v1` NDJSON.
- The design contract is v2 with eight routes and new overlays; the pinned
  prototype remains the visual source for the five analysis screens and the
  new routes are documented as the console extension.
- Settings are canonical `xsprof/ui-settings/v1`; audit is
  `xsprof/ui-audit/v1`; the accessibility tree is `xsprof/a11y-tree/v1`.
- The macOS file open panel is gone; native pickers are GPU-drawn.
- Version 0.4.0 across the package manifest, runtime, CLI parity, release
  workflow, and docs.
- Nix uses a second locked nixpkgs input for Intel macOS because current
  nixos-unstable dropped x86_64-darwin.

### Fixed

- The UI can no longer leak frame-arena labels into accessibility bridges.
- Event/slice row ids are no longer capped by the legacy 1000-1999 data range.
- Recorder restart after a stop queues the new capture effect instead of
  dropping the decision.
- Compact tails, corrupt/truncated blocks, rotation gaps, and retention drops
  are explicit markers/messages rather than corrupt rows or silent loss.
- Packaged `demo`/`doctor` locate web assets and fixtures through
  `XSPROF_WEB_DIR`/`XSPROF_FIXTURES_DIR` and standard share paths.
- Stale "native live hook not attached" and fixed-size-window documentation.

### Known limits

- Real Developer ID notarization, Gatekeeper acceptance, and public tap
  publication require external Apple/tap credentials; only fail-closed tooling
  and local dry-runs are in the repository.
- Linux AT-SPI2 screen-reader bridging is not built; tree JSON, keyboard focus,
  and a visible DEGRADED state are provided. macOS VoiceOver needs a human-run
  audit.
- 1x native rendering; Retina 2x crispness, X11 IME/paste parity, and web
  recorder control remain follow-ups.
- The root-only live/service/retention gates must be run in a disposable Linux
  VM with readable tracefs/CAP_PERFMON.

## 0.3.0 — 2026-11-06

### Added

- `xsprof top`: live, read-only ranked scheduler view with `--json`/`--once`.
- `xsprof why`: streaming root-cause report with wakeup-chain attribution.
- `xsprof report` alias, `completions bash|zsh|fish`, command help, quickstart.
- Wakeup-pair metrics, `out_of_order`, and split minor/major page faults.
- Incremental live web updates (`web_ui_append_journal`) that preserve the view.
- QA gates: unsafe-verb matrix, no-host-mutation scan, privacy scan, web UI
  smoke, version sync, and a root VM `live-smoke`.
- MIT LICENSE, CHANGELOG, SECURITY, quickstart/top-why guides, event semantics
  and audit documents.

### Changed

- Capture batches are timestamp-sorted; replay reports old skew.
- `record` streams to a timestamped file by default (`--output -` for stdout).
- `capture` streams and refuses overwrite unless `--force`.
- `incident` defaults to `./xsprof-incident-<timestamp>`; `--force` available.
- History sidecars use a 60 s interval and 24 h retention by default.
- `serve` prints the token in the URL fragment, validates the journal before
  binding, adds CSP/referrer/frame headers, and fails closed for `--live`
  without perf.
- `doctor` is human-readable by default; `--json` remains.
- Plain `zig build` installs web assets; `demo` works from a clean build.
- Release CI runs the full gate before publishing and uploads checksums.

### Fixed

- Duplicate loss markers.
- Whole-window buffering in one-shot record/capture.
- Uncleaned SIGTERM shutdown.
- Unbounded sidecars and silent sidecar failures.
- Manifest/sidecar path/schema/mutation validation.
- Live-dir partial-line and rotation-tail loss.
- Missing wasm wheel/pointer-leave exports.
- Event pid/comm display mismatch, CPU-ID overflow, and dead CPU busy code.
- Chrome Trace detail redaction and UI detail redaction.
