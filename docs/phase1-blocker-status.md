# Phase 1 Blocker Status

Latest revalidation against leader snapshot `f290058` on 2026-04-20.

## Blocker 1 — Public CLI simulation path is still missing

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

## Blocker 2 — `src/root.zig` is still stale

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
- `src/root.zig` still references tests/files that are not present in the current source tree

Why this blocks signoff:
- it leaves a broken duplicate or stale public surface in the repo
- it can mislead future integration or consumers even if the main build graph stays green

## Remaining path to signoff

Task 3 can move to acceptance-ready only after:

1. `src/main.zig` exposes a working policy-run CLI simulation path
2. `src/root.zig` is reconciled with the current library surface or removed
3. these commands pass:

```sh
zig build
zig build test --summary all
zig build run -- --scenario short-vs-long --policy fcfs
zig build run -- --scenario short-vs-long --policy rr --quantum 2
zig build run -- --scenario short-vs-long --policy cfs-like
zig test src/root.zig
```

## Reviewer disposition

Current state: **still blocked, but narrowly so**.

The remaining failures are unchanged, concrete, and implementation-local.
