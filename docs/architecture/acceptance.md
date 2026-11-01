# Rewrite acceptance record

All phases P0–P7 are complete on `main`. Evidence is reproducible from the
repository plus a disposable Linux VM for live/BPF lanes.

| Phase | Gate evidence |
|---|---|
| P0 | C++ tree on `archive/cpp-0.1.0` / tag `cpp-0.1.0`; Zig 0.17.0 pinned; vendored stdlib text hash-checked; no C++ build files on `main`; the archived simulator stayed untouched through the rewrite and was later deleted from `main`. |
| P1 | Canonical event/JSON goldens; privacy redaction; SafePath/unsafe verbs; proc/sysfs capability probes; seven-rule advisor; Chrome Trace; CLI parity. |
| P2 | `xsui` draw list, TTF rasterizer, 8-bit atlas, layout, widgets, Tester, gallery golden; headless snapshots. |
| P3 | Replay Session; Overview/Timeline/Advisor/Events/Capture; wasm32 + WebGL2 instancing; token-gated loopback `serve`; headless Chromium screenshots. |
| P4 | `perf_event_open` collectors, rings, loss markers, `record`; live SSE with `Last-Event-ID` and bounded downsample store; VM browser evidence. |
| P5 | AppKit `NSWindow` + `CAMetalLayer`; instanced Metal; offscreen Metal/CPU parity (avg 0.50); hidden-window smoke; `xsprof ui`. |
| P6 | X11 + GLX native window; runtime-loaded X11/GL; Xvfb smoke; mapped native screenshot; glibc packaging note. |
| P7 | Host-refused/Vm-marker-gated `bpf-gate`; no-op tracepoint `BPF_PROG_LOAD` + perf attach for 200 ms; libbpf dlopen probe; schema + parity. |
| xsui package | `lib/xsui/` builds/tests standalone, has no `xsprof` imports, pins the WebGL instance ABI, and runs its own public-API PNG example; xsprof consumes it as a path dependency. |

## Commands run for the final gate

```sh
./tools/zig build check          # fmt, lines, vendor, CLI parity, web, tests, hidden macOS smoke
./tools/zig build xsui-package
./tools/zig build web-smoke
sh qa/cli_parity.sh
sh qa/macos_smoke.sh
./tools/zig build -Dtarget=aarch64-linux-gnu --prefix zig-out/linux-arm
./tools/zig build -Dtarget=x86_64-linux-gnu --prefix zig-out/linux
```

VM-only lanes (disposable Fedora 44 aarch64 podman VM, tracefs enabled):

```sh
sudo xsprof record --duration 300 --output /tmp/live.ndjson
sudo xsprof bpf-gate --json
```

The BPF gate returns `READY` with `attached:true` and `host_mutation:false`.
Every host without the VM marker refuses before any BPF syscall.

## Productization acceptance

| Milestone | Evidence |
|---|---|
| M0 | Long-lived capture, per-batch arenas, stable store, incremental index parity tests. |
| M1 | `qa/service_smoke.sh` passed in a disposable Fedora 44 aarch64 VM: 8 segments, 315,929 extracted lines, single-writer lock refused a second daemon, SIGKILL recovery kept earlier segments and emitted `capture_interrupted`. CAP_PERFMON at `perf_event_paranoid=2` is recognized. |
| M2 | Combined `comm`/`pid`/`kind`/`loss` filters, filter bar, timeline task/pid filtering, native/web key mapping, deterministic app tests. |
| M3 | Metrics/compare/report/CI-budget tests and schemas. |
| M4 | Recorder-spool `serve --live-dir`, incremental WASM index, line-aligned bounded store. |
| M5 | Universal arm64+x86_64 app bundle and hidden smoke; release workflow linted; notarization/tap tooling exercised locally. External Developer ID credentials and available Actions minutes are absent, so public notarization/tap publication is not claimed. |
| M6 | PSI and cgroup v2 probes exercised in the VM; daemon overhead result showed ~2.7 MB RSS after 305k events; deterministic fuzz step; real 12,000-event multi-process fixture. |

The full gate also passed natively in the disposable Fedora 44 aarch64 VM:
`zig build check` completed 23/23 steps with 90/90 unit tests, plus CLI parity
and web smoke.

## GUI lab progress (M7, in progress)

- L0/L1: bounded input events, layout hit targets, controls, pure lab reducer,
  transactional source loading, shared live feed, and the off-thread capture
  worker.
- L2/L3: native lab rail, source buttons and path editing, capture controls,
  transport window advancement, inspector, palette, and trace export.
- L4: `xsprof lab`, scenario schema, built-in scenarios, canonical run JSON,
  per-step snapshots, and `zig build lab-smoke`.
- L3 A/B: the rail sets a second source, loads it into a separate source
  store, and reports compare regressions.
- L5: the wasm replay client shares the lab state and rail; native-only source
  and capture controls are hidden. `web_run_scenario` runs the healthy scenario
  over the loaded journal and returns canonical run JSON; a custom scenario
  file picker and result download are wired in JS. `qa/web_lab_smoke.mjs`
  passes against the built wasm, including Chrome Trace generation.
- Linux VM gate: `zig build check` passed with 106 tests, CLI parity, web
  smoke, and lab smoke.

The native rail reports pressure/cgroup state, A/B regressions, and exports
trace, report, and snapshot. The web lab runs scenarios, downloads run JSON
and Chrome Trace, and loads a second journal for compare. Final evidence:
106 tests and lab smoke in the Linux VM, web lab smoke, hidden macOS smoke,
service smoke (8 segments, 322,130 extracted lines), universal app build, and
x86_64/aarch64 Linux cross-builds.

Commands for the productization sweep:

```sh
./tools/zig build check
./tools/zig build fuzz
./tools/zig build service-smoke        # Linux root, disposable VM
XSPROF_UNIVERSAL=1 sh tools/package_macos_app.sh
XSPROF_TARGET=aarch64-linux-gnu XSPROF_OS=linux XSPROF_ARCH=aarch64 sh tools/package.sh
XSPROF_TARGET=x86_64-linux-gnu XSPROF_OS=linux XSPROF_ARCH=x86_64 sh tools/package.sh
qa/retention_bench.sh 120000 0 2G yes     # Linux root, disposable VM
```

## Incident bundle and retention truth

- `xsprof incident --last 60s --dir <state> --out <dir>` is exercised in
  `qa/cli_parity.sh`: it must produce `window.ndjson`, `summary.json`,
  `report.html`, and `trace.json`; the summary must carry the finding/status
  model and `host_mutation=false`; the HTML must contain no external URL.
- The incremental sidecar path removed the rotation stall. A 120-second Fedora
  44 aarch64 run captured 17.3M events at 144k/s with zero sample loss and
  retained 2.0 GiB / 92.36 seconds. The old path lost 2.38M events in 60
  seconds. Full method and limits: `docs/architecture/retention.md`.
- The 10-minute / 2 GiB target is **not claimed**. The Capture screen and the
  incident summary report the actually retained wall window; the 10-minute run
  attempted here was aborted by host-disk I/O errors, and the x86_64/Ubuntu
  matrix remains unrun.

## Known limits

- Native windows are fixed-size; pointer and scroll input exist, but there is
  no accessibility tree yet.
- Native live streaming is web-only; native surfaces consume replay/gallery.
- The BPF lane is a no-op load/attach gate; perf remains the event data path.
- PNG output currently uses stored deflate blocks (large but valid).
- Web screenshots use developer Playwright; it is not a shipped dependency.
- Developer ID notarization and the public Homebrew tap require external Apple
  and tap credentials; the unsigned local bundle is ad-hoc signed. A tag-driven
  release run also needs available GitHub Actions minutes.
- cgroup attribution is a bounded live `/proc` snapshot; it is not historical
  event attribution for an old journal.
