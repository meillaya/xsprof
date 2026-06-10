# SIMULATOR CORE NOTES

## OVERVIEW
`src/sim` owns deterministic scheduler data types, scenario parsing/loading, engine execution, metrics, and trace events.

## WHERE TO LOOK
| Task | Location | Notes |
|------|----------|-------|
| Core data model | `types.zig` | Publicly re-exported by `src/root.zig`; allocator ownership matters. |
| Tick loop / scheduling behavior | `engine.zig` | Algorithmically sensitive hot path. |
| Scenario formats and loading | `scenario.zig` | Legacy line-style and object-style ZON coexist. |
| Scenario registry/packs | `scenario_pack.zig` | Drives teaching shortlist, dashboard presets, optional regression pack. |
| Metrics/trace contracts | `metrics.zig`, `trace.zig` | Report/analysis consumers depend on stable meanings. |

## CONVENTIONS
- Preserve determinism: ordering, tie-breaks, queue behavior, trace event order, and floating comparisons are test contracts.
- Keep parser compatibility isolated in `scenario.zig`; new fixtures should prefer canonical object-style ZON even though legacy line-style remains supported.
- Do not bypass policy class/extension boundaries from `src/policies`; engine behavior should remain policy-kind driven through the intended boundary.
- Complexity notes are required for engine/parser changes that add scans inside tick loops, ready queues, or fixture resolution paths.
- Every allocator-owned scenario/result must have an obvious `deinit` path in tests and call sites.

## ANTI-PATTERNS
- Do not add nondeterministic iteration over unordered data where results affect traces or metrics.
- Do not widen scenario corpus semantics from parser convenience alone; update tests and scenario pack metadata together.
- Do not make observability fixtures imply simulator fidelity to Linux; that boundary lives outside core sim and remains offline-only.

## VERIFY
```bash
zig build test --summary all
zig build sim -- list
zig build sim -- --scenario short-vs-long --policy fcfs --format json
```
