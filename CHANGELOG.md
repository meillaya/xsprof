# Changelog

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
