# Event field semantics

Every capture line is a canonical `xsprof/event/v1` object. The packed fields
`a`, `b`, and `c` are not generic arguments: their meaning depends on the event
kind. Consumers must not infer the task from `pid` alone. Use `a` plus `comm`
for the subject, and the `subjectPid()` / `actorPid()` helpers in
`src/core/event.zig` when a single pid is needed.

## Common fields

| Field | Meaning |
|---|---|
| `schema` | Always `xsprof/event/v1`. |
| `event` | Event kind; see the table below. |
| `ts_ns` | Perf sample timestamp in nanoseconds. |
| `cpu` | CPU that emitted the event. `-1` for process-wide metadata markers. |
| `pid`, `tid` | Perf sample task. What this names depends on the kind. `-1` when not applicable. |
| `a`, `b`, `c` | Kind-specific unsigned values; `0` when unused. |
| `comm` | The subject's command name, bounded to 15 bytes by the serializer. |
| `detail` | Bounded, redacted text for markers, capabilities, and refusals. |
| `host_mutation` | Always `false`; a `true` row is rejected at the boundary. |

## Per-kind layout

### `sched_switch`

```json
{"a":16,"b":1768,"c":0,"comm":"rcu_preempt","cpu":1,"event":"sched_switch","host_mutation":false,"pid":1768,"schema":"xsprof/event/v1","tid":1768,"ts_ns":48470191606}
```

| Field | Meaning |
|---|---|
| `pid`, `tid` | The task that was switched **out** (perf's sample task at the switch). |
| `a` | The task switched **in** (`next_pid`). This is the subject. |
| `b` | The task switched **out** (`prev_pid`). This is the actor. |
| `c` | The previous task's `prev_state` value. |
| `comm` | The **next** task's name, i.e. the subject's comm. |

`subjectPid()` returns `a`; `actorPid()` returns `b`. This is why a row can
look "self-referential" (`pid == b`) without being malformed: `pid` is the
outgoing task and `b` repeats it deliberately.

### `sched_wakeup`

```json
{"a":16,"b":1,"c":0,"comm":"rcu_preempt","cpu":0,"event":"sched_wakeup","host_mutation":false,"pid":1745,"schema":"xsprof/event/v1","tid":1745,"ts_ns":48472180231}
```

| Field | Meaning |
|---|---|
| `pid`, `tid` | The **waker** (the task running on the CPU when the wakeup fired). |
| `a` | The **woken** task pid. This is the subject. |
| `b` | Target CPU for the wakeup. |
| `c` | `0`. |
| `comm` | The **woken** task's name. |

`subjectPid()` returns `a`; `actorPid()` returns `pid`. `why` and the metrics
index build wakeup pairs as `pid (waker) -> a (woken)`.

### `sched_migrate`

```json
{"a":1,"b":3,"c":0,"comm":"?","cpu":3,"event":"sched_migrate","host_mutation":false,"pid":1747,"schema":"xsprof/event/v1","tid":1747,"ts_ns":48603176980}
```

| Field | Meaning |
|---|---|
| `pid`, `tid` | The task being migrated. |
| `a` | Source CPU (`orig_cpu`). |
| `b` | Destination CPU (`dest_cpu`). |
| `c` | `0`. |
| `comm` | The migrating task's name. |

### `page_fault`

```json
{"a":1,"b":0,"c":0,"cpu":1,"event":"page_fault","host_mutation":false,"pid":1768,"schema":"xsprof/event/v1","tid":1768,"ts_ns":48472429023}
```

| Field | Meaning |
|---|---|
| `pid`, `tid` | The faulting task. |
| `a` | `1`; every row is one fault sample. |
| `b` | `1` = major fault, `0` = minor fault. |
| `c` | `0`. |
| `comm` | Empty for software faults. |
| `cpu` | CPU on which the fault was sampled. |

`b` is the discriminator used by `metrics`, `top`, `why`, and the history
sidecars. A `0` in a pre-0.3.0 journal means "minor or combined fault" because
those captures used the combined `SW_PAGE_FAULTS` counter and did not record a
major flag.

### Other kinds

| Kind | Payload |
|---|---|
| `marker` | `detail` carries the text. `pid`/`tid` are `-1` except session metadata: `capture_owner` records the recorder pid, `cpu_llc cpu=N llc=N` and `host_memory buddy_fragmentation=...` carry data in `detail`. `a`/`b`/`c` are `0`. |
| `capability`, `refusal`, `incident` | `detail` is `name:STATE:reason` for capabilities; refusal/incident rows are explicit failure records. No packed fields. |
| `runqueue_sample`, `priority_inversion`, `lock_contention`, `tlb_miss`, `cache_miss`, `huge_page`, `numa_balance`, `alloc_sample`, `malloc_hotspot`, `runtime_sample` | Reserved for future collectors or replayed legacy rows. Treat `a`/`b`/`c` as `0` and do not synthesize meaning. |

## Ordering and timestamps

- A capture drains per-CPU, per-event-type perf rings, so one batch can
  interleave timestamps. `Capture.take()` sorts each batch by `ts_ns`, then
  `cpu`, event kind, `pid`, and `a` before journaling (`src/capture/order.zig`).
- Legacy journals may still contain cross-ring reversals. Replay does not
  reject them; `metrics.out_of_order` counts each row whose `ts_ns` is lower
  than the previous timed row, and `why` prints a best-effort caveat.
- `ts_ns` is perf sample time in nanoseconds. Markers use the recorder's
  monotonic clock and may be older than the window cutoff; session metadata is
  kept by `capture` even when its timestamp is outside the requested window.

## Compatibility note

`fixtures/real/macos-vm-sched.ndjson` is a canonical raw capture: all 94,152
switch rows have `pid == b`, and all 54 wakeups have `pid != a`. Some synthetic
fixtures (for example `fixtures/ui/healthy.ndjson`) put the next pid in `pid`
for switch rows. Consumers that need the switch-in task should read `a`;
consumers that need its name should read `comm`. Do not assume `pid` is the
subject for `sched_switch`.

See the [perf_event_open(2) man page](https://man7.org/linux/man-pages/man2/perf_event_open.2.html)
for `PERF_SAMPLE_TID`/`PERF_SAMPLE_CPU` and tracepoint raw layouts, and the
[kernel perf ring-buffer documentation](https://docs.kernel.org/userspace-api/perf_ring_buffer.html)
for record wrapping and `PERF_RECORD_LOST`.
