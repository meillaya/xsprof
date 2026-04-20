# Phase 1 Traceability Matrix

This matrix links the approved Phase 1 PRD/test-spec requirements to the current leader implementation snapshot and the review lane's evidence.

Reviewed against leader snapshot `247ada3`.

## Status legend

- **PASS** — requirement appears satisfied by current evidence
- **PARTIAL** — foundation exists but acceptance is incomplete
- **FAIL** — requirement is currently unmet by review evidence

## Requirement traceability

| Requirement | Evidence / file(s) | Status | Notes |
| --- | --- | --- | --- |
| Zig build scaffold exists and builds on Zig 0.15.2 | `build.zig`; `zig build` | PASS | Build succeeded during verification |
| In-process simulator only | implementation review + Phase 1 docs | PASS | Review surface remains simulator-only |
| Three policies supported in code | `src/policies/fcfs.zig`; `src/policies/round_robin.zig`; `src/policies/cfs_like.zig` | PASS | Policy code is present and exercised by tests/CLI |
| Deterministic scenario fixtures exist | `scenarios/basic/*.zon`; `zig build test`; `zig build run -- show short-vs-long` | PASS | Builtin fixtures load successfully through the active surface |
| Raw trace/reporting surfaces exist | `src/cli/output.zig`; simulator modules | PASS | Trace and report sections are visible in CLI output |
| Per-task metrics exist | simulator/reporting modules | PASS | Completion, turnaround, waiting, and response surfaces are present |
| Aggregate metrics exist | simulator/reporting modules | PASS | Average waiting, average response, throughput, waiting-time spread |
| Linux mapping docs exist | `docs/phase1-linux-mapping.md` | PASS | Docs preserve simulator-only and Linux-inspired wording |
| Scenario C explanatory docs exist | `docs/phase1-scenario-c-walkthrough.md` | PASS | Walkthrough documents the teaching example |
| Verification checklist exists | `docs/phase1-verification-checklist.md` | PASS | Checklist remains usable for final reruns |
| Public CLI can list builtin scenarios | `src/main.zig`; `zig build run -- list` | PASS | Metadata discovery works |
| Public CLI can show builtin scenario details | `src/main.zig`; `zig build run -- show short-vs-long` | PASS | Scenario details and quantum print successfully |
| Public CLI can run a scenario under selectable policies and print report sections | `src/main.zig`; policy-run smoke commands | PASS | FCFS, RR, and CFS-inspired runs all pass |
| Active build-graph tests pass | `zig build test` | PASS | All 15 tests passed |
| Stale public/dead surfaces are reconciled | `src/root.zig`; `zig test src/root.zig` | PASS | Root surface compiles and its tests pass |
| End-to-end smoke verification for policy-run CLI commands | `zig build run -- --scenario ... --policy ...` | PASS | Smoke commands execute successfully |

## Acceptance blockers summarized

No active Task 3 review blockers remain in the current snapshot.

## Reviewer disposition

Current status: **signoff-ready for the reviewed Phase 1 surface**.
