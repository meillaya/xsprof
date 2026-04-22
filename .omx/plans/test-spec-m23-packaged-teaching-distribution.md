# Test Spec — M23 packaged teaching distribution and courseware

## Status
Draft for consensus review on 2026-04-22

## Scope under test
- one bounded repo-native teaching distribution built on the M21 shortlist
- student onboarding from checkout to first simulator runs
- instructor guidance for the same bounded package
- one reproducible three-module assignment pack
- explicit preservation of simulator-first identity and bounded M19/M20 + M22 appendices

## Approved future proof surfaces
- `README.md`
- `docs/project-architecture-and-status.md`
- `docs/labs/simulator-teaching-pack.md`
- `docs/courseware/m23-teaching-distribution.md`
- `docs/courseware/student-onboarding.md`
- `docs/courseware/instructor-guide.md`
- `docs/courseware/assignment-pack-01.md`
- `docs/courseware/reproducibility-checklist.md`
- `src/tests/scenario_pack_test.zig`
- `src/tests/cli_smoke_test.zig`
- `src/tests/identity_gate_test.zig`

## Required verification
1. confirm the M23 package points to the exact M21 three-anchor shortlist and does not widen the required scenario set
2. confirm README exposes exactly one canonical M23 package entrypoint
3. confirm student onboarding instructions are executable from committed repo state
4. confirm instructor guide stays aligned with the same three-anchor package and repeats simulator-first boundary wording
5. confirm the assignment pack contains exactly three required modules:
   - `short-vs-long` + `fcfs`
   - `sleep-wakeup` + `cfs-like`
   - `multicore-balancing` + `fcfs`
6. confirm every published package command is covered by smoke validation
7. confirm M19/M20 references are appendix-only and explicitly bounded to offline observability
8. confirm M22 references are appendix-only and limited to `docs/m22-library-sdk.md` plus `zig build m22-embed-smoke`
9. confirm docs do not imply browser/WASM, service scope, live capture, replay authority, or Linux-performance claims
10. run `zig build test --summary all`

## Minimum checks
- README links to `docs/courseware/m23-teaching-distribution.md`
- package index links to onboarding, instructor guide, assignment pack, and reproducibility checklist
- onboarding includes `zig build`, `zig build test --summary all`, and first-run simulator commands
- assignment pack lists committed scenario paths and exact commands for all three modules
- assignment pack does not require M19, M20, or M22 paths to complete the core package
- reproducibility checklist references only committed inputs and supported commands
- scenario-pack/doc alignment tests still prove the M21 shortlist is exact
- boundary tests fail if M23 docs drift into forbidden scope claims
- CLI smoke covers every command shown in M23 package docs

## Non-goals for this milestone
- semester-scale curriculum breadth
- second or third assignment packs
- public solution-key sprawl
- autograding or hosted teaching infrastructure
- browser/WASM delivery
- production-service or live-observability workflows
- M22 API expansion
