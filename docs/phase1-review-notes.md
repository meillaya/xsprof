# Phase 1 Review Notes

Reviewed against:
- `.omx/plans/prd-phase1-zig-scheduler-simulator.md`
- `.omx/plans/test-spec-phase1-zig-scheduler-simulator.md`
- leader snapshot `247ada3`

## Review outcome

The current leader snapshot is **acceptance-ready for Phase 1**.

The repository now presents a coherent, reviewable Phase 1 surface:
- `zig build` passes
- `zig build test` passes
- builtin scenarios list and load successfully
- the public CLI can run a scenario under selectable policies
- trace, per-task metrics, and aggregate metrics are visible in the CLI report
- `src/root.zig` compiles and aligns with the active library surface
- documentation still preserves the simulator-only / Linux-inspired boundary

## Verified strengths

### 1. Public CLI now exposes the simulation path

**Evidence**
- `src/main.zig` supports the review/test-spec smoke form:
  - `--scenario <name>`
  - `--policy <fcfs|rr|cfs-like>`
  - optional `--quantum <n>`
- the following commands execute successfully and print the expected report shape:
  - `zig build run -- --scenario short-vs-long --policy fcfs`
  - `zig build run -- --scenario short-vs-long --policy rr --quantum 2`
  - `zig build run -- --scenario short-vs-long --policy cfs-like`

**Why this matters**
This closes the previous end-to-end acceptance gap: the public CLI now exercises the simulator through the exact policy-run path the test spec expects.

### 2. Builtin scenario loading is working again

**Evidence**
- `zig build run -- list` succeeds
- `zig build run -- show short-vs-long` succeeds
- `zig build test` passes, including the builtin golden-scenario loader test

**Why this matters**
The review lane can now verify the canonical Scenario C fixture through both tests and the public CLI.

### 3. `src/root.zig` is no longer stale

**Evidence**
- `zig test src/root.zig` passes
- `src/root.zig` now re-exports the active scenario/simulator surface instead of referencing missing APIs

**Why this matters**
The repo no longer carries a broken duplicate public boundary that could confuse future integration work.

## Non-blocking observations

### Scenario discovery names changed from earlier review snapshots
The current builtin scenario keys are:
- `staggered-arrivals`
- `equal-arrival-contention`
- `short-vs-long`

This is acceptable as long as docs and tests consistently use the current names.

### Documentation boundary language remains good
Current docs still preserve:
- simulator-only scope
- no real process execution
- no kernel integration
- CFS-inspired rather than Linux-faithful wording

## Suggested final signoff sequence

Re-run these commands on the integration branch when closing the loop:
- `zig build`
- `zig build test`
- `zig build run -- list`
- `zig build run -- show short-vs-long`
- `zig build run -- --scenario short-vs-long --policy fcfs`
- `zig build run -- --scenario short-vs-long --policy rr --quantum 2`
- `zig build run -- --scenario short-vs-long --policy cfs-like`
- `zig test src/root.zig`

## Reviewer disposition

Current disposition: **accepted for Phase 1 signoff review**.

The earlier narrow blockers are resolved in the current snapshot, and the implementation now matches the intended Phase 1 review surface.
