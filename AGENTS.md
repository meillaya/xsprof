# Repository guidance

## Project

`xsprof` is a read-only Linux scheduler and memory profiler rewritten in Zig
0.17.0, with a custom GPU UI (`xsui`) targeting a web frontend, native macOS,
and native Linux. The historical C++ tree lives on `archive/cpp-0.1.0`; do not
restore it to `main`.

## Hard rules

- **Zig 0.17.0 only.** Use `./tools/zig` (pins and bootstraps 0.17.0). Use
  0.17 idioms: `std.process.Init`, `std.Io`, `@backingInt`,
  `std.Build.Module`/`root_module`. Consult `docs/zig-0.17-api-usage.md` and
  `docs/vendor/zig-0.17.0/` before guessing.
- **No C shims.** `@cImport` is removed in 0.17 and must not be reintroduced.
  System APIs are hand-written `extern`/`extern "c"` declarations, `std.DynLib`
  (`dlopen`), or the Objective-C runtime. No `.c`/`.m` files.
- **Read-only host.** Never add a path that mutates scheduler/memory policy,
  writes `/proc` or `/sys`, or auto-applies an advisor recommendation. Every
  serialized record keeps `host_mutation=false`. BPF stays VM-marker-gated and
  host-refused.
- **No privilege escalation.** Capability probes return READY/DEGRADED/SKIP/
  REFUSE with a reason; they never elevate or suggest elevation.
- **No new runtime dependencies.** Build with Zig std + system frameworks.
  `libbpf` may be loaded with `dlopen` for the VM-only BPF lane. Bundled fonts
  are assets with their license, not code dependencies.
- **No window in automated work.** Agents and tests use `xsprof snapshot`,
  `xsui.Tester`, or offscreen renderers. Do not open, activate, capture, or
  synthesize input into a real window/screen.
- **600-line limit per hand-written source file.** `./tools/zig build lines`
  enforces it. Split by responsibility instead of growing a file.
- **Headless first.** Every UI feature needs a deterministic snapshot or unit
  test. Every backend feature needs a fail-closed/SKIP test. Every wire output
  needs a canonical JSON test.
- **No hidden network.** The serve lane is loopback-only with a token. The UI
  makes no external requests and sends no telemetry. Web assets use relative
  URLs only.

## Commands

```sh
./tools/zig build              # xsprof binary
./tools/zig build check        # fmt, 600-line limit, vendor, tests, QA gates
./tools/zig build test
./tools/zig build run -- help
./tools/zig build fmt-check
./tools/zig build lines
./tools/zig build vendor-check
./tools/zig build fuzz            # deterministic parser fuzz tests
./tools/zig build compact-roundtrip # compact segment decode/verify gate
./tools/zig build a11y-smoke      # deterministic accessibility tree gate
./tools/zig build native-live-smoke # hidden live/recorder-tail smoke (Xvfb)
./tools/zig build xvfb-smoke      # hidden resize/a11y X11/GLX smoke (Xvfb)
./tools/zig build release-tooling # attestation/tap dry-run gate
./tools/zig build live-smoke      # root perf/daemon/SIGTERM, disposable VM only
./tools/zig build xsui-package    # standalone GPU UI package gate
./tools/zig build service-smoke   # Linux root, disposable VM only
devenv shell                      # git/curl/xz; Zig still comes from tools/zig
```

Vendor refresh (developer-only, needs network):

```sh
sh tools/vendor_stdlib.sh
sh qa/vendor_hash.sh
```

## Layout and conventions

- `src/core/` has no OS or UI imports.
- `src/os/linux/` is guarded by `builtin.os.tag`; non-Linux builds return
  SKIP/REFUSE, never fake data.
- `lib/xsui/` is the standalone GPU UI package: target-neutral core, CPU
  rasterizer, Metal/GL backends, fonts, and shaders. Its core has no profiler
  or OS imports and compiles for native and wasm; native backends are separate
  modules (`xsui-metal`, `xsui-gl`, `xsui-objc`). Treat it as a consumer would:
  xsprof imports it as a path dependency and only uses its public API.
- `src/app/` is platform-neutral; `src/platform/` owns windows and contexts;
  renderers live in `lib/xsui/src/gpu/`. The app uses one draw list everywhere.
- `design/` holds the console prototype (`index.html`) and its UI/UX token contract:
  palettes, typography, layout, components, screens, flows, keybindings, and the
  GPU mapping. Keep it in sync with the prototype (`python3 design/validate.py`);
  it is design input, not runtime code.
- Wire schemas live in `schemas/xsprof/`; fixtures in `fixtures/`; golden
  bytes in `tests/golden/`. Keep them in lockstep with the Zig constants.
- JSON output is canonical: keys strictly ascending, compact separators, no
  unstable formatting. Input parsing belongs at the boundary and must be
  bounded.
- Prefer bounded rings, arena allocation per frame, and stable keys over
  unbounded growth or per-frame allocation churn.
- UI text is monospace-first, tabular numerals, semantic state colors
  (PASS/SKIP/REFUSE/live). Never render unsafe/lost/refused data as success.

## Current phase

P0–P7 and M0–M4/M6/M7 are complete. v0.4.0 makes the GPU console the
product surface: Home/Recorder/Audit/Settings routes, first-run onboarding,
GPU picker/text entry, in-process native live capture plus recorder tail,
native window resize/input, a platform-neutral accessibility tree with web and
macOS bridges, compact `.xsraw` raw segments (ten-minute age cap under the byte
budget), a simplified CLI, and Nix/Linux/macOS packaging with fail-closed
notarization/tap tooling. The recorder module normalizes its own state and
never mutates host policy. Developer ID notarization, public tap publication,
and Linux AT-SPI2 remain external/known limits; the UI shows DEGRADED/SKIP with
the exact reason and does not claim them.

Keep the read-only safety invariants and the 600-line limit green. Native
windows are human-run; automated work uses CPU snapshots, Metal offscreen
parity, Xvfb/hidden-window smokes, and the gated service/live/retention smokes
in a disposable Linux VM. The design console (`src/app/design/`,
`lib/xsui/src/canvas.zig`, `web/`) is the product surface on web, macOS,
Linux, and `snapshot`. The visible lab rail is retired; `xsprof lab` remains a
headless scenario/QA tool. Re-run `zig build check`, `qa/cli_parity.sh`,
`qa/compact_roundtrip.sh`, and `qa/release_tooling.sh` after any behavior
change. Visual evidence is developer-only under `design/evidence/`
(`qa/ui_evidence.sh`). `design/ui-spec.json` is the formal runtime contract; CPU
is canonical and `qa/ui_cross_surface.py` gates Metal/WebGL2 against it.
Reference diffs are advisory, not acceptance criteria. Keyboard focus,
clipboard, brush, and the hidden a11y DOM mirror are covered by the Playwright
scripts. The committed real capture `fixtures/real/macos-vm-sched.ndjson` comes
from the podman Linux VM (macOS has no perf/tracepoint capture); live screenshots
and video replay it, marked `REPLAY` and `host_mutation=false`.
