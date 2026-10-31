# UI screenshots

Generated headlessly with:

```sh
./zig-out/bin/xsprof snapshot --out /tmp/xsprof-demo.png --width 1280 --height 720
```

`p2-gallery.png` is the P2 layout checkpoint, generated from the same
`src/app/gallery.zig` view that owns the golden framebuffer hash. It exercises
the flex layout, reusable panels/chips/stat cards, custom chart paint nodes,
the bundled JetBrains Mono rasterizer, semantic status colors, and dense
operator layout. The runtime PNG writer uses uncompressed zlib stored blocks;
the committed screenshot is compressed for review.

`p3-web-overview.png` and `p3-web-timeline.png` are headless Chromium captures
of the wasm/WebGL2 replay client served by `xsprof serve` (P3). No window is
opened by `snapshot`; the browser check was run explicitly by the agent with
Playwright headless Chromium.

`p4-live-web.png` is a headless Chromium capture of `serve --live` inside the
disposable Linux VM: LIVE capability READY, real perf events, downsampled loss
markers, and browser-side incremental rendering.

`p6-linux.png` is a native X11/OpenGL frame rendered under Xvfb from the
healthy replay fixture (no browser, no window manager).

`p3-web-timeline-selected.png` shows a clicked CPU slice with the selected task
detail row: p95 wait, off-CPU p95, and switch count.
