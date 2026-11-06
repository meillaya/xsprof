# Record a rolling window

The recorder keeps one perf capture open, writes bounded append-only segments,
and lets you extract the recent window after an incident.

`--retain` is an upper age bound, not the retained duration: `--max-bytes` binds
first. The real 1.2 s macOS-VM capture is 17.5 MB, or about 15 MB/s, so the
default 2 GiB budget holds roughly 2–3 minutes at that rate. Raise
`--max-bytes` or reduce the event mask for a longer window. The Capture screen
shows the actual retained wall span (`X covered · cap Y`) from the manifest,
not the configured cap; an extract older than the retained data carries a
`retention_loss` marker instead of being zero-filled.

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

`--preset scheduler|memory|deep` selects an event mask and ring budget.
`--duration <ms>` stops after a bounded test run. The daemon writes
`manifest.json`, `lock`, and `segments/*.ndjson` under the state directory.
Segments rotate at 16 MiB or 30 seconds. Retention drops the oldest closed
segments when the byte or age budget is exceeded and writes a
`retention_loss` marker.

SIGTERM/SIGINT is a cooperative stop: the daemon flushes the active segment,
writes `capture_stop signal=terminated`, flushes the history bucket, and marks
the manifest `stopped`. If the process is killed, the next start marks the stale
segment closed, adds `capture_interrupted previous_session=<id>`, and starts a
new segment without discarding the earlier history.

History sidecars are written from an in-memory metrics accumulator every
`--history-interval` (default 60 s) and retained for `--history-retain` (default
24 h). Each sidecar has CPU busy, switch, wakeup, migration, fault, and top-task
p95 wait metrics. This keeps the long-term history tier bounded instead of
creating one file per segment rotation. `xsprof history` queries the sidecars
across raw retention; the console and advisor still analyze the extracted raw
window.

## Extract a window

```sh
./zig-out/bin/xsprof capture --last 5m --dir /var/lib/xsprof --out incident.ndjson
./zig-out/bin/xsprof capture --last 30s --dir /var/lib/xsprof
./zig-out/bin/xsprof advise --input incident.ndjson --md
```

The extractor converts the wall-clock cutoff using each segment's wall and
monotonic anchors, keeps only complete lines, and emits explicit markers for
missing, corrupt, or trimmed history. It never fills gaps with zeroes. Session
metadata (recorder identity, CPU LLC topology, and the buddyinfo snapshot) is
kept even when its capture-start timestamp is older than the window.

## Bundle the incident

```sh
./zig-out/bin/xsprof incident --last 10m --dir /var/lib/xsprof --out incident/
```

The output folder is self-contained and offline:

- `window.ndjson` — the sanitized raw window, including metadata and loss markers
- `summary.json` — canonical counts, signals, rule statuses, findings, top tasks
- `report.html` — static report with inline CSS and relative artifact links; no
  scripts, server, telemetry, or network requests
- `trace.json` — Chrome Trace export

The summary records both the requested and the actually retained wall window.
If the byte budget dropped older history, `window.trimmed` is true and the
report says so instead of implying full coverage. `window.ndjson` is streamed
to disk and the summary is computed with a bounded-memory scan over the whole
window. `trace.json` keeps at most 200,000 events; `summary.json` and the
report set `trace.truncated` and say so when that prefix is used.

## Query sidecar history

```sh
./zig-out/bin/xsprof history --last 10m --dir /var/lib/xsprof
./zig-out/bin/xsprof history --last 1h --dir /var/lib/xsprof --md
```

This timeline survives raw segment drops, so it can cover a longer period than
the 2 GiB raw window. It reports switches, wakeups, unnecessary wakeups,
migrations, faults, loss, and CPU busy time per sidecar. It does not retract
the raw-window limit; it is the history tier next to the raw tier.

## Watch over SSH

```sh
./zig-out/bin/xsprof watch --dir /var/lib/xsprof --window 30s
./zig-out/bin/xsprof watch --dir /var/lib/xsprof --once
```

`watch` rebuilds the recent window through the same metrics index as the UI. It
shows CPU busy/idle, switches, loss, and tasks by p95 wakeup-to-run latency.
`--once` prints one frame and exits.

## Service-level smoke

`qa/service_smoke.sh` runs as root on a disposable Linux VM with systemd. It
starts a transient unit with the packaged service's user, capability set,
read-only paths, and state directory; records a bounded window; checks the
single-writer lock; extracts with `capture --last`; SIGKILLs a session; and
verifies restart recovery keeps the earlier segments. It never lowers
`perf_event_paranoid` or changes tracefs policy. It requires `doctor` to report
`perf` READY through `CAP_PERFMON`.

```sh
./tools/zig build service-smoke    # Linux host, run as root
```

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
