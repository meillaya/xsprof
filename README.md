# Zig Scheduler Simulator

A deterministic, user-space CPU scheduling simulator written in Zig 0.15.2.

## Phase 1 scope
- In-process simulator only
- FCFS/FIFO, Round Robin, and a simplified CFS-inspired policy
- Deterministic traces, per-task metrics, and aggregate metrics
- Linux-inspired learning aid, not a kernel-faithful scheduler
- No kernel integration, real process execution, or daemon behavior
- Simplified deterministic multicore / SMP simulation, not faithful Linux SMP scheduling
- Optional per-task weights that affect only the CFS-inspired policy

## Quick start
```sh
zig build test
zig build run -- --scenario short-vs-long --policy fcfs
zig build run -- --scenario-file scenarios/basic/arrivals.zon --policy fcfs
zig build run -- --scenario-file scenarios/basic/weighted-fairness.zon --policy cfs-like
zig build run -- --scenario-file scenarios/basic/multicore-contention.zon --policy fcfs
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

Task entries may include an optional `weight` field. Supported weights range from `1` to `4096`, with a default of `1024`. Under the CFS-inspired policy, higher weights can reduce vruntime growth within that supported range, though nearby weights may land in the same integer bucket; FCFS and Round Robin accept the field but ignore it.

## Output contract
Every text-mode run prints:
- scenario name
- policy name
- core count
- completion order
- raw trace events, including `core=<id>` on core-scoped lines
- per-task completion, turnaround, waiting, and response metrics
- aggregate average waiting time, average response time, throughput, and waiting-time spread

JSON mode emits the same simulation facts in the versioned `zig-scheduler/report` schema for downstream tooling.

## Export -> analysis workflow
The committed M4 example fixture lives at `docs/examples/exports/multicore-contention-fcfs.report.json`.

Render the deterministic Markdown analysis surface:
```sh
zig build analyze -- --input docs/examples/exports/multicore-contention-fcfs.report.json
zig build bench
```

Render the deterministic SVG chart surface:
```sh
zig build analyze -- --input docs/examples/exports/multicore-contention-fcfs.report.json --format svg
```

Reference artifacts are committed at:
- `docs/examples/analysis/multicore-contention-fcfs.md`
- `docs/examples/analysis/multicore-contention-fcfs.svg`

The analyzer only accepts the public export contract (`schema == "zig-scheduler/report"`, `version == 1`) and rejects missing or unsupported versions instead of guessing.

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

See `docs/phase1-simulator.md`, `docs/m4-analysis-workflow.md`, `docs/m45-benchmark-workflow.md`, and `docs/linux-mapping.md` for semantics, analysis workflow details, benchmark workflow details, and Linux relevance notes.

## Multicore fixture corpus
Committed multicore proof fixtures now include:
- `multicore-contention` — baseline two-core contention
- `multicore-balancing` — idle-core steal/rebalance behavior
- `multicore-staggered` — staggered arrivals with multicore idle/restart patterns
- `multicore-weighted` — multicore weighted fairness stress for the CFS-inspired path
- `multicore-simultaneous-complete` — deterministic same-tick completion ordering
- `multicore-rr-quantum` — multicore round-robin preemption pressure
