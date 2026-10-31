# Zig 0.17 API notes used by this repository

Pinned toolchain: **0.17.0**. Source references are line numbers in
`docs/vendor/zig-0.17.0/zig-0.17.0-stdlib-sources.txt`; grep file headers first.

## Entrypoint and process

- Executables use `pub fn main(init: std.process.Init) !void` or
  `!u8`-style exits via `std.process.exit`.
- `init.minimal.args.toSlice(arena)` yields the argument list.
- `init.arena`, `init.gpa`, `init.io`, `init.environ_map`, and `init.preopens`
  are the process-lifetime facilities.
- Stdout/stderr use `std.Io.File.Writer.init(.stdout(), io, &buffer)` and
  `interface.flush()`. `std.Io.Writer` has `print`, `writeAll`, `writeByte`,
  `fixed`, and `buffered`.

## Build system

- `b.createModule(.{ .root_source_file, .target, .optimize, .imports })` for
  private modules; `b.addModule` for exported modules.
- `b.addExecutable(.{ .name, .root_module })`; the process/entrypoint split is
  explicit in 0.17.
- `b.addTest(.{ .root_module })`, `b.addRunArtifact`, `b.addFmt(.{ .paths,
  .exclude_paths, .check })`, and `b.addSystemCommand`.
- WebAssembly executables set `root_module` with the wasm target,
  `entry = .disabled`, and `export_symbol_names` on the root module; exported
  Zig functions use `export fn`.
- `@cImport` is removed in 0.17. C ABI access is written as `extern` / `extern
  "c"` declarations, `std.DynLib` (`dlopen`), or the Objective-C runtime.
  `std.Build.Step.TranslateC` is deprecated in favor of the external
  `translate-c` package; this project does not use it.

## Language/build changes observed while porting

- `@backingInt` / `@fromBackingInt` replace `@intFromEnum` / `@enumFromInt`
  for explicit backing integers.
- `@hasDecl` is true only for public declarations.
- `@bitCast` uses logical representation and rejects extern structs.
- `std.lang.Optimize` replaces `std.lang.OptimizeMode`; `std.lang.Type` is the
  reflection home.
- `void{}` is gone; use `.{}`.
- `errdefer |capture|` capture is gone.
- Array multiplication syntax is gone.

## Stdlib facilities we rely on

- `std.Io` and `std.Io.net.Server` / `std.Io.net.Stream` for the local web
  bridge; `std.http.Server` handles one connection at a time.
- `std.json` for untrusted input parsing with bounded depth/length; the
  project's canonical writer remains hand-written for byte stability.
- `std.Thread`, `std.Thread.Pool`, and `std.Thread.WaitGroup` for the render
  and capture threads (the render thread is opt-in and measured).
- `std.crypto` for token generation and hash-based pseudonyms.
- `std.compress`/`std.tar` only in developer tooling, never at runtime.

## Known gaps to re-check when touching these areas

- Exact float text formatting must match the archived wire bytes where a golden
  exists; see `src/core/json.zig` and P1 tests.
- `std.http.Server` is single-connection; the accept loop and SSE fan-out are
  our responsibility.
- WASM has no libc/threads by default; the UI core must avoid both.
