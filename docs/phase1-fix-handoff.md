# Phase 1 Fix Handoff

This note is a focused handoff from the review lane to the implementation lane so the remaining Phase 1 blockers can be closed with the smallest viable diff.

## Goal

Unblock final Phase 1 acceptance by fixing the two remaining review findings:

1. the public CLI does not yet run simulations by policy
2. `src/root.zig` is stale relative to the current library surface

## Blocker 1: wire the public CLI to actual simulation

## Current observed behavior

`src/main.zig` currently supports only:
- `list`
- `show <scenario-name>`

That means these required smoke commands fail with usage output instead of executing a simulation:

```sh
zig build run -- --scenario short-vs-long --policy fcfs
zig build run -- --scenario short-vs-long --policy rr --quantum 2
zig build run -- --scenario short-vs-long --policy cfs-like
```

## Lowest-risk fix shape

Keep the existing `list` and `show` commands, and add one explicit execution path.

### Suggested CLI contract

Accept a form like:

```text
zig build run -- run --scenario <name> --policy <fcfs|rr|cfs-like> [--quantum <n>]
```

If preserving the exact test-spec smoke commands is preferred, then also support:

```text
zig build run -- --scenario <name> --policy <fcfs|rr|cfs-like> [--quantum <n>]
```

The second form is the one already used in review verification and aligns best with the current acceptance notes.

## Required output sections

Route the final report through the existing report writer so output includes at least:
- scenario name
- policy name
- completion order
- trace or timeline
- per-task metrics
- aggregate metrics
- Phase 1 scope notes

`src/cli/output.zig` already contains this report shape and should be reused rather than duplicated.

## Likely implementation sequence

1. Parse the requested scenario name
2. Parse the policy token:
   - `fcfs`
   - `rr` -> internal round-robin enum
   - `cfs-like` -> internal cfs-like enum
3. Load the scenario through the existing scenario loader
4. If `--quantum` is supplied, apply it consistently to the scenario/config used by the simulator
5. Run the simulation
6. Print the report with the existing CLI report writer

## Review guardrails

While wiring the CLI:
- keep Phase 1 simulator-only wording intact
- do not add real process execution
- keep deterministic raw trace semantics unchanged
- keep CFS wording explicitly Linux-inspired / simplified

## Blocker 2: reconcile or remove stale `src/root.zig`

## Current observed issue

`zig test src/root.zig` fails because `src/root.zig` references symbols that do not match the currently visible library surface.

Observed stale references include names such as:
- `ScenarioOwned`
- `loadScenarioByName`
- `parseScenarioText`
- missing test imports referenced in the file's `test` block

## Lowest-risk fix options

### Option A — remove `src/root.zig`

Choose this if `src/lib.zig` is the intended stable public entrypoint.

This is the safest option if no build step or user-facing contract depends on `src/root.zig`.

### Option B — update `src/root.zig` to mirror `src/lib.zig`

Choose this only if `src/root.zig` is intentionally meant to be a package/public surface.

If updated, it should export only symbols that currently exist and are actually supported.

## Recommended preference

Prefer **Option A (remove)** unless there is a concrete consumer that requires `src/root.zig`.

Reason:
- the repo already has `src/lib.zig`
- dead duplicate surfaces increase confusion
- the review lane already confirmed `src/root.zig` is not aligned with active tests/build usage

## Acceptance rerun after fixes

Once the implementation lane lands the CLI wiring and resolves `src/root.zig`, rerun exactly:

```sh
zig build
zig build test --summary all
zig build run -- --scenario short-vs-long --policy fcfs
zig build run -- --scenario short-vs-long --policy rr --quantum 2
zig build run -- --scenario short-vs-long --policy cfs-like
```

## Acceptance expectation

Task 3 can move from review-blocked to acceptance-ready when:
- all commands above pass
- output includes trace/timeline and metrics sections
- docs remain Linux-inspired rather than Linux-faithful
- no phase-creep indicators appear in implementation files
