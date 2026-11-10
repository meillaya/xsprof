# Flight recorder

The recorder keeps one read-only perf capture open, writes bounded append-only
compact segments, and lets you extract the recent window after an incident.
This is the core product; the viewer is optional.

`--retain` is an upper age bound, not the retained duration: `--max-bytes` can
bind first, and the actual covered span is reported from the manifest.
Compact `.xsraw` segments cost roughly 12–13 bytes/event (versus ~160 canonical
NDJSON bytes/event), so the default 2 GiB budget usually lets the ten-minute
age cap bind. Higher event rates shorten the span; `capture`/`verify` always
report what was actually retained. See
[retention](../architecture/retention.md) for the measurement model.

## Start a recorder

```sh
sudo xsprof daemon --foreground --dir /var/lib/xsprof \
  --retain 10m --max-bytes 2G
```

Useful options:

- `--preset scheduler|memory|deep` selects an event mask and ring budget.
- `--duration <ms>` stops after a bounded test run (0/default: until stopped).
- `--history-interval 60s` and `--history-retain 24h` control the sidecar tier.

The daemon writes `manifest.json`, `lock`, and compact `segments/*.xsraw` under
the state directory. It is the only long-running process, writes only that
directory, and never changes host policy. Run it under systemd or the NixOS
module for a long-lived host ([install](install.md),
[recording permissions](capture-permissions.md)).

## Rotation and recovery

- Segments rotate at 16 MiB or 30 seconds.
- Retention drops the oldest closed segments when the byte or age budget is
  exceeded and writes an explicit `retention_loss` marker.
- SIGTERM/Ctrl-C is cooperative: the daemon closes the segment footer, writes
  `capture_stop signal=terminated`, flushes the history bucket, and marks the
  manifest `stopped`.
- After a SIGKILL, the next start scans `segments/` and reconciles it with the
  manifest: an unmanifested `.xsraw` segment written before a crash (between
  create and manifest rename) is adopted and counted in one
  `capture_recovered_orphan adopted=…` marker. The stale segment is marked
  closed, `capture_interrupted previous_session=<id>` is added, and a
  `capture_truncated_tail` marker is written when the footer is missing. The
  complete prefix is kept and never zero-filled.
- A corrupt block stops decoding at that block and is reported, never guessed.

`xsprof verify --dir <state> [--json]` decodes every segment with the same
reader extraction uses and reports clean/dirty/corrupt/missing/unsupported. Exit
0 only when the state verifies READY.

## History tier

Sidecars are written from an in-memory metrics accumulator every
`--history-interval` (default 60 s) and retained for `--history-retain` (default
24 h). Each bucket has CPU busy, switch, wakeup, migration, fault, and top-task
p95 wait metrics. This keeps long-horizon history bounded instead of one file
per rotation.

```sh
xsprof history --last 10m --dir /var/lib/xsprof
xsprof history --last 1h --dir /var/lib/xsprof --json
```

The history tier survives raw drops, but it does not retract the raw-window
limit: it is aggregates, not event detail.

## Extract a window

```sh
xsprof capture --last 5m --dir /var/lib/xsprof --out incident.ndjson
xsprof capture --last 30s --dir /var/lib/xsprof
xsprof advise --input incident.ndjson --md
```

Extraction converts the wall-clock cutoff using each segment's wall and
monotonic anchors, decodes compact blocks (or legacy lines), and emits explicit
markers for missing, corrupt, torn-tail, unsupported, or trimmed history. It
never fills gaps with zeroes. Bounds:

- `--markers-only` emits just loss/gap rows for bounded audits.
- `--max-events` and `--max-window-bytes` bound huge windows with a
  `capture_truncated` marker.
- `incident --max-window-bytes` bounds the canonical window artifact.

## Bundle the incident

```sh
xsprof incident --last 10m --dir /var/lib/xsprof --out incident/
```

The output folder is self-contained and offline:

- `window.ndjson` — sanitized raw window, including metadata and loss markers;
- `summary.json` — canonical counts, signals, rule statuses, findings, top
  tasks;
- `report.html` — static report with inline CSS, no scripts/server/network;
- `trace.json` — Chrome Trace export (open in Perfetto or `chrome://tracing`).

The summary records both the requested and the actually retained wall window.
When the byte budget or age cap trimmed older history, `window.trimmed` is true
and the report says so. `window.ndjson` is streamed to disk and the summary is
computed with a bounded-memory scan. The trace keeps at most 200,000 events;
`summary.json`/the report set `trace.truncated` and say so when that prefix is
used.

## Watch over SSH

```sh
xsprof watch --dir /var/lib/xsprof --window 30s
xsprof watch --dir /var/lib/xsprof --once
```

`watch` rebuilds the recent window through the same metrics index as the
viewer, showing CPU busy/idle, switches, loss, and tasks by p95
wakeup-to-run latency. It is ANSI-only and never needs a display server.

## Privacy

The recorder stores scheduler events and comm names, not argv or environment.
Compact strings are stored after the same privacy redaction as the
canonical serializer, so the state directory never holds secrets. Keep it
private. `host_mutation=false` appears in every manifest, summary, and extracted
row; the binary segment format has no mutation field at all.

## Verification evidence

Root-only recorder gates (live capture, service start/SIGKILL recovery,
retention budget) run in a disposable Linux VM via `./tools/zig build check-vm`
and are documented in [maintaining](../maintaining.md). Measured evidence is
attached to releases, not committed to git.
