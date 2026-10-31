# Bundled fonts

The UI bundles **JetBrains Mono** Regular and Bold (OFL 1.1). The files are
unmodified upstream TTFs; the license text is `OFL.txt`.

- Upstream: https://github.com/JetBrains/JetBrainsMono
- Regular SHA-256: `e6fd0d7e91550b3ed2b735d4312474362c4716edc4fc0577a0f61ed782d5aed1`
- Bold SHA-256: `d22c4f3821d725eb01210d278d95dfcfcaadc34699a06658d47c8a5cc5830ada`
- License SHA-256: `a76abf002c49097d146e86740a3105a5d00450b1592e820a1109a8c5680cd697`

They are assets, not code dependencies. The UI rasterizes them with the
in-repo TrueType reader (`lib/xsui/src/ttf.zig`); no system font or shaping
library is required. Latin-1/ASCII is the supported set for v1.
