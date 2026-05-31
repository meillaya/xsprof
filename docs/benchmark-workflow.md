# Benchmark workflow

benchmark workflow adds a reproducible benchmark harness for simulator-local baseline comparisons.

## Scope and labeling
- Simulator-local benchmark baseline only; not a Linux performance claim.
- Metrics are deterministic output-size and trace-volume baselines over committed fixtures.
- The harness is intended for fixed-input repeatability, not for publishing host-runtime performance numbers.

## Commands
The narrow benchmark commands still exist, but the simulator now makes the canonical
multi-artifact regeneration path:

```sh
zig build reports
```

Use the benchmark workflow commands below when you intentionally want only the benchmark
surfaces.

Render the human-readable benchmark baseline report:

```sh
zig build bench
```

Render the JSON baseline artifact:

```sh
zig build bench -- --format json
```

## Committed baseline artifacts
- `docs/benchmarks/baselines.md`
- `docs/benchmarks/baselines.json`

These artifacts are generated from this fixed fixture/policy matrix:
- `scenarios/basic/arrivals.zon` with `fcfs`
- `scenarios/basic/short-vs-long.zon` with `round_robin`
- `scenarios/basic/weighted-fairness.zon` with `cfs_like`
- `scenarios/basic/multicore-contention.zon` with `fcfs`
- `scenarios/basic/multicore-rr-quantum.zon` with `round_robin`
- `scenarios/basic/multicore-weighted.zon` with `cfs_like`

## Repeatability
Repeatability is the core guarantee for this workstream:
1. Run `zig build bench` twice.
2. Run `zig build bench -- --format json` twice.
3. Compare against the committed baseline artifacts.
4. Any intentional baseline shift should be reviewed and committed with the associated code change.

## Verification shape
Minimum checks:
- benchmark harness smoke
- repeatability check over fixed fixtures
- docs audit confirming simulator-local labeling

For the end-to-end reproducible report pack that also regenerates the benchmark
artifacts, see `docs/report-pipeline.md`.
