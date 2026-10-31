# Native Linux

`xsprof ui` creates one X11 window and a GLX context, then draws the shared
flat instance list with OpenGL 3.3. X11 and GL are loaded through `std.DynLib`;
the build has no link-time GUI dependency.

## Why a dynamic libc

`std.DynLib` uses `dlopen` only when the process has a dynamic libc. The
portable cross-build target for the native window is glibc:

```sh
./tools/zig build -Dtarget=aarch64-linux-gnu --prefix zig-out/linux-arm
```

A static-musl binary still runs the CLI, but `ui` cannot load system X11/GL.
On a normal Linux host, `./tools/zig build` targets the host glibc and works.

## Surface

- `src/platform/linux/x11.zig` — Xlib display/window/events, GLX visual and
  context, key handling, `--smoke`.
- `src/platform/linux/gl.zig` — runtime-loaded OpenGL 3.3 renderer, one
  instanced `GL_TRIANGLE_STRIP` draw, R8 atlas upload, straight-alpha blend.
- `src/platform/linux/ui.vert.glsl` / `ui.frag.glsl` — the same shader as the
  WebGL frontend, adapted to desktop GLSL 330.
- Keys: `1`–`5` screens, `t` theme, `q`/Escape quit; the window manager close
  button uses `WM_DELETE_WINDOW`.

## Evidence

Headless Xvfb smoke (no window mapped):

```text
linux smoke: X11/GLX context and one frame rendered offscreen
xvfb_smoke: PASS
```

A mapped native window was rendered under Xvfb and captured for
`docs/ui/screenshots/p6-linux.png` using the healthy replay fixture: 1,444
events, four CPUs, 1,040 switches, capabilities and session counters all
visible.

## Limits

- Fixed 1280×720 at 1× scale; no resize/Retina equivalent yet.
- No accessibility tree or pointer hit-testing; keyboard navigation only.
- Native live streaming remains web-only; replay/gallery are native.
- No packaging artifact yet beyond the `zig-out` install tree.
