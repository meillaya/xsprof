# Zig 0.17.0 vendored reference source

Retrieval date: 2026-10-31T09:53:00-04:00

These are grep-friendly, offline copies of the Zig 0.17.0 standard library and
language reference. They are reference material, not build inputs, and are not
executed by the project.

## Official upstream URLs

- Toolchain download index: https://ziglang.org/download/index.json
- Source tarball: https://ziglang.org/download/0.17.0/zig-0.17.0.tar.xz
- Language reference: https://ziglang.org/documentation/0.17.0/
- Standard library shell: https://ziglang.org/documentation/0.17.0/std/

## Pinned source tarball

SHA-256: `b6c7f1728f043700d6529bac980800792f824256a9d2f1839b3d62beed0b8abd`

## Generated artifacts

- `zig-0.17.0-stdlib-sources.txt` — every `lib/std/**/*.zig` file, in stable
  path order, with a boundary header per upstream file.
- `zig-0.17.0-stdlib-reference.txt` — source-derived public declaration index
  with adjacent `///` / `//!` documentation and per-file line numbers.
- `zig-0.17.0-langref.txt` — text extraction of the official language
  reference HTML.

The tarballs and HTML are cached under `.tools/downloads/` (gitignored). They
are not committed; the text artifacts and their checksums are.

## Regeneration

```sh
sh tools/vendor_stdlib.sh
sh qa/vendor_hash.sh
```

`tools/vendor_stdlib.py` is the generator. It uses only the Python standard
library and is not required to build or test xsprof.

## Checksums

`SHA256SUMS` is validated offline by `zig build vendor-check`. It covers
`SOURCE.md` and the three generated text artifacts. The source tarball hash is
pinned in `tools/vendor_stdlib.sh` and `tools/bootstrap.sh`.

## Limitations

The standard-library page is a dynamic documentation application. This
snapshot intentionally stores source-derived text instead of executing the
upstream JavaScript/WebAssembly. Treat the files as reference data only; do not
execute vendored documentation as build logic.
