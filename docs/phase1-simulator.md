# Phase 1 Simulator Semantics

## Tick order
Each simulation tick follows the same deterministic sequence:
1. incorporate arrivals for the current tick
2. evaluate policy dispatch/preemption decisions
3. execute exactly one tick of CPU time per selected core-local task
4. record resulting completion state at the tick boundary

## Tie breaking
- same-arrival ties fall back to scenario declaration order
- FCFS preserves ready-queue order
- Round Robin rotates the ready queue in deterministic FIFO order
- the CFS-inspired policy picks the runnable task with the lowest virtual runtime, then falls back to declaration order

## Round Robin rule
If a task reaches a quantum boundary and also finishes on that tick, completion wins and no preemption event is emitted.

## Weighted CFS-inspired fairness
Tasks may include an optional `weight` field. Supported weights range from `1` to `4096`, and the default weight is `1024`.

For the CFS-inspired policy only:
- higher weights can accumulate virtual runtime more slowly within the supported range
- lower weights accumulate virtual runtime more quickly
- nearby weights may share the same integer vruntime step after rounding
- equal effective virtual runtime still falls back to scenario declaration order

FCFS and Round Robin accept the weight field as part of the scenario contract but ignore it when making scheduling decisions.

## Scenario input contract
The public run surface supports exactly one scenario source:
- `--scenario <builtin-name>`
- `--scenario-file <path>`

The canonical external scenario-file dialect is object-style ZON. Legacy line-oriented `.zon` input remains readable as a backward-compatible format during roadmap execution.

## Output contract
Text output remains the default human-readable report.

Machine-readable export is versioned JSON with:
- `schema = "zig-scheduler/report"`
- `version = 1`

Version `1` is stable for consumers, but later milestones may add backward-compatible fields or introduce a new schema version for breaking changes.
Current additive version-1 core identity fields are:
- top-level `core_count`
- per-trace-entry `core_id` for core-scoped events such as dispatch, tick, preempt, complete, and idle

Consumers should treat the export as supported only when:
- `schema == "zig-scheduler/report"`
- `version == 1`

Missing schema/version fields or unsupported values should be rejected rather than guessed.

### Downstream analysis workflow
M4 analysis/report tooling consumes only the exported `zig-scheduler/report` JSON. The canonical committed example export is `docs/examples/exports/multicore-contention-fcfs.report.json`, with paired deterministic outputs at `docs/examples/analysis/multicore-contention-fcfs.md` and `docs/examples/analysis/multicore-contention-fcfs.svg`.

Use `zig build analyze -- --input <report.json>` for the Markdown surface or add `--format svg` for the visualization surface. Consumers must keep the same schema/version gate and reject unsupported export versions instead of guessing.

### Simulator-local benchmark baselines
M4.5 adds `zig build bench` for deterministic baseline generation over committed fixtures. The harness records output-size and trace-volume metrics into `docs/benchmarks/m45-baselines.md` and `docs/benchmarks/m45-baselines.json`.

These baselines are simulator-local only: they help compare fixtures/policies within this project, and they must not be presented as Linux scheduler performance measurements.

### Public trace event taxonomy
The public trace event kinds are:
- `arrival`
- `dispatch`
- `tick`
- `preempt`
- `complete`
- `idle`

### Public JSON report fields
Top-level fields:
- `schema`
- `version`
- `source`
- `scenario`
- `policy`
- `core_count`
- `completion_order`
- `trace`
- `tasks`
- `aggregate`
- `notes`

`completion_order` is an array of task ids in final completion order.

`source` fields:
- `kind`
- `value`

`scenario` fields:
- `name`
- `round_robin_quantum`

`policy` fields:
- `kind`
- `display_name`
- `quantum`

Trace entry fields:
- `tick`
- `kind`
- `task_id`
- `core_id`

Per-task fields:
- `id`
- `arrival_tick`
- `burst_ticks`
- `weight`
- `input_order`
- `first_dispatch_tick`
- `completion_time`
- `turnaround_time`
- `waiting_time`
- `response_time`
- `total_executed`

Aggregate fields:
- `average_waiting_time`
- `average_response_time`
- `throughput`
- `throughput_numerator`
- `throughput_denominator`
- `waiting_time_spread`

These field lists define the required version `1` baseline. Any later version-`1` extension must remain additive, be documented here, and land with regression coverage for the new fields.

## Metrics
- `completion_time = tick immediately after the final executed tick`
- `turnaround_time = completion_time - arrival_tick`
- `waiting_time = turnaround_time - burst_ticks`
- `response_time = first_dispatch_tick - arrival_tick`
- `throughput = completed_task_count / (last_completion_tick - earliest_arrival_tick)`
- `waiting_time_spread = max(waiting_time) - min(waiting_time)`

## Phase boundary
This project is a simulator only. It does not launch processes, integrate with the Linux kernel, or implement daemon/service behavior.

## Simplified multicore / SMP semantics
When `core_count > 1`, the simulator runs one deterministic scheduling lane per core.

Rules:
- arrivals are assigned to the least-loaded core, tie-breaking by lower core id
- before dispatch, an idle core may steal the oldest ready task from the busiest ready queue
- arrival, dispatch, tick, preempt, complete, and idle trace events carry `core_id` where the engine has assigned a core
- no distinct migration event kind is added in version 1; migration is inferred when a later dispatch core differs from the task's earlier arrival/dispatched core

### Committed multicore fixture corpus
- `multicore-contention` — baseline deterministic two-core contention
- `multicore-balancing` — deterministic oldest-ready-task steal onto an idle core
- `multicore-staggered` — staggered arrivals and multicore idle gaps
- `multicore-weighted` — weighted multicore contention for the CFS-inspired path
- `multicore-simultaneous-complete` — same-tick completion ordering across cores
- `multicore-rr-quantum` — round-robin preemption pressure on multicore queues
