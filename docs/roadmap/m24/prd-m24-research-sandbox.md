# PRD — M24 research sandbox branch for new policies / experiments

## Status
Execution PRD reconstructed from approved consensus summary on 2026-04-22.

## Goal
Create a bounded experimental policy sandbox that allows fast research work
without destabilizing the supported simulator teaching spine.

## Core decision
M24 is an explicitly unstable sandbox lane, not a new mainline policy milestone.
Stable teaching/core policy surfaces remain separate. Promotion from experiment
to supported milestone must be explicit and documented.

## Scope
M24 should add:
- one canonical experimental policy area under `src/policies/experimental/`
- one canonical sandbox governance doc: `docs/m24-research-sandbox.md`
- one explicit promotion-path section describing how experiments graduate
- one or two bounded example experimental policies or experiments
- boundary tests proving stable vs unstable separation

## Non-goals
- no browser/WASM
- no service/product scope
- no silent widening of the stable policy surface
- no broad research framework or many experimental policies at once

## Acceptance criteria
- experimental policies are clearly marked unstable
- stable docs do not present experimental policies as supported defaults
- promotion path is documented and auditable
- no widening of stable public/report/analysis contracts occurs
- full regression remains green

## Likely implementation files
- `src/policies/experimental/root.zig`
- `src/policies/experimental/lottery.zig` (or one similarly bounded experimental example)
- `docs/m24-research-sandbox.md`
- `README.md`
- `docs/project-architecture-and-status.md`
- `src/tests/policy_extension_boundary_test.zig`
- `src/tests/policy_architecture_test.zig`
- `src/tests/identity_gate_test.zig`

## Execution steps
1. Document sandbox purpose, unstable labeling, and promotion rules.
2. Add explicit experimental namespace under `src/policies/experimental/`.
3. Add one bounded experimental policy/example with no stable-root promotion.
4. Add tests for stable vs unstable labeling and promotion-path docs.
5. Update README/status docs so M24 is visible but clearly secondary.

## Verification
- `zig build test --summary all`
- sandbox labeling audit
- boundary tests where applicable
- governance/docs audit

## ADR mini
Decision: create a bounded experimental policy sandbox rather than mixing experiments into supported policy surfaces.
Why: preserve the teaching spine while enabling faster experimentation.
Alternatives rejected: direct stable-tree experimentation; overbuilt research framework.
Consequences: clearer unstable/stable split and explicit promotion rules.
