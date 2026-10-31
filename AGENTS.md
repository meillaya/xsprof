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
- **Do not modify `simulator/`.** It is archived historical material with its
  own guidance and is excluded from the root build.

## Commands

```sh
./tools/zig build              # xsprof binary
./tools/zig build check        # fmt, 600-line limit, vendor hashes, tests
./tools/zig build test
./tools/zig build run -- help
./tools/zig build fmt-check
./tools/zig build lines
./tools/zig build vendor-check
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
- `src/ui/` has no profiler or OS imports; it compiles for native and wasm.
- `src/app/` is platform-neutral; `src/platform/` owns surfaces; `src/gpu/`
  owns renderers. The app uses one draw list everywhere.
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

P3 is complete: replay Session model, real profiler screens, wasm32-freestanding
UI core, WebGL2 instanced frontend, token-gated loopback `serve`, and headless
Chromium screenshots. P4 is live capture: perf/ring collectors, loss plumbing,
aggregation, `record`, live streaming, and VM-lab validation. Update the
roadmap when a gate passes.
