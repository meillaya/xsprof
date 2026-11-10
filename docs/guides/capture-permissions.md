# Recording permissions

xsprof is read-only, but live capture still needs the kernel's perf/tracepoint
permissions. A normal desktop user often cannot start a capture:

- `/proc/sys/kernel/perf_event_paranoid` is usually `2` or higher;
- `/sys/kernel/tracing` is usually `0700 root:root`;
- the user process has no `CAP_PERFMON` or `CAP_DAC_READ_SEARCH`.

Every capture path fails closed with `SKIP`/`REFUSE` and the exact reason. It
never elevates or changes host policy itself. Pick one of these operator-owned
paths. The native viewer is optional; all of this works with the CLI alone.

## Option A — grant the binary capabilities

For a single binary you trust (for example an installed release):

```sh
BIN=$(command -v xsprof)
sudo setcap cap_perfmon,cap_dac_read_search+ep "$BIN"
getcap "$BIN"
xsprof record --duration 10s --output session.ndjson
```

The capability is attached to that file: rebuilding or reinstalling loses it.
Never put capabilities on a copy you do not trust. If you use the viewer,
enable capture in Settings and use the Recorder screen; the CLI and the viewer
share the same probe and fail-closed reasons.

## Option B — privileged recorder, unprivileged consumer

No capability change to the binary you run as a user:

```sh
sudo xsprof daemon --foreground --dir /var/lib/xsprof \
  --retain 10m --max-bytes 2G
```

In another terminal (or over SSH):

```sh
xsprof why --last 10m --dir /var/lib/xsprof
xsprof incident --last 10m --dir /var/lib/xsprof --out incident/
xsprof ui --follow-recorder /var/lib/xsprof    # viewer, read-only attach
```

The recorder writes only its own state directory; consumers read it. Stop the
daemon with Ctrl-C/SIGTERM for a clean, cooperating shutdown.

## Option C — systemd service

The packaged unit runs as the unprivileged `xsprof` user with only
`CAP_PERFMON` and `CAP_DAC_READ_SEARCH`:

```sh
sudo install -Dm755 "$(command -v xsprof)" /usr/local/bin/xsprof
sudo install -Dm644 packaging/sysusers/xsprof.conf /etc/sysusers.d/xsprof.conf
sudo systemd-sysusers /etc/sysusers.d/xsprof.conf
sudo install -Dm644 packaging/systemd/xsprof-recorder.service \
  /etc/systemd/system/xsprof-recorder.service
sudo sed -i 's#/usr/bin/xsprof#/usr/local/bin/xsprof#' \
  /etc/systemd/system/xsprof-recorder.service
sudo systemctl daemon-reload
sudo systemctl enable --now xsprof-recorder
xsprof verify --dir /var/lib/xsprof --json
```

On NixOS, use the module instead (`services.xsprof.recorder.enable = true`) —
see [install](install.md). Both apply the same hardening and reject mutation
verbs in extra arguments.

## Verify the state

```sh
xsprof doctor --json
```

`READY` requires perf access, tracefs, and the capture source to report READY.
Missing pieces produce `SKIP`/`REFUSE` with the reason. `top`, `record`, and
`daemon` exit non-zero when they cannot capture; they never fabricate data or
write a partial claim.

## Notes

- `perf_event_paranoid=2` can be sufficient when `CAP_PERFMON` is present;
  lowering the sysctl is an operator decision, not something xsprof does or
  recommends as a shortcut.
- Container/VM hosts need the capability inside the container and readable
  tracefs. The project's own VM gates are documented in
  [maintaining](../maintaining.md); they are not a requirement for users.
- The recorder writes comm names and events, not argv or environment. Keep the
  state directory private even though privacy redaction runs at serialization.
