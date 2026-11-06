# Quickstart

`xsprof` is read-only: it opens perf tracepoints, reads `/proc`/`/sys`, and writes
only its own journals, reports, snapshots, settings, and audit files. Every
record carries `host_mutation=false`.

## 1. Launch the console

```sh
./tools/zig build
./zig-out/bin/xsprof
```

Bare `xsprof` opens the GPU console on an interactive graphical TTY. First run
shows the four-step onboarding overlay; later runs start at Home. The Home
source cards are Live, Recorder window, Replay file, and the bundled demo. The
GPU picker/text fields are part of the same draw list; no native file dialog is
used. Packaged app bundles set `XSPROF_APP_MODE=1` and always open the console.

For scripts and CI use an explicit verb, or set `XSPROF_NO_UI=1` to force the
quickstart path. Neither opens a window.

## 2. Try a bundled capture without privileges

```sh
./zig-out/bin/xsprof demo
```

This serves the bundled real capture on loopback with a token in the URL
fragment. Press `0` in the browser console to return Home, or use the route
keys shown in the keybar.

## 3. Live and recorder window

```sh
sudo ./zig-out/bin/xsprof ui --live --duration 0    # Linux perf, until stopped
./zig-out/bin/xsprof ui --follow-recorder /var/lib/xsprof
./zig-out/bin/xsprof ui --replay session.ndjson
```

The native UI starts its own in-process read-only recorder when capture controls
are enabled in Settings and the probe is READY. It writes compact `.xsraw`
segments and shows the actual covered span/loss. Without `CAP_PERFMON` or
readable tracefs the live action shows SKIP/REFUSE with the exact reason.
macOS has no perf backend; it supports replay and follow-recorder.

## 4. Recorder, verify, and exports

```sh
sudo ./zig-out/bin/xsprof daemon --foreground --dir /var/lib/xsprof \
  --retain 10m --max-bytes 2G
./zig-out/bin/xsprof verify --dir /var/lib/xsprof --json
./zig-out/bin/xsprof capture --last 10m --dir /var/lib/xsprof --out window.ndjson
sudo ./zig-out/bin/xsprof incident --last 10m --dir /var/lib/xsprof --out incident/
./zig-out/bin/xsprof history --last 10m --dir /var/lib/xsprof
```

The compact raw tier is designed to keep ten minutes at the configured byte
budget; the age cap, byte budget, and workload determine the real span. The UI
and `verify` report that span, never the configured cap. Oversized incident
windows refuse instead of silently truncating.

## 5. Check this host

```sh
./zig-out/bin/xsprof doctor
./zig-out/bin/xsprof doctor --json
```

A `SKIP`/`REFUSE` state always includes a reason. The tool never elevates or
changes host policy. `help --all` lists the hidden automation verbs.
