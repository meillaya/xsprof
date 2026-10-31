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

## Known limits

- Native windows are fixed-size and keyboard-only; no a11y tree or pointer
  hit-testing yet.
- Native live streaming is web-only; native surfaces consume replay/gallery.
- The BPF lane is a no-op load/attach gate; perf remains the event data path.
- PNG output currently uses stored deflate blocks (large but valid).
- Web screenshots use developer Playwright; it is not a shipped dependency.
