# Phase 1 Review Notes

Reviewed against:
- `.omx/plans/prd-phase1-zig-scheduler-simulator.md`
- `.omx/plans/test-spec-phase1-zig-scheduler-simulator.md`
- leader snapshot `cc3eaa8`

## Review outcome

The repository still has a solid Phase 1 foundation:
- `zig build` passes
- policy, engine, metrics, and reporting code exist
- review/docs artifacts are present and keep the Phase 1 boundary explicit
- Linux-inspired wording is still mostly disciplined

However, the current leader snapshot should still be treated as **not yet accepted** for Phase 1 because three concrete issues now block alignment with the approved test spec.

## Blocking findings

### 1. Builtin scenario loading is currently broken for the golden fixture

**Evidence**
- `zig build test` fails in `src/tests/scenario_test.zig`
- `zig build run -- show short-vs-long` fails with `error: ParseZon`
- `src/sim/scenario.zig` parses builtin fixtures through `std.zon.parse.fromSlice(types.Scenario, ...)`
- `scenarios/basic/short-vs-long.zon` is still in the older line-oriented format:
  - `name: short-vs-long`
  - `rr_quantum: 2`
  - `task: ...`

**Why this blocks acceptance**
The active loader now expects structured ZON, but at least the golden scenario fixture is still encoded in the prior ad hoc text format. This breaks both the test path and builtin scenario inspection for the key Scenario C artifact.

**Recommended fix**
- reconcile builtin scenario files to one format only
- if ZON is now the canonical format, convert `short-vs-long.zon` (and any remaining old-format fixtures) to the current `types.Scenario` shape
- rerun `zig build test` and `zig build run -- show short-vs-long`

### 2. Public CLI still does not expose policy-run simulation

**Evidence**
- `src/main.zig` only supports:
  - `list`
  - `show <scenario-name>`
- smoke commands required by the test spec still print usage text:
  - `zig build run -- --scenario short-vs-long --policy fcfs`
  - `zig build run -- --scenario short-vs-long --policy rr --quantum 2`
  - `zig build run -- --scenario short-vs-long --policy cfs-like`

**Why this blocks acceptance**
The test spec requires a public CLI path that can select a policy, run a scenario, and print completion order, trace/timeline, per-task metrics, and aggregate metrics. That end-to-end surface is still missing from the current CLI even though related reporting components exist elsewhere in the tree.

**Recommended fix**
- add a simulation execution path to `src/main.zig`
- support the review/test-spec smoke form `--scenario <name> --policy <...> [--quantum <n>]`
- route the final output through the existing report writer instead of duplicating presentation logic

### 3. `src/root.zig` remains stale and broken

**Evidence**
`zig test src/root.zig` fails because `src/root.zig` still references symbols that do not exist in the current source tree, including:
- `types.ScenarioOwned`
- `scenario.loadScenarioByName`
- `scenario.parseScenarioText`

It also still points at an older simulator-oriented surface while `src/lib.zig` now exposes the active scenario-loading API.

**Why this blocks acceptance**
Even if the main build graph can stay green without this file, it leaves a broken duplicate public surface in the repo and makes the package boundary confusing for future contributors or consumers.

**Recommended fix**
Choose one and do it consistently:
- remove `src/root.zig` if `src/lib.zig` is the intended public entrypoint, or
- rewrite `src/root.zig` so it mirrors only the currently supported exports

## Non-blocking strengths

### Build still succeeds
- `zig build` passes on the current snapshot

### Scenario metadata discovery still works
- `zig build run -- list` succeeds and enumerates the three intended canned scenarios:
  - `arrivals`
  - `contention`
  - `short-vs-long`

### Documentation boundary language remains good
Current docs still preserve:
- simulator-only scope
- no real process execution
- no kernel integration
- CFS-inspired rather than Linux-faithful wording

## Suggested acceptance sequence

1. Fix builtin scenario-format drift so Scenario C loads again
2. Add the public CLI simulation execution path in `src/main.zig`
3. Fix or remove stale `src/root.zig`
4. Re-run verification:
   - `zig build`
   - `zig build test`
   - `zig build run -- list`
   - `zig build run -- show short-vs-long`
   - `zig build run -- --scenario short-vs-long --policy fcfs`
   - `zig build run -- --scenario short-vs-long --policy rr --quantum 2`
   - `zig build run -- --scenario short-vs-long --policy cfs-like`
   - `zig test src/root.zig`

## Reviewer disposition

Current disposition: **still blocked, and now more clearly so than the previous review snapshot**.

The remaining issues are still narrow and implementation-local, but the repo is no longer at a simple “two blockers left” state because scenario-format drift now breaks the active test path as well.
