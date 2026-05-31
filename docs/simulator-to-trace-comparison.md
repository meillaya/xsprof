# comparison simulator-to-trace comparison summary

comparison adds one narrow reproducible comparison surface between the simulator and the
committed observability Linux-observability fixture family.

## Scope boundary

This workstream is intentionally limited to:
- pairing `scenarios/basic/sleep-wakeup.zon` with `cfs_like`
- comparing against `fixtures/linux-observability/manifests/tracefs-sched-demo.json`
- emitting the separate `zig-scheduler/observability-comparison` v1 payload only
- keeping the surface library/docs/tests only

This workstream does **not**:
- widen `zig-scheduler/report`
- widen `src/analysis/*`
- add a CLI or report-export entrypoint
- align raw events one by one
- match simulator task ids to Linux PIDs
- treat the comparison as replay authority or Linux-performance evidence

## Approved pairing manifest

- Pairing manifest: `fixtures/linux-observability/pairings/sleep-wakeup-vs-tracefs-sched-demo.json`
- Contract: `zig-scheduler/observability-comparison` v1
- TUI observability lane: `zig-out/bin/zig-scheduler --comparison` or `--comparison-pairing <path>`
- Normalization mapping:
  - `activation` = simulator `arrival|wakeup` vs observability `sched_wakeup|sched_wakeup_new`
  - `selection` = simulator `dispatch` vs observability `sched_switch`
  - `retirement` = simulator `complete` vs observability `sched_process_exit`

Unmapped approved-trace events remain visible in raw totals and stay out of the
normalized family summaries.

## Reproducible smoke values

From the committed simulator input and committed observability fixture only, the approved
comparison produces:

| metric | simulator | observability | delta | caveat |
| --- | ---: | ---: | ---: | --- |
| `activation_count_delta` | 3 | 2 | 1 | `not_fidelity` |
| `selection_count_delta` | 5 | 1 | 4 | `not_fidelity` |
| `retirement_count_delta` | 2 | 1 | 1 | `not_fidelity` |
| `total_event_count_delta` | 20 | 5 | 15 | `unmatched_events_present` |
| `cpu_cardinality_delta` | 1 | 2 | -1 | `observability_only` |
| `actor_cardinality_delta` | 2 | 3 | -1 | `identity_not_equivalent` |
| `time_span_delta` | 7.0 | 0.2 | 6.8 | `units_not_equivalent` |

Normalized first-seen family order is `activation -> selection -> retirement`
for both inputs.

## Caveat registry

- `observability_only` — the comparison uses a committed offline observability snapshot and remains a bounded teaching aid.
- `units_not_equivalent` — simulator ticks and trace-clock seconds are juxtaposed numerically only; the units are not equivalent.
- `identity_not_equivalent` — simulator task ids and observed Linux PIDs are different identity domains and are not matched.
- `unmatched_events_present` — unmapped approved-trace events stay in raw totals while normalized family summaries exclude them.
- `not_fidelity` — metric rows do not score replay fidelity.
