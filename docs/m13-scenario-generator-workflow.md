# M13 Scenario Generation, Shrinking, and Regression Workflow

M13 adds a workflow goal rather than a Linux-facing claim: generate valid deterministic simulator scenarios, shrink failing cases, and preserve reduced failures as repo-local regression fixtures.

## Scope boundary
- Scenario generation in this repo is for the simulator's public scenario contract.
- Shrinking is for reducing deterministic simulator failures to smaller reproducible fixtures.
- Property/invariant checks in this repo are simulator-local evidence surfaces, not Linux scheduler proofs.

## Generator output contract
Any generated scenario should still land in the same canonical object-style ZON format accepted by `--scenario-file`.

That means generated cases must stay within the documented public surface:
- non-empty scenario name
- positive `burst_ticks`
- stable task ids
- positive `core_count` when present
- supported `weight`, `deadline_tick`, `groups`, `topology_domains`, and `phases` values when those features are used
- deterministic declaration order so tie-break behavior remains reproducible

The generator should prefer the smallest feature set needed for the property under test. For example, a fairness property may need weighted tasks, while a topology property may need explicit `core_count` and `topology_domains`.

## Shrinking discipline
When a generated case fails an invariant:
1. keep the failing predicate explicit
2. shrink task count, burst sizes, and optional features while preserving the same failure
3. stop when removing another element would lose the failure or obscure the teaching value

A good shrunk fixture should remain readable enough for a future reviewer to understand why it fails.

## Regression fixture save path
Save minimized failing scenarios under:

- `scenarios/regressions/`

Use lowercase kebab-case names that summarize the preserved failure, for example:
- `scenarios/regressions/cfs-weighted-starvation-min.zon`
- `scenarios/regressions/topology-duplicate-domain-core.zon`

Keep generated or shrunk regression cases separate from `scenarios/basic/`.

- `scenarios/basic/` remains the curated teaching/demo corpus.
- `scenarios/regressions/` is for minimized failure-preserving fixtures.

If a regression fixture later becomes a canonical teaching example, copy or rewrite it into `scenarios/basic/` with explanation docs instead of silently reusing the raw regression artifact.

## Recommended review invariants
Useful M13 properties should stay close to the simulator's documented guarantees:
- repeated runs of the same scenario stay deterministic
- per-task accounting remains internally consistent
- generated scenarios satisfy parser/validation rules
- saved regressions remain loadable through `--scenario-file`
- export/analysis claims stay bounded to simulator-local behavior

## Evidence wording
When documenting generator or shrinker results, keep wording bounded:
- say "simulator-local invariant" instead of broad scheduler correctness claims
- say "deterministic regression fixture" instead of "real-world workload"
- avoid implying Linux kernel fidelity, fuzz-hardening, or production safety from these checks alone
