# Native Linux

`xsprof ui` (or bare `xsprof` on a graphical TTY) creates one X11 window and a
GLX context, then draws the shared flat instance list with OpenGL 3.3. X11 and
GL are loaded through `std.DynLib`; the build has no link-time GUI dependency.
First run shows onboarding; later runs start at Home.

## Why a dynamic libc

`std.DynLib` uses `dlopen` only when the process has a dynamic libc. The
portable cross-build target for the native window is glibc:

```sh
./tools/zig build -Dtarget=aarch64-linux-gnu --prefix zig-out/linux-arm
```

A static-musl binary still runs the CLI, but `ui` cannot load system X11/GL.
On a normal Linux host, `./tools/zig build` targets the host glibc and works.

## Surface

- `src/platform/linux/x11.zig` / `xlib.zig` / `events.zig` / `app.zig` —
  display, window, GLX context, ConfigureNotify resize, size hints, pointer
  motion/drag/release, scroll, clipboard, keyboard routes, dirty tick, and
  hidden smoke.
- `src/platform/linux/live_source.zig` — preferred in-process recorder
  daemon thread (compact `.xsraw` segments, cooperative stop, duration 0 means
  until stop) plus `follow_source` tail for the live view; `lab_worker`
  view-only fallback when no state directory is configured. Capture is gated
  on `live.probe` READY and the Settings capture opt-in.
- `src/platform/follow_source.zig` — stoppable recorder tail. It decodes
  compact segments through `recorder/segment_reader.zig`, re-serializes
  canonical NDJSON into the bounded live feed, and emits explicit gaps for
  missing/corrupt/retained segments.
- `lib/xsui/src/gpu/gl.zig` (module `xsui-gl`) — runtime-loaded OpenGL 3.3
  renderer, one instanced `GL_TRIANGLE_STRIP` draw, R8 atlas upload,
  straight-alpha blend, capability probing, and the `gpu.Renderer` adapter.
- Keys: `0` Home, `1`–`5` analysis/Recorder, `6` Audit, `7` Settings,
  `t` theme, `Cmd/Ctrl+K` palette; the window manager close button uses
  `WM_DELETE_WINDOW`.

## Accessibility

Linux builds the same `xsprof/a11y-tree/v1` tree and can dump it with
`ui --a11y` or `snapshot --a11y FILE`. The AT-SPI2 D-Bus bridge is not built
in this pass; the UI reports DEGRADED with that exact reason rather than
silently exposing no tree.

## Packaging

- Nix: `nix build .#xsprof` (pinned Zig 0.17.0) with a wrapper for the
  runtime-loaded X11/GL libraries and installed web/fixtures/manpages/desktop
  files; the opt-in NixOS recorder module is in `nix/module.nix`.
- Tarball: `./tools/package.sh`; Debian: `./tools/package_deb.sh`.
- Desktop entry and hicolor icon are installed by the tarball/deb/Nix layout.

## Evidence

Headless Xvfb smoke (no window mapped) creates the X11/GLX context and renders
one frame, including a synthetic ConfigureNotify resize; it is wired into
`zig build check` when `xvfb-run` is available. A mapped native window was
captured for `docs/ui/screenshots/p6-linux.png`.

## Limits

- 1x rendering; Retina-equivalent scale is a follow-up.
- Live capture needs readable tracefs and `CAP_PERFMON` (or
  `perf_event_paranoid <= 1`); external systemd/CLI recorders are attach-only.
- Linux AT-SPI2 screen-reader bridging is DEGRADED/JSON-only in this pass.
- X11 IME and paste parity remain follow-ups.
