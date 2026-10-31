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

No window is opened by this command.
