# Rewrite acceptance record

All phases P0–P7 are complete on `main`. Evidence is reproducible from the
repository plus a disposable Linux VM for live/BPF lanes.

| Phase | Gate evidence |
|---|---|
| P0 | C++ tree on `archive/cpp-0.1.0` / tag `cpp-0.1.0`; Zig 0.17.0 pinned; vendored stdlib text hash-checked; no C++ build files on `main`; the archived simulator stayed untouched through the rewrite and was later deleted from `main`. |
| P1 | Canonical event/JSON goldens; privacy redaction; SafePath/unsafe verbs; proc/sysfs capability probes; seven-rule advisor; Chrome Trace; CLI parity. |
| P2 | `xsui` draw list, TTF rasterizer, 8-bit atlas, layout, widgets, Tester, gallery golden; headless snapshots. |
| P3 | Replay Session; Overview/Timeline/Advisor/Events/Capture; wasm32 + WebGL2 instancing; token-gated loopback `serve`; headless Chromium screenshots. **Removed in 0.5.0.** |
| P4 | `perf_event_open` collectors, rings, loss markers, `record`; native in-process recorder and follow-tail live view. Web SSE was removed in 0.5.0. |
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
| v0.4.0 UI-first | `zig build check` green locally (245 tests, fmt/lines/vendor, CLI parity, compact round-trip, release tooling, web/UI smokes, xsui package); snapshots deterministic for Home/Recorder/Audit/Settings/onboarding/picker/a11y; `zig build fuzz` green. Root-only live/service/retention and macOS Xvfb/VoiceOver lanes remain external/VM-executed. |

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
qa/retention_bench.sh 600000 0 2G yes     # Linux root, disposable VM
```

## Incident bundle and retention truth

- `xsprof incident --last 60s --dir <state> --out <dir>` is exercised in
  `qa/cli_parity.sh`: it must produce `window.ndjson`, `summary.json`,
  `report.html`, and `trace.json`; the summary must carry the finding/status
  model and `host_mutation=false`; the HTML must contain no external URL.
  The raw window is streamed and analyzed with bounded memory; the trace is a
  bounded prefix with an explicit `trace.truncated` caveat. A 613 MB,
  4,020,874-event window was bundled on the VM with two findings; no 192 MiB
  refusal remains.
- The incremental sidecar path removed the rotation stall. A 10-minute Fedora
  44 aarch64 run captured 83,908,179 events at 139,845/s; the retained 2.0 GiB
  raw window covered 94.44 seconds with no loss markers. The sidecar history
  for the full 10 minutes lost 3,278 of 81.4M events (0.004%), under the 0.1%
  target. The old path lost 2.38M events in 60 seconds. Full method and limits:
  `docs/architecture/retention.md`.
- `history --last 10m` read 774 per-segment sidecars covering 81.4M events with
  3,278 lost events (0.004%) in the historical per-segment profile. Current
  0.3.0 uses 60-second buckets; see the v0.3.0 note at the end. `qa/cli_parity.sh` also exercises the sidecar reader with a synthetic
  `metrics/` sidecar.
- The compact raw tier supersedes the historical NDJSON measurements in
  0.4.0. The 2 GiB budget now covers the ten-minute age cap at the measured
  rate; `qa/retention_bench.sh 600000 0 2G yes` enforces the current
  bytes/event, covered-span, and loss thresholds and must be rerun in the VM.
  Historical 0.3.0 NDJSON numbers below are retained as pre-0.4 evidence only.

## 0.5.0 native-only removal evidence

- `web/`, `src/web.zig`, `src/web_console.zig`, `src/serve/`,
  `src/cli/serve_cmd.zig`, `ui-session` schema, web QA/Playwright scripts, and
  browser assets are deleted; `build.zig` no longer builds wasm/WebGL2 or web
  smokes.
- `xsprof demo` is native-only; `xsprof serve` fails closed as a removed
  0.5.0 verb; help/completions contain no browser surface.
- The standalone xsui package has no WebGL2/wasm backend; CPU/Metal/GL remain.
- AppImage and native offscreen showcase media are part of the 0.5.0 evidence;
  KVM podman VM logs for live_smoke/service_smoke/retention_bench are under
  `docs/evidence/v0.5.0-vm/`.
- Local gate: `zig build check`, fuzz, design validation, and the native
  snapshot/a11y gates pass; browser artifacts are absent from package layouts.
- KVM podman VM (Fedora CoreOS 44, /dev/kvm, committed 0.4.0 binary):
  `live_smoke` PASS (93,534 rows, SIGTERM clean), `service_smoke` PASS
  (3 compact segments, 421,068 extracted lines), `retention_bench 600000 0 2G
  yes` PASS (51,912,224 events, 12.06 B/event, covered 600.01 s, 0 loss,
  10 sidecars, 12,928 KiB RSS). Canonical ratio recomputed from same-VM
  samples: 160.10 B/event -> 13.28x. Evidence:
  `docs/evidence/v0.5.0-vm/`.

## v0.4.0 UI-first evidence

- The native console is the product: eight routes, first-run onboarding,
  GPU picker/text entry, settings/recents/audit persistence, Recorder
  management, exports, and self-managed read-only capture.
- Native resize/input are implemented on AppKit/Metal and X11/GLX; hidden
  resize smokes are wired. A11y tree: web DOM/ARIA and macOS NSAccessibility
  bridges; Linux emits canonical tree JSON and DEGRADED AT-SPI state.
- Compact `.xsraw` segments replace NDJSON raw storage while
  capture/incident/UI outputs stay canonical NDJSON. The reader is streaming
  and bounded; torn/corrupt tails are explicit markers. `verify` and the
  retention bench enforce bytes/event, covered span, and loss.
- Local evidence (this host): `./tools/zig build check` PASS,
  `./tools/zig build fuzz` PASS, `qa/compact_roundtrip.sh` PASS,
  `qa/release_tooling.sh` PASS, deterministic Home/Recorder/Audit/Settings
  snapshots, and a deterministic `snapshot --a11y` tree.
- Nix evidence: `nix flake check --all-systems --no-build --no-update-lock-file`
  PASS and an offline package build from a clean source snapshot (the clean
  snapshot reports its own HEAD version; current tree reports 0.4.0). The
  session's Nix cache was writable for this lane; rerun in a normal shell/CI.
- Not run here (must run externally): root `live_smoke`, `service_smoke`,
  `retention_bench.sh 600000 0 2G yes`; Xvfb/macOS hidden smokes and a human
  VoiceOver audit; real Developer ID notarization, Gatekeeper, and tap push.

## Known limits

- Native windows are resizable at 1x; Retina 2x crispness, X11 IME/paste
  parity, and browser-native recorder control remain follow-ups.
- Linux AT-SPI2 screen-reader bridging is DEGRADED/JSON-only; the tree,
  keyboard focus, web ARIA, and macOS NSAccessibility bridge are implemented.
- Native live capture is Linux-only (perf); macOS follows a recorder directory.
  The recording daemon path needs a Linux host with CAP_PERFMON/readable
  tracefs and is exercised by the VM gates, not by unit tests.
- Native web surfaces are viewers: capture/recorder control and host directory
  browsing fail closed with explicit reasons.
- Developer ID notarization, Gatekeeper acceptance, and public tap publication
  require external credentials; the repository ships fail-closed attestation
  tooling and local dry-runs, not credentials.
- The 10-minute raw tier is workload/budget dependent; the UI and verify report
  the actual covered span.
- The BPF lane is a no-op load/attach gate; perf remains the event data path.
- PNG output currently uses stored deflate blocks (large but valid).
- Developer ID notarization and the public Homebrew tap require external Apple
  and tap credentials; the unsigned local bundle is ad-hoc signed. A tag-driven
  release run also needs available GitHub Actions minutes.
- cgroup attribution is a bounded live `/proc` snapshot; it is not historical
  event attribution for an old journal.


## v0.3.0 polish

- `xsprof top` (live ranked view, fail-closed SKIP) and `xsprof why`
  (streaming root-cause report with wakeup pairs) landed.
- Capture batches are timestamp-sorted; legacy replay reports `out_of_order`
  instead of claiming rejection. `PERF_RECORD_LOST` is journaled once.
- Page faults split into `SW_PAGE_FAULTS_MIN`/`MAJ`; major/minor are observable.
- `record`/`capture` stream; daemon SIGTERM flushes and marks the manifest
  stopped; history sidecars use a bounded interval/retention.
- Historical 0.3 web surface (removed in 0.5.0): `serve` validated journals,
  tokens, CSP, and live append. The current native console replaces it.
- MIT LICENSE, release check gate and checksum upload.
- Historical gates: `unsafe_cli_matrix`, `no_host_mutation`, `privacy_scan`,
  `web_ui_smoke` (removed), `version_sync`, and root `live_smoke`.
- VM evidence (Fedora 44 x86_64): `live_smoke` PASS, `service_smoke` PASS
  (6 segments, 334,064 extracted lines), `bpf-gate` READY.

The 0.3.0 residual list is superseded by the v0.4.0 section above: native
live/resize, the accessibility tree, compact raw storage, and fail-closed
notarization/tap tooling landed; Linux AT-SPI2, real Apple/tap credentials,
Retina 2x, and web recorder control remain explicit limits. The historical
94-second/10-minute figures were measured before the 60-second sidecar cadence
and before compact segments; do not mix them with 0.4 retention numbers.

Current gate: `zig build check` passes the full local suite (unit/fuzz tests,
CLI parity, compact round-trip, a11y smoke, release tooling, web UI/bridge
smokes, privacy/no-mutation/unsafe-verb gates, xsui package, lab smoke).
Root-only `live_smoke`/`service_smoke`/retention and macOS Xvfb/VoiceOver/
notarization lanes are external/VM-executed.
