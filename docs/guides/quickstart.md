# Quickstart

`xsprof` is a read-only Linux scheduler flight recorder: it opens perf
tracepoints, reads `/proc`/`/sys`, keeps a bounded compact-segment window on
disk, and writes evidence only to its own files. Every serialized record carries
`host_mutation=false`. The native viewer is optional.

## 1. Get the binary

With Nix:

```sh
nix run github:meillaya/xsprof -- version
```

From a checkout:

```sh
./tools/zig build
./zig-out/bin/xsprof version
```

See [install](install.md) for AppImage/deb/tarball artifacts and the NixOS
module.

## 2. Check what this host can collect

```sh
xsprof doctor
xsprof doctor --json
```

`doctor` reports kernel, perf, tracefs, cgroup, PSI, and libbpf readiness. A
`SKIP`/`REFUSE` state always includes a reason; nothing is elevated or changed.
Live capture needs perf tracepoints plus `CAP_PERFMON` (or
`perf_event_paranoid <= 1`) and readable tracefs — see
[recording permissions](capture-permissions.md).

## 3. Capture 10 seconds and explain it

```sh
xsprof record --duration 10s --output session.ndjson
xsprof why --input session.ndjson
xsprof why --input session.ndjson --json
```

`record` writes canonical `xsprof/event/v1` NDJSON plus a
`xsprof/capture-summary/v1` line on stderr. Missing permissions produce
`SKIP`/`REFUSE` with a reason and a non-zero exit; no fake data is written.

`top` gives the live ranked view without writing a file:

```sh
xsprof top
xsprof top --duration 10s --interval 250ms --json
```

## 4. Run a rolling recorder

The recorder keeps one capture open and rotates compact `.xsraw` segments under
a bounded retention window. Keep the last ten minutes (age cap and byte budget
both apply):

```sh
sudo xsprof daemon --foreground --dir /var/lib/xsprof \
  --retain 10m --max-bytes 2G
```

The daemon writes only its state directory. SIGTERM/Ctrl-C is a cooperative
stop that closes the active segment and marks the manifest `stopped`. Run it
under systemd or the NixOS module for a long-lived host; see
[recording permissions](capture-permissions.md) and
[flight recorder](flight-recorder.md).

## 5. Bundle the incident

```sh
sudo xsprof incident --last 10m --dir /var/lib/xsprof --out incident/
xsprof verify --dir /var/lib/xsprof --json
```

`incident` writes a self-contained offline bundle: `window.ndjson`,
`summary.json`, `report.html`, and `trace.json` (Chrome Trace; open it in
Perfetto or `chrome://tracing`). Lost or trimmed data is reported explicitly —
never zero-filled. `verify` decodes every segment and exits 0 only when the
state directory verifies READY.

## 6. Viewer (optional)

```sh
xsprof demo                                      # bundled replay fixture
xsprof ui --replay session.ndjson
xsprof ui --follow-recorder /var/lib/xsprof      # read-only attach
```

The viewer needs a graphical Linux or macOS session. macOS is viewer-only: it
can replay and follow a recorder but cannot capture scheduler events. There is
no browser or server surface.

## Next

- [Install](install.md) · [Recording permissions](capture-permissions.md)
- [Flight recorder](flight-recorder.md) · [top & why](top-why.md)
- [Compare captures in CI](compare-ci.md) · [Safety invariants](../safety/invariants.md)
