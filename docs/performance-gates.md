# performance gates

This is the canonical performance gate for simulator-lab/product quality.
It is reproducible, fixture-local, and bounded by ADR 0003: these numbers are
not Linux performance claims and do not authorize a daemon, service, agent, or
production runtime.

## benchmark baseline

The committed baseline is `docs/benchmarks/baselines.json` and the rendered
human review is `docs/benchmarks/baselines.md`. The baseline matrix comes
from:

```sh
zig build bench -- --format markdown
zig build bench -- --format json
```

## reviewed budgets

Budgets live in `src/perf/root.zig` and are checked with:

```sh
zig build perf
```

Budget changes require a reviewed commit that explains whether the movement is a
baseline refresh, an intentional product tradeoff, or a regression that must be
fixed before release.

## Performance gate optimization responsibilities

| workstream | Responsibility | Evidence |
| --- | --- | --- |
| Engine allocation reduction | Pre-size ready queues, completion order, trace storage, and multicore per-tick scratch lists. | `src/sim/engine.zig`, `estimateTraceCapacity`, simulator tests. |
| Trace storage scaling | Trace capacity is estimated from CPU ticks, lifecycle events, blocking/wakeup phases, and core floor. | `sim.estimateTraceCapacity` tests. |
| Policy hot path optimization | Policy selection remains behind `src/policies/class.zig` and avoids report/dashboard imports. | architecture tests and budget gate. |
| Scenario parser optimization | Legacy parser validates numeric fields before allocating task IDs on error paths. | fault-injection leak-free parser tests. |
| Report export streaming | Report exporters write to caller-provided writers without building alternate ASTs. | CLI/SDK compatibility and benchmark export-byte budgets. |
| Dashboard render performance | Snapshot rendering is deterministic across compact, medium, and large tiers and avoids medium-height underflow. | TUI snapshot tests. |
| Analysis pipeline performance | Markdown/SVG byte ceilings are tracked in the performance gate. | `zig build perf`. |
| Reproducible performance gate | One command checks all deterministic budgets against the benchmark baseline. | `zig build perf`. |
