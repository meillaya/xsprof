# Simulator teaching pack

This is the canonical teaching simulator-first teaching index.

For the packaged courseware shell built on top of this spine, start from:
- `docs/courseware/m23-teaching-distribution.md`

It intentionally covers only **three** start-here anchors:
- `short-vs-long` + `fcfs`
- `sleep-wakeup` + `cfs-like`
- `multicore-balancing` + `fcfs`

observability/comparison remain reachable in the TUI, but they are a bounded observability side
lane rather than the main teaching path.

## 1. short-vs-long — convoy contrast

Scenario file:
- `scenarios/basic/short-vs-long.zon`

Recommended commands:

```sh
zig build sim -- --scenario-file scenarios/basic/short-vs-long.zon --policy fcfs
zig build run -- --scenario-file scenarios/basic/short-vs-long.zon --policy fcfs
```

What to notice:
- the long task arrives first and makes the short tasks wait
- FCFS gives the clearest first-demo convoy story
- the trace and waiting-time output show why short jobs finish later than intuition might expect

Deeper explanation:
- `docs/phase1-scenario-c-walkthrough.md`

## 2. sleep-wakeup — blocked/wakeup burstiness

Scenario file:
- `scenarios/basic/sleep-wakeup.zon`

Recommended commands:

```sh
zig build sim -- --scenario-file scenarios/basic/sleep-wakeup.zon --policy cfs-like
zig build run -- --scenario-file scenarios/basic/sleep-wakeup.zon --policy cfs-like
```

What to notice:
- blocked time and wakeup behavior are visible directly in the trace
- the scenario demonstrates the simulator's educational blocked/wakeup model without claiming kernel fidelity
- the TUI makes the arrival/block/wakeup/complete sequence easy to inspect locally

Deeper explanation:
- `docs/phase1-simulator.md`

## 3. multicore-balancing — deterministic rebalance story

Scenario file:
- `scenarios/basic/multicore-balancing.zon`

Recommended commands:

```sh
zig build sim -- --scenario-file scenarios/basic/multicore-balancing.zon --policy fcfs
zig build run -- --scenario-file scenarios/basic/multicore-balancing.zon --policy fcfs
```

What to notice:
- one idle core becomes available while queued work remains elsewhere
- the trace exposes deterministic rebalance behavior in a small, readable multicore example
- this is a teaching simplification, not a Linux scheduler-domain fidelity claim

Deeper explanation:
- `docs/scenario-corpus.md`

## Boundary reminder

This teaching pack is simulator-first:
- no browser/WASM requirement
- no widening of `zig-scheduler/report`
- no widening of `src/analysis/*`
- no replay-fidelity, calibration, or Linux-performance claims
- observability/comparison stay a separate observability-only side lane
