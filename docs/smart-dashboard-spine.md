# M67-M74 smart dashboard spine

This is the canonical information architecture for the one smart dashboard shell.
It preserves ADR 0003: the dashboard is a simulator-lab/product-quality surface,
not a daemon, service, agent, production runtime, or live automation system.

Run the generated contract view with:

```sh
zig build dashboard
```

## Screens

| Milestone | Screen | Responsibility |
| --- | --- | --- |
| M67 | Home | one shell, launcher, current quality/perf status, no ad hoc TUI modes |
| M68 | Scenario | scenario metadata, parser mode, fixture provenance, drilldown entry |
| M69 | Timeline | trace replay, tick scrubber, deterministic snapshots |
| M70 | Tasks/Cores | task table, core lanes, runqueue/affinity/topology drilldowns |
| M71 | Policy Compare | paired policy comparison, decision deltas, explainable differences |
| M72 | Observability | offline fixture calibration, M19/M20 caveats, simulator-vs-observed mapping |
| M73 | Performance | benchmark baseline, budget status, reproducible perf gate |
| M74 | Reports | generated report pack status, export contract, release artifacts |
| M74 | Help | keyboard help, screen glossary, ADR guardrails |

## Rule: no new ad hoc TUI modes

After M67, new TUI experiences must be represented as screens or drilldowns in
`src/dashboard/root.zig`. Existing TUI views are mapped into the dashboard spine
by `src/tui/render.zig`; future work should replace old names gradually rather
than adding parallel one-off modes.
