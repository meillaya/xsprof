# Rewrite acceptance record

All phases P0–P7 are complete on `main`. Evidence is reproducible from the
repository plus a disposable Linux VM for live/BPF lanes.

| Phase | Gate evidence |
|---|---|
| P0 | C++ tree on `archive/cpp-0.1.0` / tag `cpp-0.1.0`; Zig 0.17.0 pinned; vendored stdlib text hash-checked; no C++ build files on `main`; `simulator/` untouched. |
| P1 | Canonical event/JSON goldens; privacy redaction; SafePath/unsafe verbs; proc/sysfs capability probes; seven-rule advisor; Chrome Trace; CLI parity. |
| P2 | `xsui` draw list, TTF rasterizer, 8-bit atlas, layout, widgets, Tester, gallery golden; headless snapshots. |
| P3 | Replay Session; Overview/Timeline/Advisor/Events/Capture; wasm32 + WebGL2 instancing; token-gated loopback `serve`; headless Chromium screenshots. |
| P4 | `perf_event_open` collectors, rings, loss markers, `record`; live SSE with `Last-Event-ID` and bounded downsample store; VM browser evidence. |
| P5 | AppKit `NSWindow` + `CAMetalLayer`; instanced Metal; offscreen Metal/CPU parity (avg 0.50); hidden-window smoke; `xsprof ui`. |
| P6 | X11 + GLX native window; runtime-loaded X11/GL; Xvfb smoke; mapped native screenshot; glibc packaging note. |
| P7 | Host-refused/Vm-marker-gated `bpf-gate`; no-op tracepoint `BPF_PROG_LOAD` + perf attach for 200 ms; libbpf dlopen probe; schema + parity. |

## Commands run for the final gate

```sh
./tools/zig build check          # fmt, lines, vendor, CLI parity, web, 58 tests, hidden macOS smoke
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
| M5 | Universal arm64+x86_64 app bundle and hidden smoke; release workflow and notarization/tap tooling; external Developer ID credentials absent, so public notarization/tap publication is not claimed. |
| M6 | PSI and cgroup v2 probes exercised in the VM; daemon overhead result showed ~2.7 MB RSS after 305k events; deterministic fuzz step; real 12,000-event multi-process fixture. |

Commands for the productization sweep:

```sh
./tools/zig build check
./tools/zig build fuzz
./tools/zig build service-smoke        # Linux root, disposable VM
XSPROF_UNIVERSAL=1 sh tools/package_macos_app.sh
XSPROF_TARGET=aarch64-linux-gnu XSPROF_OS=linux XSPROF_ARCH=aarch64 sh tools/package.sh
XSPROF_TARGET=x86_64-linux-gnu XSPROF_OS=linux XSPROF_ARCH=x86_64 sh tools/package.sh
```

## Known limits

- Native windows are fixed-size; pointer and scroll input exist, but there is
  no accessibility tree yet.
- Native live streaming is web-only; native surfaces consume replay/gallery.
- The BPF lane is a no-op load/attach gate; perf remains the event data path.
- PNG output currently uses stored deflate blocks (large but valid).
- Web screenshots use developer Playwright; it is not a shipped dependency.
- Developer ID notarization and the public Homebrew tap require external Apple
  and tap credentials; the unsigned local bundle is ad-hoc signed.
- cgroup attribution is a bounded live `/proc` snapshot; it is not historical
  event attribution for an old journal.
