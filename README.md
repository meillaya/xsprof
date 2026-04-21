# zig-scheduler

A deterministic CPU scheduling simulator in Zig.

It is a teaching and experimentation project, not a kernel scheduler, daemon,
or production automation system.

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

Built-in scenario:

```sh
zig build run -- --scenario short-vs-long --policy fcfs
```

Scenario file:

```sh
zig build run -- --scenario-file scenarios/basic/group-fairness.zon --policy cfs-like
```

JSON export:

```sh
zig build run -- --scenario-file scenarios/basic/deadline-priority.zon --policy deadline --format json
```

## Test

```sh
zig build test --summary all
```


## CLI surface

Use exactly one scenario source:

- `--scenario <builtin-name>`
- `--scenario-file <path>`

These flags are mutually exclusive.

## Tooling

Analysis:

```sh
zig build analyze -- --input docs/examples/exports/multicore-contention-fcfs.report.json
```

Benchmarks:

```sh
zig build bench
```

TUI trace explorer (M15):

```sh
# interactive mode (requires a real TTY)
zig build tui -- --scenario-file scenarios/basic/multicore-contention.zon --policy fcfs

# explicit non-TTY snapshot mode
zig-out/bin/zig-scheduler-tui --input docs/examples/exports/multicore-contention-fcfs.report.json --snapshot
zig build run -- --scenario-file scenarios/basic/multicore-contention.zon --policy fcfs --format json | zig-out/bin/zig-scheduler-tui --stdin --snapshot
```

## Key teaching fixtures

- `scenarios/basic/sleep-wakeup.zon`
- `scenarios/basic/multi-phase-io.zon`
- `scenarios/basic/latency-probe.zon`
- `scenarios/basic/starvation-pressure.zon`
- `scenarios/basic/deadline-priority.zon`
- `scenarios/basic/group-fairness.zon`
- `scenarios/basic/topology-domains.zon`

These fixtures exercise `sleep_after_ticks`, `phases`, deadlines, groups, and
simple topology distinctions.

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

- curated built-ins remain registered in the core scenario registry
- external or optional packs are just canonical `.zon` trees loaded by path
- policy extension remains routed through `src/policies/class.zig`
- core behavior stays operable without optional packs

## Documentation

Start here for the full project write-up:

- `docs/project-architecture-and-status.md`

Other useful docs:

- `docs/phase1-simulator.md`
- `docs/m14-extension-boundary.md`
- `docs/m13-property-testing.md`
- `docs/adr/0001-m5-project-identity.md`
