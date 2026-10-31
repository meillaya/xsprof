# Live capture (Linux, read-only)

`xsprof record` uses `perf_event_open` on the sched tracepoints plus the
software page-fault counter. It never writes scheduler state.

## Probe and failure posture

- `perf_event_paranoid > 1` → SKIP with the exact reason.
- tracefs sched format unreadable → REFUSE.
- No events opened → SKIP.
- Non-Linux → SKIP.
- Every path exits non-zero on SKIP/REFUSE and prints a capability event with
  `host_mutation=false`.
- `--bpf` remains VM-marker-gated and is a P7 lane; it reports SKIP today.

## Implementation

- `src/capture/live.zig`: raw `perf_event_open`, per-CPU mmap rings, streaming
  record parser, tracepoint format offset parser, lost-record markers.
- `record` writes canonical NDJSON `xsprof/event/v1` rows and a
  `xsprof/capture-summary/v1` line to stderr.
- Perf header sizes are read at byte 6 (type:u32, misc:u16, size:u16); sample
  fields are TID/TIME/CPU/RAW in kernel order.
- `PERF_RECORD_LOST` becomes an explicit `sample_loss` marker; it is never
  interpolated.

## VM validation (2026-10-31)

Disposable podman Linux VM, kernel `7.2.7-200.fc44.aarch64`, 4 vCPUs,
tracefs mounted, `kernel.perf_event_paranoid=1`, binary cross-compiled for
`aarch64-linux`:

```text
{"capability":"READY","duration_ms":300,"events_captured":73648,
 "host_mutation":false,"page_faults":4971,"sched_migrations":3,
 "sched_switches":68631,"sched_wakeups":41,
 "schema":"xsprof/capture-summary/v1","source":"perf_tracepoint"}
```

A simultaneous tracefs count during the same capture was 69,580
`sched_switch` entries, matching the 68,631 switch records (sampling itself
raises scheduler activity in this nested VM). Events had unique timestamps,
printable-ASCII comms, increasing ns timestamps, and valid UTF-8 JSON.

The host (macOS) and any unprivileged Linux host report SKIP and exit 1; this
is the tested fail-closed behavior.

## Live SSE and the browser

`xsprof serve --live` starts a capture worker that repeatedly opens the perf
rings, downsamples (every 80th event) into a bounded 8 MiB store, and emits an
explicit `sample_loss live_downsample dropped=N` marker per batch. Endpoints:

- `/api/journal` — current snapshot for initial load.
- `/api/events` — one-shot SSE batches with `id:` offsets and `Last-Event-ID`
  resume; an `event: reset` frame tells the client to reload after trimming.
- `/api/meta` — `source:"live"`.

The browser appends SSE lines through `web_append_journal`, re-renders while
preserving the active screen, and reloads on reset. Verified in the VM with a
headless Chromium screenshot: LIVE READY capability, 51k+ events, 4 CPUs,
loss markers, `host_mutation=false`.

The worker downsamples for UI responsiveness; the CLI `record` remains the
full-fidelity evidence path.
