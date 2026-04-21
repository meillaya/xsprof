# zig-scheduler

A deterministic CPU scheduling simulator in Zig.

It is a teaching and experimentation project, not a kernel scheduler, daemon,
or production automation system.

The main simulator, `zig-scheduler/report` contract, and downstream
`src/analysis` tooling remain simulator-first. Under
`docs/adr/0002-m18-linux-observability-gate.md` and
`docs/m19-curated-linux-observability.md`, the optional Linux-observability
lane is limited to **offline, observability-only, version-pinned snapshot
fixtures** ending at a bounded observability summary — not live capture,
tooling automation, replay, analyzer/report-contract widening, or
Linux-performance claims.

## What it does

- runs deterministic scheduling scenarios
- supports FCFS, Round Robin, CFS-inspired, and deadline-inspired policies
- models multicore, blocked/wakeup, multi-phase workloads, groups, and topology domains
- exports versioned JSON reports
- includes analysis, benchmark, and property-testing tooling

## Build

```sh
zig build
```

## Run

Main interface:

```sh
zig build run
# or, after building:
zig-out/bin/zig-scheduler
```

Launch the TUI with a scenario preloaded:

```sh
zig build run -- --scenario-file scenarios/basic/group-fairness.zon --policy cfs-like
```

Render a non-interactive snapshot:

```sh
zig-out/bin/zig-scheduler --input docs/examples/exports/multicore-contention-fcfs.report.json --snapshot
```

Legacy simulator CLI:

```sh
zig build sim -- --scenario short-vs-long --policy fcfs
zig-out/bin/zig-scheduler sim --scenario-file scenarios/basic/deadline-priority.zon --policy deadline --format json
```

## Test

```sh
zig build test --summary all
```


## CLI surface

The default `zig-scheduler` entrypoint is now TUI-first.

TUI input flags:
- `--scenario <core/basic-name>`
- `--scenario-file <path>`
- `--input <report.json>`
- `--stdin`
- `--snapshot`

Legacy simulator CLI remains available under `zig-scheduler sim ...` (or `zig build sim -- ...`).

## Tooling

Analysis:

```sh
zig build analyze -- --input docs/examples/exports/multicore-contention-fcfs.report.json
```

Benchmarks:

```sh
zig build bench
```

Reproducible report pack (M16):

```sh
zig build reports
# smoke into a separate directory:
zig build reports -- --output-dir zig-out/m16-smoke
```

TUI trace explorer (M15):

```sh
# dedicated TUI binary still exists
zig build tui -- --scenario-file scenarios/basic/multicore-contention.zon --policy fcfs

# main binary now launches the same TUI by default
zig-out/bin/zig-scheduler --scenario-file scenarios/basic/multicore-contention.zon --policy fcfs

# explicit non-TTY snapshot mode
zig-out/bin/zig-scheduler --input docs/examples/exports/multicore-contention-fcfs.report.json --snapshot
zig build sim -- --scenario-file scenarios/basic/multicore-contention.zon --policy fcfs --format json | zig-out/bin/zig-scheduler --stdin --snapshot
```

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
- `docs/m17-scenario-corpus.md`
- `docs/m16-report-pipeline.md`
- `docs/m14-extension-boundary.md`
- `docs/m13-property-testing.md`
- `docs/adr/0001-m5-project-identity.md`
- `docs/adr/0002-m18-linux-observability-gate.md`
