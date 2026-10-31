# UI screenshots

Generated headlessly with:

```sh
./zig-out/bin/xsprof snapshot --out /tmp/xsprof-demo.png --width 1280 --height 720
```

`p2-demo.png` is the P2 kernel checkpoint (compressed for the repository; the
runtime PNG writer uses uncompressed zlib stored blocks and is optimized in a
later phase). It exercises the bundled JetBrains Mono rasterizer, glyph atlas,
rounded panels, semantic status colors, and dense operator layout.

No window is opened by this command.
