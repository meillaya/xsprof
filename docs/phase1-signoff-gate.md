# Phase 1 Signoff Gate

Leader snapshot under review: `cc3eaa8`

Phase 1 must not be signed off until **all** gate checks below are green.

## Gate checks

| Check | Command | Current status | Required for signoff |
| --- | --- | --- | --- |
| Build | `zig build` | PASS | yes |
| Active test graph | `zig build test --summary all` | PASS | yes |
| Policy-run CLI smoke: FCFS | `zig build run -- --scenario short-vs-long --policy fcfs` | FAIL | yes |
| Policy-run CLI smoke: RR | `zig build run -- --scenario short-vs-long --policy rr --quantum 2` | FAIL by same missing path | yes |
| Policy-run CLI smoke: CFS-like | `zig build run -- --scenario short-vs-long --policy cfs-like` | FAIL by same missing path | yes |
| Stale-surface check | `zig test src/root.zig` | FAIL | yes |

## Current failing gate details

### Missing policy-run CLI path

Current output for:

```sh
zig build run -- --scenario short-vs-long --policy fcfs
```

is only:

```text
Usage:
  zig build run -- list
  zig build run -- show <scenario-name>
```

Implication:
- `src/main.zig` still does not expose the required public simulation execution path.

### Stale `src/root.zig`

Current failure for:

```sh
zig test src/root.zig
```

includes unresolved/stale symbols:
- `ScenarioOwned`
- `loadScenarioByName`
- `parseScenarioText`

Implication:
- `src/root.zig` is still out of sync with the current library surface and must be reconciled or removed.

## Signoff rule

**Do not mark task 3 complete** until:
1. the three policy-run CLI smoke commands execute successfully and print the expected report sections
2. `zig test src/root.zig` passes, or the stale file is removed and the intended public surface is clear

## Once fixes land, rerun exactly

```sh
zig build
zig build test --summary all
zig build run -- --scenario short-vs-long --policy fcfs
zig build run -- --scenario short-vs-long --policy rr --quantum 2
zig build run -- --scenario short-vs-long --policy cfs-like
zig test src/root.zig
```
