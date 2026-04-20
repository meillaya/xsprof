# Phase 1 Review Notes

Reviewed against:
- `.omx/plans/prd-phase1-zig-scheduler-simulator.md`
- `.omx/plans/test-spec-phase1-zig-scheduler-simulator.md`
- leader snapshot `caa3368`

## Review outcome

The implementation has a solid Phase 1 foundation:
- build passes
- tests in the active build graph pass
- canned scenarios exist
- trace/metrics reporting code exists
- docs keep the Linux-inspired / simulator-only boundary clear

But the current leader snapshot should still be treated as **not yet accepted** for Phase 1 because two review findings block full alignment with the approved test spec.

## Blocking findings

### 1. Public CLI does not expose the simulation path

**Evidence**
- `src/main.zig` only supports:
  - `list`
  - `show <scenario-name>`
- policy-run smoke commands required by the test spec return usage text instead of executing a simulation

**Why this blocks acceptance**
The test spec requires a CLI path that can:
- select a policy
- run a scenario
- print completion order
- print trace/timeline
- print per-task metrics
- print aggregate metrics

That report surface already exists in `src/cli/output.zig`, but it is not wired into `src/main.zig`.

**Recommended fix**
- add a `run` path in `src/main.zig`
- parse scenario + policy (+ RR quantum override if supported)
- call the simulation library
- route output through `src/cli/output.zig`

### 2. `src/root.zig` is stale and internally inconsistent

**Evidence**
`zig test src/root.zig` fails because `src/root.zig` references APIs and types that do not exist in the current tree, including:
- `types.ScenarioOwned`
- `scenario.loadScenarioByName`
- `scenario.parseScenarioText`
- missing test imports listed in its `test` block

**Why this matters**
Even though this surface is not on the current `zig build test` path, it is still a misleading dead surface in the repo and can confuse future integration or package consumers.

**Recommended fix**
Choose one and do it consistently:
- update `src/root.zig` to match the current library surface, or
- remove it if `src/lib.zig` is the intended stable entrypoint

## Non-blocking strengths

### Deterministic scenario fixtures exist
- `arrivals`
- `contention`
- `short-vs-long`

This matches the required scenario shape from the test spec.

### Documentation guardrails are good
Current docs correctly state:
- simulator only
- no real process execution
- no kernel integration
- CFS-inspired rather than Linux-faithful wording

### Scope discipline is intact
Scoped review did not find signs of phase creep such as process spawning or kernel scheduler integration in implementation files.

## Suggested acceptance sequence

1. Fix CLI wiring in `src/main.zig`
2. Fix or remove stale `src/root.zig`
3. Re-run verification:
   - `zig build`
   - `zig build test --summary all`
   - `zig build run -- --scenario short-vs-long --policy fcfs`
   - `zig build run -- --scenario short-vs-long --policy rr --quantum 2`
   - `zig build run -- --scenario short-vs-long --policy cfs-like`
4. If those pass, task 3 can move from review-blocked to acceptance-ready

## Reviewer disposition

Current disposition: **conditionally promising, not yet acceptable**.

The project is close, but the team should not mark Phase 1 complete until the public CLI executes simulations as specified and the stale root surface is resolved.
