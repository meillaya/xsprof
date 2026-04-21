# Phase 1 Simulator Semantics

## Tick order
Each simulation tick follows the same deterministic sequence:
1. incorporate arrivals for the current tick
2. evaluate policy dispatch/preemption decisions
3. execute exactly one tick of CPU time for the selected task
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

Consumers should treat the export as supported only when:
- `schema == "zig-scheduler/report"`
- `version == 1`

Missing schema/version fields or unsupported values should be rejected rather than guessed.

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

## Metrics
- `completion_time = tick immediately after the final executed tick`
- `turnaround_time = completion_time - arrival_tick`
- `waiting_time = turnaround_time - burst_ticks`
- `response_time = first_dispatch_tick - arrival_tick`
- `throughput = completed_task_count / (last_completion_tick - earliest_arrival_tick)`
- `waiting_time_spread = max(waiting_time) - min(waiting_time)`

## Phase boundary
This project is a simulator only. It does not launch processes, integrate with the Linux kernel, or implement daemon/service behavior.
