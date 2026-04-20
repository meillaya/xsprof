# Phase 1 Blocker Status

Latest revalidation against leader snapshot `cc3eaa8` on 2026-04-20.

## Blocker 1 — Builtin scenario format drift breaks the golden fixture

Commands:

```sh
zig build test
zig build run -- show short-vs-long
```

Actual result:
- `zig build test` fails in `tests.scenario_test.test.builtin golden scenario fixture matches plan inputs`
- `zig build run -- show short-vs-long` fails with `error: ParseZon`

Current code evidence:
- `src/sim/scenario.zig` now parses builtin fixtures with `std.zon.parse.fromSlice(types.Scenario, ...)`
- `scenarios/basic/short-vs-long.zon` is still encoded in the older line-oriented format rather than structured ZON

Why this blocks signoff:
- the key Scenario C fixture no longer loads through the active builtin path
- the active test path is red
- even the public `show` command cannot inspect the golden scenario successfully

## Blocker 2 — Public CLI simulation path is still missing

Command:

```sh
zig build run -- --scenario short-vs-long --policy fcfs
```

Actual result:

```text
Usage:
  zig build run -- list
  zig build run -- show <scenario-name>
```

Current code evidence:
- `src/main.zig` still only handles:
  - `list`
  - `show <scenario-name>`
- no public CLI branch currently parses `--scenario`, `--policy`, or `--quantum`

Why this blocks signoff:
- the approved test spec requires a policy-selectable CLI run path
- final acceptance expects visible trace/timeline and metrics output from a runnable CLI command

## Blocker 3 — `src/root.zig` is still stale

Command:

```sh
zig test src/root.zig
```

Actual failure highlights:
- `ScenarioOwned`
- `loadScenarioByName`
- `parseScenarioText`

Current code evidence:
- `src/root.zig` still exports symbols that do not exist in the current `src/sim/types.zig` and `src/sim/scenario.zig` surfaces
- `src/lib.zig` is now the active scenario-loading surface, so `src/root.zig` is a stale duplicate boundary

Why this blocks signoff:
- it leaves a broken duplicate public surface in the repo
- it can mislead future integration or consumers even if the main build graph does not use it directly

## Remaining path to signoff

Task 3 can move to acceptance-ready only after:

1. builtin scenario fixtures are reconciled with the active parser format
2. `src/main.zig` exposes a working policy-run CLI simulation path
3. `src/root.zig` is reconciled with the current library surface or removed
4. these commands pass:

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

## Reviewer disposition

Current state: **still blocked, with three concrete blockers**.

The failure set is still implementation-local, but the scenario-format mismatch now also breaks the active test path and should be fixed before any final signoff attempt.
