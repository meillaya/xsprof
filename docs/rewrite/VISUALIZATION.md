# VISUALIZATION — Interactive Timeline (Chrome Trace Event Format)

Research deliverable for mission `cpp-sched-mem-profiler`. The visualization sink produces an
interactive timeline in the Chrome Trace Event Format, openable in `chrome://tracing` and the
Perfetto UI, where a user can scrub through every thread, every CPU, every syscall/scheduling event,
and memory allocations.

## 1. Why Chrome Trace Event Format

It is a stable, widely-supported JSON schema (`{"traceEvents":[...]}`) that gives an interactive,
zoomable, scrubber-driven timeline with per-process/per-thread rows, flow arrows, and async events —
exactly the "Chrome Trace Viewer"-style UX in the vision, without shipping a bespoke renderer. The
exporter is the framework's default viz artifact; a Perfetto-protobuf exporter is a later milestone.

## 2. Row model

- **One process row group per observed PID**, with a thread lane per TID (`name = comm`).
- **One row group per CPU** showing run-queue occupancy and the currently running task as duration
  events (`ph:"X"`), so the user sees what ran where over time.
- **Memory lane** per thread for allocation/free spans and page-fault markers.

## 3. Event mapping

| Domain | Trace event |
| --- | --- |
| task running on CPU | `X` (complete) duration event on the CPU lane, `name=comm`, args: pid,tid,prio |
| context switch | boundary between two `X` events + a flow event linking prev->next |
| wakeup -> switch | `s`/`f` flow events (wakeup source to first switch of the woken task) |
| migration | flow event from orig_cpu lane to dest_cpu lane |
| page fault / TLB / cache miss | `i` (instant) event on the thread lane, args: address region, kind |
| malloc/free hotspot | `X` spans (alloc lifetime) + instant markers at hot sites |
| advisor finding | `N`/annotation overlay at the relevant time range with the finding id |
| sample loss / gap | red `i` marker + a metadata row; never interpolated (unsafe/incomplete signal) |

## 4. Scrubbing & scale

- Time base is perf-clock nanoseconds; the exporter writes `ts` in microseconds (Chrome convention)
  and a `systemTraceEvents`/`metadata` block describing CPUs and topology so the UI can label rows.
- For long captures the exporter supports **chunked** output (Perfetto-style multiple JSON arrays or
  a sliced `traceEvents` window) so multi-gigabyte sessions remain openable.
- A `--window start:end` flag exports a sub-range for focused inspection.

## 5. Determinism & replay

Mirroring the Zig daemon's replay discipline, the exporter can consume a recorded JSONL evidence
journal instead of a live pipeline, producing a byte-stable timeline for a given fixture. Lost,
gapped, or truncated streams render as explicit unsafe markers rather than smoothed progress.

## 6. Privacy in the timeline

Comm/argv/env are subject to the same privacy filter as the journal: the timeline shows bounded comm
strings and redacts secret-like args. A `--redact-comms` flag further pseudonymizes task names.

## 7. Evidence vs. inference

Grounded: the Chrome Trace Event Format (`ph` types X/i/s/f/N, `ts`/`dur`/`pid`/`tid`/`name`/`args`)
is a documented public schema; flow events are the standard mechanism for wakeup/migration arrows.
Assumption (labeled): very large captures are best served by Perfetto protobuf for smooth scrubbing;
the JSON exporter targets captures up to a few hundred MB before chunking/protobuf is preferred.
