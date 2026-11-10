# Changelog

## 0.6.0 — 2026-11-10

Brownfield repositioning to a trust-first Linux scheduler flight recorder with
an optional, frozen native viewer. This release is prepared but not yet tagged:
the root/VM gates and CI/release lanes must run before a tag is cut.

### Changed

- The product surface is the recorder and its evidence tooling. The lab lane,
  legacy 5-screen UI, view-only live fallback, microVM verification lane,
  devenv, Homebrew/notarization tooling, and macOS release artifacts are
  removed. macOS remains a Nix-built viewer only.
- Tracked tree dieted from ~59.9 MB to ~11 MB: no vendored stdlib corpus,
  committed evidence/media/prototype screenshots, or oversized captures. Real
  captures are deterministic prefixes; the full capture is a release asset.
- LIVE view no longer round-trips through canonical NDJSON: compact segments
  decode directly into bounded event batches (no per-event serialize/parse).
- Retention is planned purely and applied; delete failures emit one
  `retention_loss` marker and retry. Startup reconciles `segments/` with the
  manifest (orphan adoption) and fsyncs the state directory. `verify`
  cross-checks footer counts (`footer_mismatch` => REFUSE).
- Capability probes report real per-collector coverage: READY only when every
  declared collector is up, otherwise DEGRADED with exact reasons. Capture
  summary carries optional `rings`/`reason`.
- One loss registry (10 kinds) replaces substring accounting; metrics, session,
  index, and incident counts include every kind (`loss_by_kind` additive wire).
- Manifest/CLI: one command registry drives dispatch/help/completions and a
  committed `packaging/cli-manifest.json`; exit codes are an enum; state dirs
  are resolved from an injected environment and honor `XSPROF_STATE_DIR` for
  every verb.
- Wire: canonical JSON schemas stay the source of truth; a bounded validator
  and 21k-document conformance registry run in `check`; `xsprof validate`
  validates one document or an NDJSON stream. Five schemas gained optional
  fields; no required-field or byte-stability changes.
- Viewer: accessibility is registered while painting and serialized by one
  bounded tree/writer across snapshot, Linux JSON and the macOS bridge; idle
  windows block on events instead of polling; the 16 MiB glyph atlas is lazy;
  screenshots re-render byte-identically in the gate; GL/CPU parity runs under
  Xvfb fail-closed.
- Gates are tiered: fast `check` (no display/Python/root), strict `check-ci`
  (no silent SKIPs), `check-media` (screenshot re-render), `check-vm` (root
  live/service/retention). CI covers Linux x86_64/aarch64 and macOS; the
  release workflow is tag-first and attaches its check-ci log + provenance.

### Fixed

- Live store could grow `pending` without bound after a full/corrupt feed and
  keep a stale LIVE state; ingest now latches one DEGRADED reason, emits one
  loss marker, and stops the source.
- `fixtures/ui/healthy.ndjson` rows missing canonical `"c"` were corrected;
  schemas/`$id`s are canonical and schema-conformance is enforced.
- `metrics` accepts its documented `--json` flag.
- Retention delete failures no longer silently stop trimming; crash orphANS
  are adopted instead of becoming invisible; state-dir rename is fsynced.

## 0.5.1 — 2026-11-10

### Added

- A disposable microvm.nix verification lane: `nix run .#xsprof-microvm-tcg`
  (or `sh qa/microvm_verify.sh`) boots a throwaway NixOS guest that smoke-checks
  the Nix-packaged binary — version/help, canonical-JSON
  doctor/capabilities/preflight, byte-identical CPU snapshots, the
  accessibility tree, and `xsprof lab` — and prints strict PASS/FAIL markers.
  The harness builds the KVM or TCG variant, captures the serial console, and
  writes canonical evidence under `docs/evidence/microvm/`. Root
  perf/live/service/retention gates remain in `qa/vm_acceptance.sh`. The
  committed TCG run passed all 10 checks in 50 s on a container host with no
  `/dev/kvm` (qemu fell back to TCG). The microVM lane and that guide were
  later removed from the repository.
- A deterministic light/dark native screenshot set
  (`design/screenshots/native/{dark,light}/`, 1280x720, canonical provenance)
  plus `tools/screenshots.sh`, whose `--check` verifies committed bytes,
  sha256, dimensions, and the provenance schema without a renderer.
- A manual `microvm` GitHub Actions workflow (`workflow_dispatch`) that
  reproduces the disposable microVM verification on a hosted Linux runner and
  uploads its evidence, plus `qa/script_syntax.sh` (offline shell-syntax gate)
  wired into `zig build check` and a CI step that runs the gate together with
  `tools/screenshots.sh --check`.

### Changed

- README rewritten around the Ambxst-style layout: branded logo header,
  light/dark screenshots, installation and deployment-option explainers,
  NixOS configuration, extensions/theming, safety, verification lanes, known
  limits, and credits.
- New logo system (`assets/logo.svg`, `assets/logo-light.svg`,
  `assets/logo-mark.svg`) and refreshed AppImage/deb/desktop icon
  (`packaging/linux/xsprof.svg`): a sampled X built from two crossing scheduler
  trace lanes.
- The Overview light/dark stills now render the committed real VM capture
  instead of the healthy replay, and the topbar ellipsizes long session
  identities deterministically instead of overlapping the REPLAY/LOSS/safety
  chips.

### Fixed

- Live tail stop no longer stalls when the bounded feed fills up. The feed now
  trims to half capacity in one step; trimming only the exact overflow copied
  the whole store for every appended event once full (a catch-up/stop stall).
  See [docs/history/audits/live-feed-stall.md](docs/history/audits/live-feed-stall.md).
- Recorder probe SKIP/REFUSE is no longer displayed as FAILED; the reason is
  shown with the capture permission requirement and the Recorder screen keeps
  in-app export/verify actions instead of shell snippets.
- Capture permission guidance added in docs/guides/capture-permissions.md
  (setcap, privileged daemon + follow-recorder, systemd service).
- Clock-dependent recorder tests no longer panic or fail on freshly booted CI
  runners: the torn-tail test uses a deterministic monotonic base instead of
  subtracting 120 s from the host monotonic clock (u64 underflow), and the
  window/markers bounds tests timestamp events away from the wall-derived
  cutoff so scheduling jitter cannot filter them.
- The topbar truncates long session identity strings with a measured,
  codepoint-safe trailing ellipsis and keeps the right-aligned status chips
  readable at 1280 px.
- The TCG microVM guest uses the q35 machine because the microvm machine type
  wedges this kernel in early KASLR under qemu TCG; the KVM variant keeps the
  lighter microvm machine.
- The release workflow's pinned appimagetool URL now uses the real release
  asset names (`appimagetool-<arch>.AppImage`, no version in the filename);
  the previous URL 404'd on the first dispatch. Duplicate
  `dist/*.AppImage.sha256` globs were also removed from the publish step, which
  otherwise hit `HTTP 422: ReleaseAsset.name already exists`. The v0.5.1
  unsigned prerelease now publishes and its `SHA256SUMS` verifies.
- The microVM harness infers KVM vs TCG from qemu's explicit fallback line and
  the host `/dev/kvm` writability instead of the guest `kvm-clock` line, which
  the guest console loglevel can filter (a GitHub runner with usable `/dev/kvm`
  was previously mislabeled as TCG).

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
