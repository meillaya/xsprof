# Zig Scheduler Simulator

A deterministic, user-space CPU scheduling simulator written in Zig 0.15.2.

Per `docs/adr/0001-m5-project-identity.md`, the current implementation remains simulator-only while the repository roadmap is now explicitly a broader scheduler laboratory with a simulator-only mainline and gated optional branches.

## Project identity after M5
- Current shipped implementation: deterministic simulator only
- Approved roadmap identity: broader scheduler laboratory with a simulator-only mainline
- Optional Linux-facing, distribution, research, library, and production-like branches remain explicitly gated
- ADR: `docs/adr/0001-m5-project-identity.md`

## Phase 1 scope
- In-process simulator only
- FCFS/FIFO, Round Robin, a simplified CFS-inspired policy, and a deterministic deadline-inspired teaching policy
- Deterministic traces, per-task metrics, and aggregate metrics
- Linux-inspired learning aid, not a kernel-faithful scheduler
- No kernel integration, real process execution, or daemon behavior
- Simplified deterministic multicore / SMP simulation, not faithful Linux SMP scheduling
- Optional per-task weights that affect only the CFS-inspired policy
- Optional deterministic single-sleep transitions (`sleep_after_ticks`, `sleep_duration`) for blocked/wakeup teaching scenarios
- Policy handling is routed through an explicit scheduling-class boundary so additional policy families can be added without tangling engine core

## Quick start
```sh
zig build test
zig build run -- --scenario short-vs-long --policy fcfs
zig build run -- --scenario-file scenarios/basic/arrivals.zon --policy fcfs
zig build run -- --scenario-file scenarios/basic/weighted-fairness.zon --policy cfs-like
zig build run -- --scenario-file scenarios/basic/multicore-contention.zon --policy fcfs
zig build run -- --scenario-file scenarios/basic/sleep-wakeup.zon --policy fcfs
zig build run -- --scenario-file scenarios/basic/multi-phase-io.zon --policy fcfs
zig build run -- --scenario-file scenarios/basic/latency-probe.zon --policy rr
zig build run -- --scenario-file scenarios/basic/deadline-priority.zon --policy deadline
zig build run -- --scenario-file scenarios/basic/group-fairness.zon --policy cfs-like
zig build run -- --scenario short-vs-long --policy rr --quantum 2 --format json
zig build analyze -- --input docs/examples/exports/multicore-contention-fcfs.report.json
zig build bench
```

## Public CLI contract
Use exactly one scenario source for `run`:
- `--scenario <builtin-name>` for built-in fixtures
- `--scenario-file <path>` for direct file input

These flags are mutually exclusive.

Output formats:
- `--format text` (default)
- `--format json`

The JSON contract is versioned with:
- `schema: "zig-scheduler/report"`
- `version: 1`

Version `1` now includes additive core-identity fields:
- top-level `core_count`
- per-trace-entry `core_id` when the engine has assigned the event to a core

## Scenario fixtures
The canonical external scenario-file dialect is object-style ZON:

```zig
.{
    .name = "arrivals",
    .quantum = 2,
    .tasks = .{
        .{ .id = "A", .arrival_tick = 0, .burst_ticks = 5 },
        .{ .id = "B", .arrival_tick = 2, .burst_ticks = 3 },
        .{ .id = "C", .arrival_tick = 4, .burst_ticks = 2 },
        .{ .id = "D", .arrival_tick = 6, .burst_ticks = 1 },
    },
}
```

Legacy line-oriented `.zon` input remains readable as a backward-compatible format:

```text
name: short-vs-long
rr_quantum: 2
task: L 0 8
task: S1 1 2
task: S2 2 1
```

The parser keeps task declaration order as the deterministic tie-break fallback for every policy.

Task entries may include an optional `weight` field. Supported weights range from `1` to `4096`, with a default of `1024`. Under the CFS-inspired policy, higher weights can reduce vruntime growth within that supported range, though nearby weights may land in the same integer bucket; FCFS, Round Robin, and the deadline-inspired policy accept the field but ignore it for scheduling decisions.

Tasks may also include an optional absolute `deadline_tick` for the deadline-inspired teaching policy. Lower deadlines win, tie-breaking by stable scenario order. This is a deterministic experimental teaching surface, not a Linux real-time scheduler implementation.

Object-style ZON tasks may model workload phases in two ways:
- compatibility single-sleep fields: `sleep_after_ticks` and `sleep_duration`
- explicit multi-phase arrays: `phases = .{ .{ .kind = .cpu, .ticks = ... }, .{ .kind = .wait, .ticks = ... }, ... }`

The multi-phase form is the canonical M7 surface for alternating CPU and wait segments. The older single-sleep fields remain supported as a compatibility shorthand for one `cpu -> wait -> cpu` transition.

This is an educational simulator model, not a Linux-faithful sleep/wakeup or I/O implementation. Legacy line-oriented `.zon` input remains supported, but blocked/wakeup and multi-phase fields are documented only for the canonical object-style format.

## Output contract
Every text-mode run prints:
- scenario name
- policy name
- core count
- completion order
- raw trace events, including `core=<id>` on core-scoped lines
- explicit `block` / `wakeup` trace events when a task uses deterministic sleep
- per-task completion, turnaround, runnable waiting, blocked-time, and response metrics
- aggregate average waiting time, average response time, throughput, waiting-time spread, and max waiting/response probe metrics

JSON mode emits the same simulation facts in the versioned `zig-scheduler/report` schema for downstream tooling.

## Export -> analysis workflow
The committed M4 example fixture lives at `docs/examples/exports/multicore-contention-fcfs.report.json`.

Render the deterministic Markdown analysis surface:
```sh
zig build analyze -- --input docs/examples/exports/multicore-contention-fcfs.report.json
```

Render the deterministic SVG chart surface:
```sh
zig build analyze -- --input docs/examples/exports/multicore-contention-fcfs.report.json --format svg
```

Reference artifacts are committed at:
- `docs/examples/analysis/multicore-contention-fcfs.md`
- `docs/examples/analysis/multicore-contention-fcfs.svg`

The analyzer only accepts the public export contract (`schema == "zig-scheduler/report"`, `version == 1`) and rejects missing or unsupported versions instead of guessing.

## Group scheduling teaching fixture
M11 adds `scenarios/basic/group-fairness.zon` to model group membership, group weights, and quota-like caps in a simulator-safe way.

The current group model is intentionally narrow: tasks may reference declared groups, groups carry `weight` and `quota_ticks`, and the CFS-inspired policy uses those values to create deterministic group-fairness pressure. This is a teaching analogy, not Linux cgroups or kernel group scheduling fidelity.

## Deadline-inspired teaching policy
M10 adds `--policy deadline` (also aliased as `edf`) for deterministic deadline-oriented teaching experiments. The canonical fixture is `scenarios/basic/deadline-priority.zon`.

This policy is intentionally narrow: it prefers the runnable task with the earliest declared absolute deadline and preempts when a newly runnable task has an earlier deadline. It is useful for teaching deadline pressure and latency tradeoffs, but it does not claim Linux real-time scheduler fidelity.

## Fairness and latency probe fixtures
M8 adds dedicated experiment fixtures for evidence-based fairness discussions:
- `scenarios/basic/latency-probe.zon` — batch plus short arrivals for latency comparisons
- `scenarios/basic/starvation-pressure.zon` — weighted equal-arrival contention that exposes starvation pressure on low-weight work

Useful probe metrics now include `max_waiting_time`, `max_response_time`, and `response_time_spread` in addition to the existing averages and waiting-time spread. These are simulator-local experiment aids, not formal scheduler guarantees.

## Benchmark baselines
Use the reproducible M4.5 harness to regenerate simulator-local baseline artifacts:
```sh
zig build bench
zig build bench -- --format json
```

Committed baseline artifacts live at:
- `docs/benchmarks/m45-baselines.md`
- `docs/benchmarks/m45-baselines.json`

These numbers are deterministic simulator-local output-size/trace-volume baselines over committed fixtures. They are not Linux performance claims.

The `scenarios/basic/sleep-wakeup.zon` fixture is the canonical M6 example for deterministic blocked/runnable transitions, and `scenarios/basic/multi-phase-io.zon` is the canonical M7 example for alternating CPU/wait phases.

See `docs/phase1-simulator.md`, `docs/m4-analysis-workflow.md`, `docs/m45-benchmark-workflow.md`, `docs/m8-fairness-probes.md`, `docs/m10-deadline-policy.md`, `docs/m11-group-scheduling.md`, and `docs/linux-mapping.md` for semantics, analysis workflow details, benchmark workflow details, fairness probe guidance, deadline-policy notes, group-scheduling guidance, and Linux relevance notes.

## Multicore fixture corpus
Committed multicore proof fixtures now include:
- `multicore-contention` — baseline two-core contention
- `multicore-balancing` — idle-core steal/rebalance behavior
- `multicore-staggered` — staggered arrivals with multicore idle/restart patterns
- `multicore-weighted` — multicore weighted fairness stress for the CFS-inspired path
- `multicore-simultaneous-complete` — deterministic same-tick completion ordering
- `multicore-rr-quantum` — multicore round-robin preemption pressure
