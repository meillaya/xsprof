# Simulator semantics

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
- the deadline-inspired policy picks the runnable task with the earliest declared absolute deadline, then falls back to declaration order

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
- `--scenario <core/basic-name>`
- `--scenario-file <path>`

The canonical external scenario-file dialect is object-style ZON. Legacy line-oriented `.zon` input remains readable as a backward-compatible format during roadmap execution.

## Output contract
Text output remains the default human-readable report.

Machine-readable export is versioned JSON with:
- `schema = "zig-scheduler/report"`
- `version = 1`

Version `1` is stable for consumers, but later workstreams may add backward-compatible fields or introduce a new schema version for breaking changes.
Current additive version-1 core identity fields are:
- top-level `core_count`
- per-trace-entry `core_id` for core-scoped events such as dispatch, tick, preempt, complete, and idle

Consumers should treat the export as supported only when:
- `schema == "zig-scheduler/report"`
- `version == 1`

Missing schema/version fields or unsupported values should be rejected rather than guessed.

### Downstream analysis workflow
the simulator analysis/report tooling consumes only the exported `zig-scheduler/report` JSON. The canonical committed example export is `docs/examples/exports/multicore-contention-fcfs.report.json`, with paired deterministic outputs at `docs/examples/analysis/multicore-contention-fcfs.md` and `docs/examples/analysis/multicore-contention-fcfs.svg`.

Use `zig build analyze -- --input <report.json>` for the Markdown surface or add `--format svg` for the visualization surface. Consumers must keep the same schema/version gate and reject unsupported export versions instead of guessing.

the simulator adds the canonical end-to-end regeneration path:

```sh
zig build reports
```

Use `zig build reports -- --output-dir <dir>` for a smoke run that materializes
the same curated artifact pack outside the committed docs tree.

### Simulator-local benchmark baselines
benchmark workflow adds `zig build bench` for deterministic baseline generation over committed fixtures. The harness records output-size and trace-volume metrics into `docs/benchmarks/baselines.md` and `docs/benchmarks/baselines.json`.

These baselines are simulator-local only: they help compare fixtures/policies within this project, and they must not be presented as Linux scheduler performance measurements.

### canonical scenario corpus
the simulator promotes the strongest teaching fixtures into an explicit curriculum-grade
corpus with stable metadata, explanation docs, and demo/regression guidance.

Required coverage in the canonical corpus includes:
- convoy-style waiting-time contrast (`short-vs-long`)
- blocked/wakeup and phased burstiness (`sleep-wakeup`, `multi-phase-io`)
- starvation pressure (`starvation-pressure`)
- deterministic multicore rebalancing (`multicore-balancing`)
- topology-aware placement (`topology-domains`)

See `docs/scenario-corpus.md` for the index, recommended policies, and
manual-demo commands.

### Deterministic blocked / wakeup model
the simulator adds one intentionally simple blocked-state model: a task may declare a single `sleep_after_ticks` / `sleep_duration` pair in object-style ZON. After the task accumulates `sleep_after_ticks` executed ticks, it emits a `block` trace event, becomes unrunnable for `sleep_duration` ticks, then emits a `wakeup` trace event and re-enters the runnable set.

This is an educational deterministic model only. It does not attempt to reproduce Linux wakeup races, interrupt timing, wait queues, or I/O completion behavior.

### Multi-phase workload model
the simulator extends the object-style scenario surface with explicit `phases` arrays so a task can alternate CPU and wait segments deterministically. Each task phase sequence must start with `cpu`, alternate between `cpu` and `wait`, and end with `cpu`.

For backward compatibility, the earlier the simulator `sleep_after_ticks` / `sleep_duration` pair is still accepted and normalized to an equivalent three-phase `cpu -> wait -> cpu` plan. Existing single-burst scenarios remain valid with no migration.

### Deadline-inspired teaching policy
the simulator adds a deterministic deadline-inspired policy. Tasks may declare `deadline_tick`, and the policy chooses the runnable task with the earliest deadline, tie-breaking by stable scenario order. If an earlier-deadline task becomes runnable, the current task is preempted.

This is an educational policy only. It does not model Linux deadline scheduling, admission control, runtime budgets, or real-time guarantees.

### Topology-aware multicore model
the simulator adds an explicit `topology_domains` surface so multicore scenarios can group cores into one higher-level topology distinction such as a simplified NUMA node or cache domain.

Current deterministic rules:
- arrivals choose the least-loaded topology domain first, then the least-loaded core within that domain
- idle-core stealing prefers same-domain donors before falling back to cross-domain donors
- trace events now carry `domain_id` alongside `core_id` when a task is placed or moved

This is a teaching simplification only. It does not model Linux scheduler domains, NUMA balancing, cache hierarchies, or kernel migration cost fidelity.

### group-level scheduling ideas
the simulator adds a simulator-safe group model. Scenarios may declare top-level `groups`, and tasks may reference a `group_id`. Groups currently carry:
- `weight`
- `quota_ticks`

In the current mainline implementation, the CFS-inspired policy uses group weight as part of effective fairness accounting and uses quota-like caps to keep other runnable groups visible in deterministic experiments. This is an analogy to group fairness ideas, not Linux cgroups or kernel group scheduling fidelity.

### Scheduling-class boundary
the simulator refactors the engine so policy-specific selection, preemption, and tick-accounting hooks flow through an explicit scheduling-class boundary (`src/policies/class.zig`). The engine still owns common simulation state and trace/metric production, while policy families provide their own scheduling decisions behind that boundary.

This is an internal architecture cleanup only: current FCFS, Round Robin, and CFS-inspired behavior should remain semantically unchanged.

### Scenario-pack convention and extension boundary
the simulator keeps extension points narrow and reviewable instead of adding a plugin runtime.

Scenario-pack convention:
- curated built-ins and pack-qualified names stay registered in `src/sim/scenario.zig`
- curriculum-grade corpus metadata is indexed in `src/sim/scenario_pack.zig`
- built-in metadata points at committed fixtures under `scenarios/basic/`
- external or optional packs are just canonical `.zon` files loaded through `--scenario-file <path>` or `loadScenarioFile`

Policy-extension boundary:
- `src/sim/engine.zig` stays coupled to `src/policies/class.zig`, not to individual policy modules
- policy families remain responsible for their own selection, preemption, and tick-accounting behavior behind that boundary
- optional scenario packs must not be required for the core simulator, test suite, or basic CLI workflows to operate

This keeps the mainline core operable without optional extras while still leaving a documented path for new teaching fixtures or policy families.

### scenario generation and regression workflow
the simulator extends verification expectations around the existing public scenario surface: generated cases should still serialize to the canonical object-style ZON dialect, shrinking should preserve a clear failing predicate, and minimized failures should be saved under `scenarios/regressions/` rather than mixed into the curated teaching corpus.

These checks are simulator-local only. They increase confidence in parser, engine, and export invariants, but they do not by themselves justify Linux scheduler fidelity or production-hardening claims.

See `docs/scenario-generator-workflow.md` for the workflow and save-path guidance.

### Public trace event taxonomy
The public trace event kinds are:
- `arrival`
- `dispatch`
- `tick`
- `preempt`
- `block`
- `wakeup`
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
- `topology_domains`
- `groups`
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
- `sleep_after_ticks`
- `sleep_duration`
- `phase_count`
- `deadline_tick`
- `input_order`
- `first_dispatch_tick`
- `completion_time`
- `turnaround_time`
- `waiting_time`
- `blocked_time`
- `response_time`
- `total_executed`

Aggregate fields:
- `average_waiting_time`
- `average_response_time`
- `throughput`
- `throughput_numerator`
- `throughput_denominator`
- `waiting_time_spread`
- `max_waiting_time`
- `max_response_time`
- `response_time_spread`

These field lists define the required version `1` baseline. Any later version-`1` extension must remain additive, be documented here, and land with regression coverage for the new fields.

### Fairness / latency probe metrics
the simulator adds a few explicit experiment-oriented aggregate metrics:
- `max_waiting_time`
- `max_response_time`
- `response_time_spread`

These are probe metrics for comparing deterministic scenarios across policies. They are evidence surfaces for fairness/latency discussion, not formal starvation or Linux scheduler guarantees.

## Metrics
- `completion_time = tick immediately after the final executed tick`
- `turnaround_time = completion_time - arrival_tick`
- `blocked_time = number of ticks spent in deterministic wait phases before wakeup`
- `waiting_time = turnaround_time - burst_ticks - blocked_time`
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
- arrival, dispatch, tick, preempt, block, wakeup, complete, and idle trace events carry `core_id` where the engine has assigned a core
- no distinct migration event kind is added in version 1; migration is inferred when a later dispatch core differs from the task's earlier arrival/dispatched core

### Committed multicore fixture corpus
- `multicore-contention` — baseline deterministic two-core contention
- `multicore-balancing` — deterministic oldest-ready-task steal onto an idle core
- `multicore-staggered` — staggered arrivals and multicore idle gaps
- `multicore-weighted` — weighted multicore contention for the CFS-inspired path
- `multicore-simultaneous-complete` — same-tick completion ordering across cores
- `multicore-rr-quantum` — round-robin preemption pressure on multicore queues
