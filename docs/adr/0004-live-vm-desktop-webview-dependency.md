# ADR 0004: Live VM desktop WebView dependency direction

## Status

Superseded for the implemented Linux desktop host. This ADR records the early
dependency direction only; the current product runtime is the explicit
WebKitGTK host helper documented in `docs/desktop-webview.md`.

## Context

The live VM desktop plan needs a Zig-owned, non-Electron shell that renders the
authoritative live microVM lab UI in a system WebView. The root project is being
built and tested with Zig 0.16.0, so any Zig wrapper dependency must prove
compatibility with that toolchain before it can become the implementation path.

The first task in `.omo/plans/zig-webview-live-vm-desktop.md` intentionally
captures a failing-first proof for `zig build live-vm-desktop -- --smoke` before
any product entrypoint exists. That keeps the desktop work ordered: prove the
missing surface, then add dependency/build integration in later tasks.

## Decision

The original preference for a direct `webview/webview` C ABI is no longer the
authoritative runtime claim for the Linux desktop shell. The implemented product
path uses a WebKitGTK host helper with a script-message bridge. The
`webview/webview` declarations are retained only as a legacy compile-only canary
until a future, separately evidenced change adopts or removes them.

## Consequences

- Task 1 remains documentation and RED-proof only; it must not add
  `live-vm-desktop` build wiring or any other build step.
- Any pre-existing `live-vm-web` browser/reference step is unrelated to this
  desktop WebView dependency decision and remains out of scope for Task 1.
- The probe should be read as a system WebKitGTK dependency canary, not proof
  that the product is running through the `webview/webview` ABI.
- If a Zig wrapper is evaluated, its acceptance criterion is a local Zig 0.16.0
  build proof, not repository popularity or README claims.
- The desktop app remains VM-lab-only/fail-closed and must not broaden host
  scheduler mutation permissions.

## Verification

- `.omo/evidence/task-01-zig-webview-live-vm-desktop-red.txt` contains the
  failing-first `zig build live-vm-desktop -- --smoke` transcript and non-zero
  `exit_status=`.
- `grep -n "live-vm-desktop" build.zig` does not report a new desktop build
  step from this ADR.
