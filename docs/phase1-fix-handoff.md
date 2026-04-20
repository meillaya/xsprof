# Phase 1 Fix Handoff

This note is a focused handoff from the review lane to the implementation lane so the remaining Phase 1 blockers can be closed with the smallest viable diff.

## Goal

Unblock final Phase 1 acceptance by fixing these remaining review findings:

1. builtin scenario loading is broken for the golden fixture
2. the public CLI does not yet run simulations by policy
3. `src/root.zig` is stale relative to the current library surface

## Blocker 1: reconcile builtin fixture format with the active parser

## Current observed behavior

These commands fail:

```sh
zig build test
zig build run -- show short-vs-long
```

The active loader in `src/sim/scenario.zig` parses builtin files through `std.zon.parse.fromSlice(types.Scenario, ...)`, but `scenarios/basic/short-vs-long.zon` is still stored in the older line-based format.

## Lowest-risk fix shape

Pick one canonical builtin fixture format and use it consistently.

### Recommended preference

Prefer **structured ZON** because the current loader, `types.Scenario`, and validation path already assume that shape.

### Minimum required follow-through

- convert `scenarios/basic/short-vs-long.zon` to structured ZON matching `types.Scenario`
- check whether any other builtin fixture still uses the older ad hoc format
- rerun:
  - `zig build test`
  - `zig build run -- show short-vs-long`

## Blocker 2: wire the public CLI to actual simulation

## Current observed behavior

`src/main.zig` currently supports only:
- `list`
- `show <scenario-name>`

That means these required smoke commands still fail with usage output instead of executing a simulation:

```sh
zig build run -- --scenario short-vs-long --policy fcfs
zig build run -- --scenario short-vs-long --policy rr --quantum 2
zig build run -- --scenario short-vs-long --policy cfs-like
```

## Lowest-risk fix shape

Keep the existing `list` and `show` commands, and add one explicit execution path.

### Suggested CLI contract

Accept the smoke form already used in review verification:

```text
zig build run -- --scenario <name> --policy <fcfs|rr|cfs-like> [--quantum <n>]
```

If helpful, also support an explicit subcommand variant such as:

```text
zig build run -- run --scenario <name> --policy <fcfs|rr|cfs-like> [--quantum <n>]
```

## Required output sections

Route the final report through the existing report writer so output includes at least:
- scenario name
- policy name
- completion order
- trace or timeline
- per-task metrics
- aggregate metrics
- Phase 1 scope notes

## Blocker 3: reconcile or remove stale `src/root.zig`

## Current observed issue

`zig test src/root.zig` fails because `src/root.zig` still references symbols that do not match the currently active library surface.

Observed stale references include names such as:
- `ScenarioOwned`
- `loadScenarioByName`
- `parseScenarioText`

## Lowest-risk fix options

### Option A — remove `src/root.zig`

Choose this if `src/lib.zig` is the intended stable public entrypoint.

This is the safest option if no build step or user-facing contract depends on `src/root.zig`.

### Option B — update `src/root.zig` to mirror the currently supported surface

Choose this only if `src/root.zig` is intentionally meant to be a package/public boundary.

If updated, it should export only symbols that currently exist and are actively supported.

## Recommended preference

Prefer **Option A (remove)** unless there is a concrete consumer that requires `src/root.zig`.

Reason:
- `src/lib.zig` already exposes the active scenario-loading surface
- dead duplicate surfaces increase confusion
- the file is currently broken and stale relative to the current tree

## Acceptance rerun after fixes

Once the implementation lane lands the builtin fixture fix, CLI wiring, and `src/root.zig` cleanup, rerun exactly:

```sh
zig build
zig build test
zig build run -- list
zig build run -- show short-vs-long
zig build run -- --scenario short-vs-long --policy fcfs
zig build run -- --scenario short-vs-long --policy rr --quantum 2
zig build run -- --scenario short-vs-long --policy cfs-like
zig test src/root.zig
```

## Acceptance expectation

Task 3 can move from review-blocked to acceptance-ready when:
- the golden builtin fixture loads successfully
- all commands above pass
- output includes trace/timeline and metrics sections
- docs remain Linux-inspired rather than Linux-faithful
- no phase-creep indicators appear in implementation files
