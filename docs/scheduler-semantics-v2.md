# scheduling semantics v2

This document describes simulator-lab scheduling semantics only. It preserves
ADR 0003: no daemon, service, agent, kernel scheduler, or production automation
runtime is implemented or authorized here.

Run the generated contract view with:

```sh
zig build semantics
```

## Milestone map

| Milestone | Semantics | Contract owner |
| --- | --- | --- |
| semantics contract | Scheduling-class contract v2 names FCFS, Round Robin, CFS-inspired fairness, and deadline-inspired classes. | `src/semantics/root.zig` |
| priority mapping | Priority/nice semantics use deterministic `nice[-20,19]` to weight and priority mappings. | `niceToWeight`, `priorityFromNice` |
| fairness model | Fairness v2 normalizes virtual runtime by task nice weight and group weight. | `fairnessScore` |
| deadline admission | Deadline admission rejects zero-runtime and infeasible arrival/runtime/deadline windows. | `admitDeadline` |
| runqueue model | Multi-queue runqueue semantics identify global, per-core, and per-domain queues. | `RunQueueModel` |
| affinity model | Affinity/pinning semantics use explicit u64 masks and an all-cores helper. | `fullAffinity`, `allowsCore` |
| topology model | Topology cost model has same-core, same-domain, and cross-domain tiers. | `topologyCost` |
| group budget model | Group quota/burst accounting exposes remaining quota, burst debt, and throttling. | `groupBudgetState` |
| decision log | Explainable decision log emits stable task/core/reason rows. | `DecisionLog` |
| replay diff | Replay/diff engine reports the first deterministic decision mismatch. | `diffDecisions` |

These APIs are intentionally small and deterministic so future simulator policies,
TUI panels, and report explanations can consume the same semantics vocabulary
without reaching into engine internals.
