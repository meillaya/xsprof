# Phase 1 Verification Report

Verified on leader repository snapshot `caa3368` on 2026-04-20.

## Summary verdict

Build, tests, formatting, scenario fixtures, and Phase 1 scope-boundary checks pass on the leader snapshot.

However, Phase 1 is **not yet fully aligned with the approved test spec** because the installed CLI only supports `list` and `show`, while the test spec requires a policy-selectable simulation command that prints trace/timeline and metrics. There is also a stale `src/root.zig` surface that fails standalone compilation and references missing APIs/tests.

## Verification results

### PASS — build

Command:

```sh
zig build
```

Result:
- exited successfully with no build errors

### PASS — test suite

Command:

```sh
zig build test --summary all
```

Result:

```text
Build Summary: 5/5 steps succeeded; 5/5 tests passed
```

### PASS — formatting

Command:

```sh
zig fmt --check build.zig build.zig.zon $(find src -type f \( -name '*.zig' -o -name '*.zon' \) | sort) $(find scenarios -type f -name '*.zon' | sort)
```

Result:
- exited successfully with no formatting diffs

### PASS — canned scenario discovery

Command:

```sh
zig build run -- list
```

Result:
- lists `arrivals`, `contention`, and `short-vs-long`

Command:

```sh
zig build run -- show short-vs-long
```

Result:
- prints the Scenario C definition with quantum `2` and tasks `L`, `S1`, `S2`

### PASS — scope-boundary grep

Searched implementation files only (`build.zig`, `build.zig.zon`, `src/**/*.zig`, `scenarios/**/*.zon`) for obvious phase-creep markers.

Checked terms:
- `std.process.Child`
- `fork`
- `execve`
- `sched_set`
- `sched_get`
- `daemon`
- `systemd`

Result:
- no hits in implementation/scenario files
- note: `std.process.argsAlloc` is used in `src/main.zig` for CLI argument parsing only and does not indicate process spawning

### PASS — docs wording guardrails

Content checks passed for:
- `docs/phase1-linux-mapping.md`
- `docs/phase1-verification-checklist.md`
- `docs/phase1-scenario-c-walkthrough.md`

These docs explicitly preserve:
- simulator-only scope
- no real process execution
- no kernel integration
- CFS-inspired wording instead of Linux-faithful claims

## Failures / gaps

### FAIL — CLI does not yet execute simulations by policy

Spec expectation:
- the CLI should allow a scenario to be run under selectable policies and print completion order, per-task metrics, aggregate metrics, and trace/timeline output

Observed commands:

```sh
zig build run -- --scenario short-vs-long --policy fcfs
zig build run -- --scenario short-vs-long --policy rr --quantum 2
zig build run -- --scenario short-vs-long --policy cfs-like
```

Observed result for each:

```text
Usage:
  zig build run -- list
  zig build run -- show <scenario-name>
```

Interpretation:
- the library/reporting layer exists (`src/cli/output.zig`), but `src/main.zig` has not yet wired policy execution into the public CLI
- this blocks full end-to-end acceptance against the test spec's CLI expectations

### FAIL — stale root surface

Command:

```sh
zig test src/root.zig
```

Result:
- compile failure
- `src/root.zig` exports missing APIs/types such as `ScenarioOwned`, `loadScenarioByName`, and `parseScenarioText`
- it also references missing test files in its `test` block

Interpretation:
- this file appears stale or partially migrated
- it is not currently in the `zig build test` path, so the main build stays green, but it is a quality/repo-consistency issue worth fixing or removing

## Recommended next fixes

1. Extend `src/main.zig` so the CLI can actually run a scenario under `fcfs`, `round_robin`, and `cfs_like`.
2. Reuse `src/cli/output.zig` for the public CLI report path so trace and metrics output become user-visible.
3. Either update or remove `src/root.zig` so stale exports and missing test imports do not linger as dead surfaces.
4. After CLI wiring lands, rerun:
   - `zig build`
   - `zig build test --summary all`
   - `zig build run -- --scenario short-vs-long --policy fcfs`
   - `zig build run -- --scenario short-vs-long --policy rr --quantum 2`
   - `zig build run -- --scenario short-vs-long --policy cfs-like`

## Current disposition

- Verification evidence is ready for integration review.
- Build/test baseline is green.
- Final acceptance is blocked on CLI execution wiring and stale-root cleanup.
