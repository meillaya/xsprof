# Record the last ten minutes

The recorder keeps one perf capture open, writes bounded append-only segments,
and lets you extract the recent window after an incident.

## Prerequisites

- Linux with perf tracepoints and tracefs.
- `CAP_PERFMON` for `perf_event_open`.
- Read access to tracefs, granted by `CAP_DAC_READ_SEARCH` in the service unit.
- A real or virtual machine you control. The recorder runs on Linux only.

The unit in `packaging/systemd/xsprof-recorder.service` uses only those two
capabilities. Create the `xsprof` user and install the unit yourself; the CLI
never installs services or changes sysctls. Adjust the tracefs mount and
kernel policy through your normal provisioning.

## Foreground use

```sh
./zig-out/bin/xsprof daemon --foreground --dir /var/lib/xsprof \
  --retain 10m --max-bytes 2G
```

`--duration <ms>` stops after a bounded test run. The daemon writes
`manifest.json`, `lock`, and `segments/*.ndjson` under the state directory.
Segments rotate at 16 MiB or 30 seconds. Retention drops the oldest closed
segments when the byte or age budget is exceeded and writes a
`retention_loss` marker.

If the process is killed, the next start marks the stale segment closed, adds
`capture_interrupted previous_session=<id>`, and starts a new segment without
discarding the earlier history.

Each closed segment also gets a `metrics/<stem>.json` sidecar with CPU busy,
switch, wakeup, migration, fault, and top-task p95 wait metrics. The sidecar is
small enough to keep after raw retention drops the segment.

## Extract a window

```sh
./zig-out/bin/xsprof capture --last 5m --dir /var/lib/xsprof --out incident.ndjson
./zig-out/bin/xsprof capture --last 30s --dir /var/lib/xsprof
```

The extractor converts the wall-clock cutoff using each segment's wall and
monotonic anchors, keeps only complete lines, and emits explicit markers for
missing, corrupt, or trimmed history. It never fills gaps with zeroes.

## Watch over SSH

```sh
./zig-out/bin/xsprof watch --dir /var/lib/xsprof --window 30s
./zig-out/bin/xsprof watch --dir /var/lib/xsprof --once
```

`watch` rebuilds the recent window through the same metrics index as the UI. It
shows CPU busy/idle, switches, loss, and tasks by p95 wakeup-to-run latency.
`--once` prints one frame and exits.

## Diagnose

```sh
./zig-out/bin/xsprof doctor --json
```

`doctor` reports kernel, `perf_event_paranoid`, tracefs, perf, libbpf, and web
assets. It reports the reason and never executes a fix.

## State and privacy

The recorder stores scheduler events and comm names, not argv or environment.
Keep the state directory private. `host_mutation` is false in every segment,
summary, and manifest. `capture --last` output remains canonical
`xsprof/event/v1` NDJSON.
