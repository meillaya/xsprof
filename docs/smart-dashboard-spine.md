# smart dashboard spine

This is the canonical information architecture for the one smart dashboard shell.
It preserves ADR 0003: the dashboard is a simulator-lab/product-quality surface,
not a daemon, service, agent, production runtime, or live automation system.

Run the generated contract view with:

```sh
zig build dashboard
```

## Screens

| workstream | Screen | Responsibility |
| --- | --- | --- |
| dashboard home | Home | one shell, launcher, current quality/perf status, no ad hoc TUI modes |
| dashboard scenario | Scenario | scenario metadata, parser mode, fixture provenance, drilldown entry |
| dashboard timeline | Timeline | trace replay, tick scrubber, deterministic snapshots |
| dashboard tasks | Tasks/Cores | task table, core lanes, runqueue/affinity/topology drilldowns |
| policy compare | Policy Compare | paired policy comparison, decision deltas, explainable differences |
| observability screen | Observability | offline fixture calibration, observability/comparison caveats, simulator-vs-observed mapping |
| performance screen | Performance | benchmark baseline, budget status, reproducible perf gate |
| reports/help | Reports | generated report pack status, export contract, release artifacts |
| reports/help | Help | keyboard help, screen glossary, ADR guardrails |

## Rule: no new ad hoc TUI modes

After dashboard home, new TUI experiences must be represented as screens or drilldowns in
`src/dashboard/root.zig`. Existing TUI views are mapped into the dashboard spine
by `src/tui/render.zig`; future work should replace old names gradually rather
than adding parallel one-off modes.
