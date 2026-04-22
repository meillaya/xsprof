# zig-scheduler

A deterministic CPU scheduling simulator in Zig with a TUI-first main interface, a narrow optional library facade for embedders, and a bounded observability side lane for offline M19/M20 evidence. The repo remains simulator-first: it is for teaching and experimentation, not a kernel scheduler, daemon, or production automation system. Under `docs/adr/0002-m18-linux-observability-gate.md`, the Linux-facing path stays limited to **offline, observability-only, version-pinned snapshot fixtures** — not live capture, tooling automation, replay, or Linux-performance claims. The current “start here” simulator teaching path is documented in `docs/labs/simulator-teaching-pack.md`, while the stable embedder subset is documented in `docs/m22-library-sdk.md`.

## Build

```sh
zig build
zig build test --summary all
```

## Run

Main interface:

```sh
zig build run
# or, after building:
zig-out/bin/zig-scheduler
```

Simulator examples:

```sh
zig build sim -- --scenario-file scenarios/basic/short-vs-long.zon --policy fcfs
zig build run -- --scenario-file scenarios/basic/short-vs-long.zon --policy fcfs

zig build sim -- --scenario-file scenarios/basic/sleep-wakeup.zon --policy cfs-like
zig build run -- --scenario-file scenarios/basic/sleep-wakeup.zon --policy cfs-like

zig build sim -- --scenario-file scenarios/basic/multicore-balancing.zon --policy fcfs
zig build run -- --scenario-file scenarios/basic/multicore-balancing.zon --policy fcfs
```

Snapshots and reports:

```sh
zig-out/bin/zig-scheduler --input docs/examples/exports/multicore-contention-fcfs.report.json --snapshot
zig build sim -- --scenario-file scenarios/basic/multicore-contention.zon --policy fcfs --format json | zig-out/bin/zig-scheduler --stdin --snapshot
```

Core TUI/report inputs:
- `--scenario-file <path>`
- `--input <report.json>`
- `--stdin`
- `--snapshot`

Observability side lane:

```sh
zig-out/bin/zig-scheduler --m19
zig-out/bin/zig-scheduler --snapshot --m19
zig-out/bin/zig-scheduler --m20
zig-out/bin/zig-scheduler --snapshot --m20
```

This observability path uses committed fixtures under
`fixtures/linux-observability/` and does **not** widen `zig-scheduler/report` or `src/analysis`.

Library / SDK smoke:

```sh
zig build m22-embed-smoke
```

Tooling:

```sh
zig build analyze -- --input docs/examples/exports/multicore-contention-fcfs.report.json
zig build bench
zig build reports
zig build reports -- --output-dir zig-out/m16-smoke
```

## Brief theory

The simulator models scheduling as deterministic discrete ticks: tasks arrive,
become runnable, may block/wake, get chosen by a policy, execute, and emit
trace/metric updates. The point is explainable policy comparison on committed
workloads, not Linux kernel fidelity.

## Brief architecture

- **Scenario/model layer**: object-style ZON inputs plus committed scenario packs
- **Engine layer**: deterministic simulation, multicore, blocking, groups, topology
- **Policy layer**: FCFS, Round Robin, CFS-inspired, deadline-inspired
- **Report layer**: versioned `zig-scheduler/report` export contract
- **UI/tooling layer**: TUI, snapshots, analysis, benchmarks, report pipeline
- **Bounded side lanes**:
  - M19/M20 offline observability under `fixtures/linux-observability/`
  - M22 curated public embedder facade documented in `docs/m22-library-sdk.md`

## Start here: simulator-first teaching path (M21)

Use these three anchors as the fastest local demo/review path:

```sh
zig build sim -- --scenario-file scenarios/basic/short-vs-long.zon --policy fcfs
zig build run -- --scenario-file scenarios/basic/short-vs-long.zon --policy fcfs

zig build sim -- --scenario-file scenarios/basic/sleep-wakeup.zon --policy cfs-like
zig build run -- --scenario-file scenarios/basic/sleep-wakeup.zon --policy cfs-like

zig build sim -- --scenario-file scenarios/basic/multicore-balancing.zon --policy fcfs
zig build run -- --scenario-file scenarios/basic/multicore-balancing.zon --policy fcfs
```

The canonical teaching index for this simulator-first path is:

- `docs/labs/simulator-teaching-pack.md`

M19/M20 stay a **separate observability-only lane** inside the TUI:
- use `--m19` or `--m19-manifest <path>` for the M19 fixture summary
- use `--m20` or `--m20-pairing <path>` for the M20 comparison summary
- from the interactive picker, press `m` for M19 or `c` for M20
- these views do **not** widen `zig-scheduler/report` or `src/analysis/*`
- these views are **not** replay authority, fidelity scoring, or Linux-performance evidence

## Key teaching fixtures

- `scenarios/basic/short-vs-long.zon` — convoy-style waiting-time contrast
- `scenarios/basic/sleep-wakeup.zon` — blocked/wakeup burstiness
- `scenarios/basic/multi-phase-io.zon` — phased bursty I/O
- `scenarios/basic/latency-probe.zon` — latency/fairness spread
- `scenarios/basic/starvation-pressure.zon` — starvation pressure
- `scenarios/basic/deadline-priority.zon` — deadline-oriented comparison
- `scenarios/basic/group-fairness.zon` — group fairness
- `scenarios/basic/multicore-balancing.zon` — idle-core rebalance
- `scenarios/basic/topology-domains.zon` — topology-aware placement

These fixtures exercise `sleep_after_ticks`, `phases`, deadlines, groups, and
simple topology distinctions.

The full curriculum-grade corpus index and demo guidance lives in:

- `docs/m17-scenario-corpus.md`

## Scenario generator and property harness

The repo includes a deterministic generator/shrinker/property harness in:

```text
src/testing/property.zig
src/tests/property_test.zig
```

It generates valid scenarios, shrinks failing cases, and saves minimized
regressions under:

```text
scenarios/regressions/
```

## Scenario packs and extension boundary

M14 keeps extension points narrow and reviewable.

- curated named scenarios remain registered in the core scenario registry
- external or optional packs are just canonical `.zon` trees loaded by path
- policy extension remains routed through `src/policies/class.zig`
- core behavior stays operable without optional packs

## Documentation

Start here for the full project write-up:

- `docs/project-architecture-and-status.md`

Other useful docs:

- `docs/phase1-simulator.md`
- `docs/m19-curated-linux-observability.md`
- `docs/m20-simulator-to-trace-comparison.md`
- `docs/m21-simulator-first-teaching-surface.md`
- `docs/m22-library-sdk.md`
- `docs/labs/simulator-teaching-pack.md`
- `docs/m17-scenario-corpus.md`
- `docs/m16-report-pipeline.md`
- `docs/m14-extension-boundary.md`
- `docs/m13-property-testing.md`
- `docs/adr/0001-m5-project-identity.md`
- `docs/adr/0002-m18-linux-observability-gate.md`
