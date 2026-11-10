# Repository guidance

## Project

`xsprof` is a **trust-first Linux scheduler flight recorder with an optional
native viewer**. The shipped core is the read-only capture path, the bounded
compact-segment recorder, and the canonical evidence tooling; the viewer
(`xsui` + `src/app/design`) is an optional, frozen consumer of the same data.
Linux is the capture platform. macOS is a viewer-only platform (no perf
backend) and is never published as a release artifact.

There is no browser, WASM, HTTP, or server surface. The lab/experiment lane and
its schemas were removed; do not reintroduce them. Historical material lives in
`docs/history/`.

## Hard rules

- **Zig 0.17.0 only.** Use `./tools/zig` (pins and bootstraps 0.17.0). Use
  0.17 idioms: `std.process.Init`, `std.Io`, `@backingInt`, `std.Build.Module`/
  `root_module`. Read `docs/zig-0.17-api-usage.md`, then the pinned toolchain's
  own stdlib (`./tools/zig env` → `lib_dir`) before guessing. The vendored
  stdlib text corpus was removed for repository size; do not re-add it.
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
  `libbpf` may be loaded with `dlopen` for the VM-only BPF gate. Bundled fonts
  and the glyph atlas are assets with licenses, not code dependencies.
- **No window in automated work.** Agents and tests use `xsprof snapshot`,
  `xsui.Tester`, or offscreen renderers. Never open, activate, capture, or
  synthesize input into a real window/screen.
- **1,000-line responsibility limit.** One hand-written source file should hold
  one responsibility. `./tools/zig build lines` enforces the limit. Tests
  (`tests/**`, `*_test.zig`) and generated files (first line contains
  `GENERATED`) are exempt; split by responsibility instead of growing a file.
- **Headless first.** Every viewer feature needs a deterministic snapshot or
  unit test. Every backend feature needs a fail-closed/SKIP test. Every wire
  output needs a canonical JSON test and, where applicable, schema validation.
- **No hidden network.** No telemetry, no external fonts/CDNs, no listening
  socket, no outbound request from the product.
- **No committed evidence, media, or vendor corpora.** Keep the tracked tree
  small: `qa/repo_size.sh` budgets 12 MiB total and 2 MiB per file (exact glyph
  atlas allowlist). Verification evidence is attached to GitHub releases, not
  committed.
- **Schema-validated wire.** Canonical `xsprof/*` JSON in `schemas/xsprof/`,
  examples in `fixtures/`, golden bytes in `tests/golden/`. Keep Zig
  serializers, schemas, and fixtures in lockstep.
- **Tag-first releases.** Publish only from a pushed `vX.Y.Z` tag; never rewrite
  history after a tag. Fix forward with the next version.

## Commands

```sh
./tools/zig build              # xsprof binary
./tools/zig build check        # fast local gate; tool-light, no display/server needed
./tools/zig build check-ci     # CI gate: check + platform/media + repo-size + docs-links (no silent SKIPs)
./tools/zig build check-vm     # root live/service/retention gates (disposable Linux VM only)
./tools/zig build test         # unit + integration tests
./tools/zig build fuzz         # deterministic parser fuzz tests
./tools/zig build run -- help
./tools/zig build fmt-check
./tools/zig build lines            # 1,000-line responsibility limit
./tools/zig build design-check     # python3 design/validate.py (design contract only)
./tools/zig build repo-size        # tracked-tree size budgets
./tools/zig build docs-links       # every relative markdown link resolves
./tools/zig build screenshots-check # committed stills: bytes + provenance
./tools/zig build cli-parity       # process-level read-only CLI behavior
./tools/zig build cli-manifest     # committed CLI manifest is current
./tools/zig build perf-smoke       # bounded hot-path performance floor
./tools/zig build compact-roundtrip # .xsraw decode/verify/corruption gate
./tools/zig build a11y-smoke       # deterministic accessibility tree
./tools/zig build xsui-package     # standalone UI package gate
./tools/zig build native-live-smoke # hidden live/recorder-tail smoke (Xvfb, Linux)
./tools/zig build xvfb-smoke       # hidden X11/GLX smoke (Xvfb, Linux)
./tools/zig build live-smoke       # root perf/daemon gate, disposable VM only
./tools/zig build service-smoke    # root systemd gate, disposable VM only
./tools/zig build retention-bench  # root retention budget gate, disposable VM only
```

One-time, pre-first-tag only (destructive history rewrite; see
`docs/maintaining.md`): `CONFIRM=1 sh tools/repo_diet.sh`. Never rewrite history
after a release tag exists.

`check` never needs a display, Python, ffmpeg, or root. `check-ci` sets
`XSPROF_REQUIRE_TOOLS=1`, so a missing tool fails instead of skipping; CI and
the release preflight run it. Development-only tools (Python 3, ImageMagick,
ffmpeg, Xvfb) are for design tokens, screenshots, and platform smokes — never
runtime dependencies.

## Layout and conventions

- `src/core/` — Zig std only; no OS or UI imports; canonical JSON writer,
  event model, version, schema helpers.
- `src/os/linux/` — guarded by `builtin.os.tag`; non-Linux returns
  SKIP/REFUSE, never fake data.
- `src/capture/`, `src/recorder/`, `src/stream/`, `src/incident/`,
  `src/analyze/` — read-only collectors, compact segments, bounded stores,
  incident bundles, advisor.
- `src/cli/`, `src/main.zig` — dispatch only; visible verbs are the operator
  surface, automation verbs are listed by `help --all`.
- `src/tui/` — bounded ANSI views (`watch`, dashboard) for SSH/headless use.
- `lib/xsui/` — standalone native UI package (CPU rasterizer + Metal/GL
  backends + fonts/shaders). It has no profiler or OS imports; `xsprof` uses it
  through its public API only. `qa/xsui_package.sh` keeps that boundary
  enforced, including the no-WebGL/no-WASM rule.
- `src/app/design/`, `src/platform/` — the optional viewer. Treat it as frozen:
  no new routes, palettes, or effects without an explicit product decision.
  `src/app/` is platform-neutral; `src/platform/` owns windows, contexts, and
  effect execution; renderers live in `lib/xsui/src/gpu/`.
- `design/` — the frozen console prototype (`index.html`) and its UI/UX token
  contract (`tokens.json`, `palettes.json`, `ui-spec.json`, `screens.json`, …).
  It is design input, never built or served. Validate with
  `./tools/zig build design-check`; committed stills are
  `design/screenshots/native/{dark,light}/{home,overview}.png`.
- `schemas/xsprof/` — canonical wire schemas; `fixtures/` — bounded example
  inputs; `tests/golden/` — byte-stability baselines. Everything stays in
  lockstep with the Zig constants and is schema-validated.
- `qa/` — shell gates; `nix/` — flake package, checks, NixOS recorder module;
  `packaging/` — systemd unit, sysusers, desktop entry/icon.
- JSON output is canonical: keys strictly ascending, compact separators, no
  unstable formatting. Input parsing belongs at the boundary and must be
  bounded.
- Prefer bounded rings, arena allocation per frame/batch, and stable keys over
  unbounded growth or per-frame allocation churn.
- Viewer text is monospace-first, tabular numerals, semantic state colors.
  Never render unsafe/lost/refused/SKIP data as success; capability states are
  never color-only.

## Current phase

Brownfield repositioning: the flight recorder and its evidence tooling are the
product, the viewer is optional and frozen, and the repository was dieted to a
small tracked tree (no evidence/media/vendor corpora). Docs describe the
target state and gate tiers above; when code and docs disagree, stop and fix
the smaller error — this repository treats stale claims as bugs. Re-run
`./tools/zig build check` after any behavior change; `check-ci` before a
release.
