# Zig Scheduler Simulator

A deterministic, user-space CPU scheduling simulator written in Zig 0.15.2.

## Phase 1 scope
- In-process simulator only
- FCFS/FIFO, Round Robin, and a simplified CFS-inspired policy
- Deterministic traces, per-task metrics, and aggregate metrics
- Linux-inspired learning aid, not a kernel-faithful scheduler

## Quick start
```sh
zig build test
zig build run -- --scenario short-vs-long --policy fcfs
zig build run -- --scenario equal-arrival-contention --policy rr --quantum 2
```

## Scenario fixtures
Scenario fixtures live in `scenarios/basic/*.zon` and use a compact, line-oriented text format:

```text
name: short-vs-long
rr_quantum: 2
task: L 0 8
task: S1 1 2
task: S2 2 1
```

The parser keeps task declaration order as the deterministic tie-break fallback for every policy.

## Output contract
Every run prints:
- scenario name
- policy name
- completion order
- raw trace events
- per-task completion, turnaround, waiting, and response metrics
- aggregate average waiting time, average response time, throughput, and waiting-time spread

See `docs/phase1-simulator.md` and `docs/linux-mapping.md` for semantics and Linux relevance notes.
