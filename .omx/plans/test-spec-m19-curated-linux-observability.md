# Test Spec — M19 curated Linux-observability snapshots

## Status
Draft for consensus review on 2026-04-21

## Scope under test
- approved offline import contract only
- fixture admission and manifest validation
- tuple/version enforcement
- separation from simulator-native assets
- observability-only wording discipline
- explicit non-widening of `zig-scheduler/report`

## Required verification
1. M18 approval audit
2. parser/import tests for the approved capture family only (`tracefs-sched-snapshot`)
3. provenance manifest checks
4. scrub/privacy checks
5. tuple/version enforcement
6. fixture separation checks
7. import -> observability-summary smoke
8. docs wording audit against replay/performance overclaiming
9. unsupported-family audit rejecting:
   - `perf sched`
   - generic `perf.data`
   - `perf script`
   - `trace_pipe`
   - non-sched tracepoints

## Minimum checks
- import parser tests
- provenance metadata checks
- tuple/version rejection tests
- fixture admission audit
- import -> observability-summary smoke
- README / project-status / ADR wording audit
- unsupported-family rejection tests
- explicit assertion that M19 does not route imported Linux fixtures into the existing `zig-scheduler/report` analyzer/contract

## Non-goals for this milestone
- live capture
- multi-family import breadth
- calibration/comparison logic
- Linux-performance or fidelity claims
