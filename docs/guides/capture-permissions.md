# Recording on your PC (permissions)

xsprof is read-only, but live capture still needs the kernel's perf/tracepoint
permissions. A normal desktop user often cannot start a capture:

- `/proc/sys/kernel/perf_event_paranoid` is usually `2` or higher;
- `/sys/kernel/tracing` is usually `0700 root:root`;
- the user process has no `CAP_PERFMON` or `CAP_DAC_READ_SEARCH`.

The console fails closed with `SKIP`/`REFUSE` and the exact reason. It never
elevates or changes host policy itself. Pick one of these operator-owned paths.

## Option A — grant the binary capabilities (UI-owned recording)

This keeps the console running in your normal graphical session:

```sh
BIN=$(realpath ./zig-out/bin/xsprof)
sudo setcap cap_perfmon,cap_dac_read_search+ep "$BIN"
getcap "$BIN"
./zig-out/bin/xsprof ui
```

Then enable **Settings -> Enable capture controls** and press Start in
Recorder. The capability is attached to that binary file; rebuilding or
reinstalling loses it and you must re-run setcap. Do not set capabilities on an
untrusted copy.

## Option B — privileged recorder in a terminal, UI attached read-only

No capability change to the GUI binary:

```sh
STATE="$HOME/.local/state/xsprof-live"
sudo sh -c 'umask 022; exec ./zig-out/bin/xsprof daemon --foreground --dir "$0" --retain 10m --max-bytes 2G' "$STATE"
```

In another terminal, keep the UI as your normal user and attach:

```sh
./zig-out/bin/xsprof ui --follow-recorder "$HOME/.local/state/xsprof-live"
```

The recorder writes only its own state directory; the UI reads it. Stop the
daemon with Ctrl-C (SIGTERM is handled cleanly).

## Option C — systemd service

Install the binary, sysusers entry, and unit; point the unit at your installed
path:

```sh
sudo install -Dm755 "$(realpath ./zig-out/bin/xsprof)" /usr/local/bin/xsprof
sudo install -Dm644 packaging/sysusers/xsprof.conf /etc/sysusers.d/xsprof.conf
sudo systemd-sysusers /etc/sysusers.d/xsprof.conf
sudo install -Dm644 packaging/systemd/xsprof-recorder.service \
  /etc/systemd/system/xsprof-recorder.service
sudo sed -i 's#/usr/bin/xsprof#/usr/local/bin/xsprof#' \
  /etc/systemd/system/xsprof-recorder.service
sudo systemctl daemon-reload
sudo systemctl start xsprof-recorder
./zig-out/bin/xsprof ui --follow-recorder /var/lib/xsprof
```

The unit runs as the unprivileged `xsprof` user with only `CAP_PERFMON` +
`CAP_DAC_READ_SEARCH`, writes `/var/lib/xsprof`, and the console attaches
read-only. Check the state directory permissions before attaching; the UI only
reads. The `install` path is rebuild-stable, unlike capabilities on a repo
binary.

## Why the UI showed FAILED

That was a display bug: a probe SKIP/REFUSE was labelled `FAILED`. The current
code shows `SKIP` or `REFUSE` with the exact reason and the capture
requirements, and the Recorder screen offers the in-app exports instead of
"run it yourself" shell snippets.

## Verify

```sh
xsprof doctor --json     # perf_event_paranoid, CAP_PERFMON, tracefs
```

A `READY` status requires all three. `SKIP`/`REFUSE` always includes the
reason; no fake data is recorded.
