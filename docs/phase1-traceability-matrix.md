# Phase 1 Traceability Matrix

This matrix links the approved Phase 1 PRD/test-spec requirements to the current leader implementation snapshot and the review lane's evidence.

Reviewed against leader snapshot `cc3eaa8`.

## Status legend

- **PASS** — requirement appears satisfied by current evidence
- **PARTIAL** — foundation exists but acceptance is incomplete
- **FAIL** — requirement is currently unmet by review evidence

## Requirement traceability

| Requirement | Evidence / file(s) | Status | Notes |
| --- | --- | --- | --- |
| Zig build scaffold exists and builds on Zig 0.15.2 | `build.zig`; `zig build` | PASS | Build succeeded during verification |
| In-process simulator only | implementation review + scoped grep evidence in review docs | PASS | No phase-creep indicators were the focus of the current blockers |
| Three policies supported in code | `src/policies/fcfs.zig`; `src/policies/round_robin.zig`; `src/policies/cfs_like.zig` | PASS | Policy code exists in the tree |
| Deterministic scenario fixtures exist conceptually | `scenarios/basic/*.zon` | PARTIAL | Metadata and files exist, but the golden builtin fixture currently fails to parse through the active loader |
| Raw trace/reporting surfaces exist | `src/cli/output.zig`; simulator modules | PASS | Reporting/building blocks exist, but not all are wired into the public CLI |
| Per-task metrics exist | simulator/reporting modules | PASS | Completion, turnaround, waiting, and response surfaces exist |
| Aggregate metrics exist | simulator/reporting modules | PASS | Average waiting, average response, throughput, waiting-time spread |
| Linux mapping docs exist | `docs/phase1-linux-mapping.md` | PASS | Review docs preserve simulator-only and Linux-inspired wording |
| Scenario C explanatory docs exist | `docs/phase1-scenario-c-walkthrough.md` | PASS | Walkthrough still documents the teaching example |
| Verification checklist exists | `docs/phase1-verification-checklist.md` | PASS | Checklist remains useful for final reruns |
| Public CLI can list builtin scenarios | `src/main.zig`; `zig build run -- list` | PASS | Metadata discovery still works |
| Public CLI can show builtin scenario details | `src/main.zig`; `zig build run -- show short-vs-long` | FAIL | `show` currently fails because the builtin golden fixture does not parse |
| Public CLI can run a scenario under selectable policies and print report sections | `src/main.zig`; attempted smoke commands | FAIL | Policy-run execution path is still missing |
| Active build-graph tests pass | `zig build test` | FAIL | Current test path fails in builtin scenario parsing |
| Stale public/dead surfaces are reconciled | `src/root.zig`; `zig test src/root.zig` | FAIL | File references missing APIs and fails standalone compilation |
| End-to-end smoke verification for policy-run CLI commands | attempted `zig build run -- --scenario ... --policy ...` | FAIL | Commands still return usage output |

## Acceptance blockers summarized

Three items keep the matrix from full PASS status:

1. **Builtin fixture / parser mismatch**
   - the active loader expects structured ZON
   - the golden scenario fixture is still in the older format
   - this breaks `zig build test` and `zig build run -- show short-vs-long`

2. **Missing public CLI simulation path**
   - `src/main.zig` does not yet accept policy-run commands
   - the required trace/metrics report cannot be exercised end-to-end from the CLI

3. **Stale `src/root.zig` surface**
   - standalone compilation fails
   - exports do not match the current active library surface

## Fastest path to all-green

1. Convert remaining old-format builtin scenario fixtures to the active ZON `types.Scenario` shape
2. Wire `src/main.zig` to run simulations by policy using the existing report writer
3. Remove or reconcile `src/root.zig`
4. Rerun:

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

Current status: **close in scope, but not signoff-ready**.

The implementation still appears near completion, but the live acceptance picture is now blocked by three concrete failures rather than the earlier two-blocker snapshot.
