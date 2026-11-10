# macOS (viewer only)

macOS is a **viewer-only** platform. It has no perf/tracepoint backend, so it
cannot capture scheduler events; it replays canonical NDJSON and follows a
recorder state directory exported from Linux. macOS is not a release target and
there are no signed macOS artifacts.

## Build from source with Nix

```sh
nix build .#xsprof          # aarch64-darwin
./result/bin/xsprof ui --replay session.ndjson
./result/bin/xsprof ui --follow-recorder /path/to/state
```

The flake supports `aarch64-darwin` only (Intel macOS is out of scope). The
binary is ad-hoc signed and **not notarized**; Gatekeeper will warn. There is
no signed app, cask, tap, or `.dmg`, and nothing is published for macOS.

## Viewer behavior

- `xsprof ui` opens one AppKit window hosting a `CAMetalLayer`. The renderer is
  the same flat instance draw list the CPU and Linux GL backends use.
- `--replay FILE` loads a canonical `xsprof/event/v1` NDJSON journal (or a
  recorder window extracted with `capture`).
- `--follow-recorder DIR` tails a recorder state written on Linux (legacy
  NDJSON or compact `.xsraw`), re-serializing canonical NDJSON for the bounded
  live feed. It never pretends to capture and never writes host policy.
- Live capture actions report `SKIP` with the no-backend reason. Capture
  controls are disabled with the exact reason.
- `xsprof snapshot` and `xsprof demo` are supported headless anyway; the CPU
  rasterizer is canonical.

## Accessibility

The viewer builds the same `xsprof/a11y-tree/v1` tree and bridges it through
`NSAccessibility` (roles, labels, values, frames, focus, press). The bridge is
smoke-tested with a hidden window; **VoiceOver needs a human-run audit** before
spoken-navigation quality can be claimed. Automated work never opens or
activates a real window; `qa/macos_smoke.sh` creates a hidden window only.

## Limits

- No live capture on macOS: that is what the Linux recorder is for.
- Rendering is 1x; Retina 2x crispness is a follow-up.
- No notarized/signed distribution: build from source with Nix and treat the
  binary as unsigned software.
- Keyboard/mouse work natively; IME and menu-bar behaviors are not part of the
  viewer contract.

## Building directly (without Nix)

`./tools/zig build` on macOS 15+ with the Xcode SDK produces a native binary.
Cross-building a universal app needs the macOS SDK path
(`-Dmacos-sdk=<SDK>`); direct builds are ad-hoc signed by Zig and not
notarized. Prefer the Nix build for reproducibility.
