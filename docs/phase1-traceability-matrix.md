# Phase 1 Traceability Matrix

This matrix links the approved Phase 1 PRD/test-spec requirements to the current leader implementation snapshot and the review lane's evidence.

Reviewed against leader snapshot `caa3368`.

## Status legend

- **PASS** — requirement appears satisfied by current evidence
- **PARTIAL** — foundation exists but acceptance is incomplete
- **FAIL** — requirement is currently unmet by review evidence

## Requirement traceability

| Requirement | Evidence / file(s) | Status | Notes |
| --- | --- | --- | --- |
| Zig build scaffold exists and builds on Zig 0.15.2 | `build.zig`; `zig build` | PASS | Build succeeded during verification |
| In-process simulator only | `src/sim/engine.zig`; scoped grep on implementation files | PASS | No process-spawning or kernel-scheduler integration indicators found |
| Three policies supported | `src/policies/fcfs.zig`; `src/policies/round_robin.zig`; `src/policies/cfs_like.zig` | PASS | Policy code exists and build/test path passes |
| Deterministic scenario fixtures exist | `scenarios/basic/arrivals.zon`; `scenarios/basic/contention.zon`; `scenarios/basic/short-vs-long.zon`; `src/tests/scenario_test.zig` | PASS | Three required canned scenarios are present |
| Raw trace semantics exist | `src/sim/engine.zig`; `src/sim/trace.zig` | PASS | Engine records `arrival`, `dispatch`, `tick`, `preempt`, `complete`, `idle` |
| Per-task metrics exist | `src/sim/engine.zig`; `src/sim/metrics.zig`; `src/cli/output.zig` | PASS | Completion, turnaround, waiting, and response values are produced |
| Aggregate metrics exist | `src/sim/metrics.zig`; `src/cli/output.zig` | PASS | Average waiting, average response, throughput, waiting-time spread |
| Linux mapping docs exist | `docs/phase1-linux-mapping.md` | PASS | Scope guardrails and Linux-inspired wording documented |
| Scenario C explanatory docs exist | `docs/phase1-scenario-c-walkthrough.md` | PASS | Golden-oracle walkthrough prepared for review and teaching |
| Verification checklist exists | `docs/phase1-verification-checklist.md` | PASS | Review checklist aligned to PRD/test spec |
| Public CLI can list/show canned scenarios | `src/main.zig`; `zig build run -- list`; `zig build run -- show short-vs-long` | PASS | Discovery path works |
| Public CLI can run a scenario under selectable policies and print report sections | `src/main.zig`; `src/cli/output.zig`; attempted smoke commands | FAIL | Reporting code exists, but CLI execution path is not wired |
| Phase 1 docs preserve simulator-only and CFS-inspired wording | `docs/phase1-linux-mapping.md`; `docs/phase1-review-notes.md`; `docs/phase1-verification-report.md` | PASS | Review lane confirmed wording guardrails |
| Active build-graph tests pass | `zig build test --summary all` | PASS | 5/5 steps, 5/5 tests passed |
| Stale public/dead surfaces are reconciled | `src/root.zig`; `zig test src/root.zig` | FAIL | File references missing APIs/tests and fails standalone compilation |
| End-to-end smoke verification for policy-run CLI commands | attempted `zig build run -- --scenario ... --policy ...` | FAIL | Commands currently return usage output |

## Acceptance blockers summarized

Two items keep the matrix from full PASS status:

1. **Missing public CLI simulation path**
   - `src/main.zig` does not yet accept policy-run commands
   - required trace/metrics report cannot be exercised end-to-end from the CLI

2. **Stale `src/root.zig` surface**
   - standalone compilation fails
   - references do not match the current library surface

## Fastest path to all-green

1. Wire `src/main.zig` to run simulations by policy using the existing report writer in `src/cli/output.zig`
2. Remove or reconcile `src/root.zig`
3. Rerun:

```sh
zig build
zig build test --summary all
zig build run -- --scenario short-vs-long --policy fcfs
zig build run -- --scenario short-vs-long --policy rr --quantum 2
zig build run -- --scenario short-vs-long --policy cfs-like
```

## Reviewer disposition

Current status: **close, but not signoff-ready**.

The implementation already satisfies most Phase 1 requirements. The remaining failures are narrow, concrete, and implementation-local.
