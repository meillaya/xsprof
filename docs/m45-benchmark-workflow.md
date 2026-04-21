# M4.5 benchmark workflow

M4.5 adds a reproducible benchmark harness for simulator-local baseline comparisons.

## Scope and labeling
- Simulator-local benchmark baseline only; not a Linux performance claim.
- Metrics are deterministic output-size and trace-volume baselines over committed fixtures.
- The harness is intended for fixed-input repeatability, not for publishing host-runtime performance numbers.

## Commands
Render the human-readable benchmark baseline report:

```sh
zig build bench
```

Render the JSON baseline artifact:

```sh
zig build bench -- --format json
```

## Committed baseline artifacts
- `docs/benchmarks/m45-baselines.md`
- `docs/benchmarks/m45-baselines.json`

These artifacts are generated from this fixed fixture/policy matrix:
- `scenarios/basic/arrivals.zon` with `fcfs`
- `scenarios/basic/short-vs-long.zon` with `round_robin`
- `scenarios/basic/weighted-fairness.zon` with `cfs_like`
- `scenarios/basic/multicore-contention.zon` with `fcfs`
- `scenarios/basic/multicore-rr-quantum.zon` with `round_robin`
- `scenarios/basic/multicore-weighted.zon` with `cfs_like`

## Repeatability
Repeatability is the core guarantee for this milestone:
1. Run `zig build bench` twice.
2. Run `zig build bench -- --format json` twice.
3. Compare against the committed baseline artifacts.
4. Any intentional baseline shift should be reviewed and committed with the associated code change.

## Verification shape
Minimum checks:
- benchmark harness smoke
- repeatability check over fixed fixtures
- docs audit confirming simulator-local labeling
