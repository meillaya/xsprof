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
- `PERF_RECORD_LOST` becomes one explicit `sample_loss` marker; it is never
  interpolated or counted twice.
- `PERF_COUNT_SW_PAGE_FAULTS_MIN` and `MAJ` are separate rings; `page_fault.b`
  is `1` for major and `0` for minor. A combined-counter fallback is explicit.
- `Capture.take()` sorts each drained batch by timestamp/CPU/kind/pid before
  returning it. Perf rings are independent, so ring order alone is not time
  order. Legacy journals may still report `out_of_order` on replay.
- SIGTERM/SIGINT is a cooperative stop: the daemon flushes the active segment,
  writes `capture_stop signal=terminated`, and marks the manifest stopped.

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

## Native live view (optional viewer)

When capture is enabled in Settings, the viewer starts one in-process read-only
recorder (compact `.xsraw` segments) and tails those segments through
`src/platform/follow_source.zig` for the live view. It:
- gates on `live.probe` READY before starting;
- keeps a bounded feed/index and rebuilds the model at most about 4 times per
  second;
- re-serializes canonical NDJSON for the UI, preserving the selected screen and
  remapping selection by stable keys;
- emits explicit `sample_loss`/`retention_loss` markers on trim, corrupt
  blocks, or caps;
- never opens a network surface, never kills an external recorder, and writes
  only its state directory.

External recorders are attach-only: `xsprof ui --follow-recorder DIR` tails
the same compact/legacy segments without opening a capture. The CLI `record`
remains the full-fidelity evidence path. macOS has no perf backend and reports
live capture as SKIP; it still supports follow-recorder over an exported state
directory ([macOS viewer](../platforms/macos-viewer.md)).
