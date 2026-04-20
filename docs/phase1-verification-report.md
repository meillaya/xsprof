# Phase 1 Verification Report

Verified on leader repository snapshot `cc3eaa8` on 2026-04-20.

## Summary verdict

The current snapshot is **not yet aligned** with the approved Phase 1 test spec.

What still works:
- `zig build`
- `zig build run -- list`
- review docs continue to preserve the simulator-only / Linux-inspired boundary

What now fails or remains incomplete:
- `zig build test` fails because builtin scenario parsing does not match the golden fixture file format
- `zig build run -- show short-vs-long` fails with `ParseZon`
- the public CLI still cannot run a scenario under selectable policies and print the required trace/metrics report
- `src/root.zig` is still stale and fails standalone compilation

## Verification results

### PASS — build

Command:

```sh
zig build
```

Result:
- exited successfully with no build errors

### FAIL — test suite

Command:

```sh
zig build test
```

Result:
- failed in `tests.scenario_test.test.builtin golden scenario fixture matches plan inputs`
- failure path ends in `std.zon.parse.fromSlice(...)` returning `error.ParseZon`
- the active loader expects ZON, but the golden scenario fixture is still stored in the earlier line-oriented format

### PASS — builtin scenario metadata list

Command:

```sh
zig build run -- list
```

Result:
- lists `arrivals`, `contention`, and `short-vs-long`

Interpretation:
- builtin metadata registration is still wired
- this does **not** prove fixture loading works

### FAIL — builtin scenario display for Scenario C

Command:

```sh
zig build run -- show short-vs-long
```

Result:
- fails with `error: ParseZon`

Interpretation:
- scenario metadata exists, but loading the golden fixture currently fails

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
- the public CLI still only supports `list` and `show`
- the required end-to-end policy-run smoke path is still missing

### FAIL — stale root surface

Command:

```sh
zig test src/root.zig
```

Result:
- compile failure
- `src/root.zig` references missing APIs/types such as:
  - `ScenarioOwned`
  - `loadScenarioByName`
  - `parseScenarioText`

Interpretation:
- this file is still stale relative to the currently active `src/lib.zig` surface
- it remains a repo-consistency and public-surface quality issue

### PASS — review docs still preserve scope wording

Checked docs continue to preserve:
- simulator-only scope
- no real process execution
- no kernel integration
- CFS-inspired wording rather than Linux-faithful claims

## Failures / gaps summary

Three issues now block acceptance:

1. **Scenario fixture / parser mismatch**
   - active builtin loader expects ZON
   - `short-vs-long.zon` is still stored in the older ad hoc format
   - this breaks `zig build test` and `zig build run -- show short-vs-long`

2. **Missing public CLI simulation path**
   - `src/main.zig` still cannot run scenarios by policy
   - required trace/metrics report cannot be exercised end-to-end from the public CLI

3. **Stale `src/root.zig` surface**
   - standalone compilation still fails
   - exports do not match the current library surface

## Recommended next fixes

1. Convert the remaining old-format builtin scenario fixtures to the active ZON `types.Scenario` shape.
2. Extend `src/main.zig` so the CLI can run a scenario under `fcfs`, `rr`, and `cfs-like`.
3. Reuse the existing report writer for public CLI output.
4. Either update or remove `src/root.zig` so broken duplicate exports do not linger.
5. After fixes land, rerun:
   - `zig build`
   - `zig build test`
   - `zig build run -- list`
   - `zig build run -- show short-vs-long`
   - `zig build run -- --scenario short-vs-long --policy fcfs`
   - `zig build run -- --scenario short-vs-long --policy rr --quantum 2`
   - `zig build run -- --scenario short-vs-long --policy cfs-like`
   - `zig test src/root.zig`

## Current disposition

- Verification evidence is updated to the live snapshot.
- The repo is **not signoff-ready**.
- Acceptance is now blocked by three concrete, local issues rather than the earlier two-blocker picture.
