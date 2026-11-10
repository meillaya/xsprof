# Zig 0.17 API notes used by this repository

Pinned toolchain: **0.17.0**, fetched and verified by `./tools/bootstrap.sh` into
`.tools/zig-0.17.0/` and invoked through `./tools/zig` (`XSPROF_ZIG` overrides it
for hermetic Nix/CI builds). The vendored stdlib text corpus was removed in the
repository diet; the canonical reference is the pinned toolchain itself:

```sh
./tools/zig env          # prints version, lib_dir, std_dir, global cache dir
grep -r 'pub fn' .tools/zig-0.17.0/lib/std/    # the actual standard library
```

Check `lib_dir` from `./tools/zig env` rather than assuming a path. This file
records only project-specific 0.17 usage; it is not a language reference.

## Entrypoint and process

- Executables use `pub fn main(init: std.process.Init) !void` or an
  `!u8`-style exit via `std.process.exit`.
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
  .check })`, and `b.addSystemCommand`.
- First-party packages use `.dependencies = .{ .xsui = .{ .path = "lib/xsui" } }`
  in `build.zig.zon` and `b.dependency("xsui", .{ .target, .optimize })` in
  `build.zig`; exported modules are retrieved with `dep.module("xsui")`.
- `@cImport` is removed in 0.17. C ABI access is written as `extern` / `extern
  "c"` declarations, `std.DynLib` (`dlopen`), or the Objective-C runtime.
  `std.Build.Step.TranslateC` is deprecated; this project does not use it.

## Language/build changes observed while porting

- `@backingInt` / `@fromBackingInt` replace `@intFromEnum` / `@enumFromInt`
  for explicit backing integers.
- `@hasDecl` is true only for public declarations.
- `@bitCast` uses logical representation and rejects extern structs.
- `std.lang.Optimize` replaces `std.lang.OptimizeMode`; `std.lang.Type` is the
  reflection home.
- `void{}` is gone; use `.{}`.
- `errdefer |capture|` capture is gone. Array multiplication syntax is gone.

## Stdlib facilities this repository relies on

- `std.Io` and `std.Io.Writer`/`Reader` for streaming, bounded writers, and
  canonical output.
- `std.json` for untrusted input parsing with bounded depth/length; the
  project's canonical writer remains hand-written for byte stability.
- `std.Thread`, `std.Thread.Pool`, and `std.Thread.WaitGroup` for capture and
  render threads (bounded queues; no per-frame allocation churn).
- `std.DynLib` for runtime-loaded X11/GL and the VM-only `libbpf` probe.
- `std.heap.smp_allocator` for the thread-shared live controller; arenas for
  per-frame/per-batch work.

## Known gaps to re-check when touching these areas

- Exact float/integer text formatting must match canonical wire bytes; see
  `src/core/json.zig` and the golden tests.
- Any stdlib API drift on a Zig upgrade must be resolved against the pinned
  stdlib, not guessed. Follow the runbook in
  [maintaining.md](maintaining.md#zig-pin-upgrade-runbook).
- Do not reintroduce vendored stdlib text, `@cImport`, or a C shim to work
  around an API change.
