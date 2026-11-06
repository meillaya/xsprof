# UI screenshots

Generated headlessly with the native CPU snapshot path:

```sh
./zig-out/bin/xsprof snapshot --demo-model fixtures/ui/design/demo.json \
  --view overview --out /tmp/xsprof-demo.png --width 1280 --height 720
```

`p2-gallery.png` is the P2 layout checkpoint from the same
`src/app/gallery.zig` view that owns the golden framebuffer hash. It exercises
the flex layout, reusable panels/chips/stat cards, custom chart paint nodes, the
bundled JetBrains Mono rasterizer, semantic status colors, and dense operator
layout.

`p6-linux.png` is a native X11/OpenGL frame rendered under Xvfb from the
healthy replay fixture (no browser, no window manager).

The browser/WebGL2 screenshots (`p3-web-*`, `p4-live-web.png`) were removed in
0.5.0 with the Web surface. Native screenshot evidence is under
`design/screenshots/native/`; native offscreen showcase videos are under
`design/media/`. The frozen design prototype captures remain under
`design/screenshots/prototype/` as design input only.
