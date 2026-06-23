# Zig 0.16 API usage ledger

This ledger records targeted local Zig 0.16 stdlib citations for root backend Zig files touched by VM-lab-evidence work. Do not paste bulk stdlib excerpts; cite the local vendored source/reference files by path and line.

Verified vendor artifacts:
- `docs/vendor/zig-0.16.0/zig-0.16.0-stdlib-reference.txt`
- `docs/vendor/zig-0.16.0/zig-0.16.0-stdlib-sources.txt`

## Current control surfaces

| Zig file | API | Local Zig 0.16 citation | Note |
| --- | --- | --- | --- |
| `src/control/protocol.zig` | `std.json.parseFromSlice` | `docs/vendor/zig-0.16.0/zig-0.16.0-stdlib-reference.txt:55558` | Confirms parse API used for strict action JSON parsing with `ignore_unknown_fields=false`. |
| `src/control/protocol.zig` | `std.ArrayList` | `docs/vendor/zig-0.16.0/zig-0.16.0-stdlib-reference.txt:84706` | Confirms `std.ArrayList(T)` constructor alias used for JSON buffer assembly. |
| `src/control/protocol.zig` | `std.Io.Writer.Allocating.fromArrayList` | `docs/vendor/zig-0.16.0/zig-0.16.0-stdlib-reference.txt:7381` | Confirms allocating writer construction from an existing `ArrayList(u8)`. |
| `src/control/daemon.zig` | `std.ArrayList` | `docs/vendor/zig-0.16.0/zig-0.16.0-stdlib-reference.txt:84706` | Confirms daemon tests' buffer type. |
| `src/control/daemon.zig` | `std.Io.Writer.Allocating.fromArrayList` | `docs/vendor/zig-0.16.0/zig-0.16.0-stdlib-reference.txt:7381` | Confirms daemon tests' writer construction. |
| `src/control/stream.zig` | `std.json.parseFromSlice` | `docs/vendor/zig-0.16.0/zig-0.16.0-stdlib-reference.txt:55558` | Confirms runtime sample parser API. |
| `src/control/stream.zig` | `std.ArrayList` | `docs/vendor/zig-0.16.0/zig-0.16.0-stdlib-reference.txt:84706` | Confirms stream output/event buffers. |
| `src/control/stream.zig` | `std.Io.Writer.Allocating.fromArrayList` | `docs/vendor/zig-0.16.0/zig-0.16.0-stdlib-reference.txt:7381` | Confirms event serialization writer construction. |
| `src/daemon_main.zig` | `std.Io.net.UnixAddress.init` | `docs/vendor/zig-0.16.0/zig-0.16.0-stdlib-reference.txt:7704` | Confirms local Unix socket address construction for the backend JSON-RPC daemon lane. |
| `src/daemon_main.zig` | `std.Io.net.UnixAddress.listen` | `docs/vendor/zig-0.16.0/zig-0.16.0-stdlib-reference.txt:7716` | Confirms Unix-domain socket listener construction. |
| `src/daemon_main.zig` | `std.Io.net.Server.accept` | `docs/vendor/zig-0.16.0/zig-0.16.0-stdlib-reference.txt:7919` | Confirms blocking local socket accept semantics for deterministic one-client QA. |
| `src/daemon_main.zig` | `std.Io.net.Stream.reader` / `writer` | `docs/vendor/zig-0.16.0/zig-0.16.0-stdlib-reference.txt:7908` | Confirms stream reader/writer construction for JSON-RPC lines. |
| `src/daemon_main.zig` | `std.json.parseFromSlice` | `docs/vendor/zig-0.16.0/zig-0.16.0-stdlib-reference.txt:55558` | Confirms strict JSON-RPC request and replay event parsing. |
| `src/daemon_main.zig` | `std.Io.Dir.statFile` / `StatFileOptions.follow_symlinks` | `docs/vendor/zig-0.16.0/zig-0.16.0-stdlib-reference.txt:4676` | Confirms pre-unlink socket collision checks can stat without following symlinks. |
| `src/daemon_main.zig` | `std.Io.File.Kind.unix_domain_socket` | `docs/vendor/zig-0.16.0/zig-0.16.0-stdlib-sources.txt:33142` | Confirms existing socket paths are distinguished from regular files before unlink. |
| `build.zig` | `std.Build.addSystemCommand` | `docs/vendor/zig-0.16.0/zig-0.16.0-stdlib-reference.txt:205` | Confirms host-side QA command wiring for the backend client contract and socket RPC checks. |

## Source cross-checks

- `docs/vendor/zig-0.16.0/zig-0.16.0-stdlib-sources.txt:260047` contains the JSON static parse implementation area used by `std.json.parseFromSlice`.
- `docs/vendor/zig-0.16.0/zig-0.16.0-stdlib-sources.txt:34548` contains the `std.Io.Writer.Allocating.fromArrayList` implementation area.
- `docs/vendor/zig-0.16.0/zig-0.16.0-stdlib-sources.txt:68553` contains the `std.Io.net.UnixAddress` implementation used by the local socket daemon lane.
- `docs/vendor/zig-0.16.0/zig-0.16.0-stdlib-sources.txt:69157` contains the `std.Io.net.Server.accept` implementation used by the one-client socket QA surface.
- `docs/vendor/zig-0.16.0/zig-0.16.0-stdlib-sources.txt:26928` contains `std.Io.Dir.statFile`; `docs/vendor/zig-0.16.0/zig-0.16.0-stdlib-sources.txt:33142` contains `std.Io.File.Kind`, including `unix_domain_socket`.
