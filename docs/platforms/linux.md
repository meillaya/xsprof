# Linux (capture platform)

Linux is the capture platform: perf tracepoints, tracefs, `/proc`, `/sys`,
cgroups/PSI probes, and the recorder all run here. The viewer is optional and
runs on the same host.

## Capture

- `xsprof record`, `top`, `daemon`, `capture`, `why`, `incident`, `history`,
  `watch`, `verify` and `advise` are the automation/operator surface.
- Live capture needs readable tracefs and `CAP_PERFMON` (or
  `perf_event_paranoid <= 1`); see [recording permissions](../guides/capture-permissions.md).
- `src/os/linux/` is guarded by `builtin.os.tag`. Non-Linux builds return
  SKIP/REFUSE with a reason, never fake data.
- The recorder writes compact `.xsraw` segments under its own state directory
  only; it never writes `/proc`/`/sys`, changes policy, or suggests elevation.

## Viewer (optional)

`xsprof ui` (or bare `xsprof` on a graphical TTY) creates one X11 window and a
GLX context, then draws the shared flat instance list with OpenGL 3.3. X11 and
GL are loaded through `std.DynLib`; the build has no link-time GUI dependency.
First run shows onboarding; later runs start at Home. The full route set is
Home, Overview, Timeline, Advisor, Events, Recorder, Audit, Settings; the viewer
also reports a canonical accessibility-tree JSON dump and keyboard focus order.

The viewer owns its recorder when capture controls are enabled: one in-process
read-only recorder thread writes compact segments, and a follow-tail
re-serializes them into the bounded live feed. Without a capture probe that is
READY, it reports SKIP/REFUSE and does not stream fabricated data.

## Why a dynamic libc

`std.DynLib` uses `dlopen` only when the process has a dynamic libc. The
portable cross-build target for the native window is glibc:

```sh
./tools/zig build -Dtarget=aarch64-linux-gnu --prefix zig-out/linux-arm
```

A static-musl binary still runs the CLI, but `ui` cannot load system X11/GL. On
a normal Linux host, `./tools/zig build` targets the host glibc and works.

## Packaging

- **Nix:** `nix build .#xsprof` (pinned Zig 0.17.0) with a wrapper for the
  runtime-loaded X11/GL libraries and the installed fixtures/desktop/systemd
  files; the opt-in NixOS recorder module is `nix/module.nix`.
- **Release artifacts:** checksummed tarball, Debian package, and AppImage for
  x86_64/aarch64 (see [install](../guides/install.md)); Sigstore build
  provenance and `SHA256SUMS` accompany every release.
- The desktop entry/icon, sysusers entry, and hardened systemd unit live under
  `packaging/`.

## Accessibility and display limits

- The viewer builds the same `xsprof/a11y-tree/v1` tree and dumps it with
  `ui --a11y` or `snapshot --a11y FILE`.
- **AT-SPI2 is not implemented.** Linux reports the bridge as `DEGRADED` with
  that exact reason; there is no screen-reader bridge in this release.
- Rendering is 1x; Retina-equivalent scaling is a follow-up.
- X11 IME and paste parity are not implemented. Automated work never opens a
  real window: tests use CPU snapshots and hidden-window Xvfb smokes.

## Developer gates

`./tools/zig build check` runs on any Linux host; `check-ci` adds platform/
media lanes and fails instead of skipping when a required tool is missing. The
root-only perf/recorder gates run in a disposable KVM VM. From a rootless host
the durable, write-scoped way to run them is
`sh tools/vm_lab.sh gates --all --bundle` (see [maintaining](../maintaining.md)):
it pins every mutable host path under `.vm/`, keeps evidence under
`dist/vm/evidence/`, and refuses to fabricate a PASS. A container-only host can
still run `sh tools/vm_lab.sh gates --backend podman-container --lanes
container,container-analysis`; explicitly requested privileged lanes are
recorded as `REFUSE` with the exact reason.
