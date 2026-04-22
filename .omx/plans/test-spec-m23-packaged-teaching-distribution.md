# Test Spec — M23 packaged teaching distribution and courseware

## Status
Draft for consensus review on 2026-04-22

## Scope under test
- one bounded repo-native package shell built on the M21 shortlist
- exactly four primary docs total
- student onboarding from checkout to first simulator runs
- instructor guidance for the same bounded package
- one reproducible three-module assignment pack
- explicit preservation of simulator-first identity and bounded M19/M20 + M22 appendix sections embedded inside named primary docs

## Approved future proof surfaces
- `README.md`
- `docs/project-architecture-and-status.md`
- `docs/labs/simulator-teaching-pack.md`
- `docs/courseware/m23-teaching-distribution.md`
- `docs/courseware/student-onboarding.md`
- `docs/courseware/instructor-guide.md`
- `docs/courseware/assignment-pack-01.md`
- `src/tests/scenario_pack_test.zig`
- `src/tests/cli_smoke_test.zig`
- `src/tests/identity_gate_test.zig`

## Required verification
1. confirm `README.md` exposes exactly one canonical M23 package entrypoint
2. confirm other docs may reference M23 only by pointing back to `docs/courseware/m23-teaching-distribution.md`
3. confirm the package entrypoint links onward to onboarding, instructor guide, and assignment pack without competing package starts
4. confirm the M23 required anchors derive exactly from `listM21TeachingEntries()`
5. confirm M23 does not widen the required anchor set or replace the primary M21 commands
6. confirm the assignment pack contains exactly three required modules:
   - `short-vs-long` + `fcfs`
   - `sleep-wakeup` + `cfs-like`
   - `multicore-balancing` + `fcfs`
7. confirm each required module uses the current M21 command pairs already present in `README.md` and `docs/labs/simulator-teaching-pack.md`:
   - `zig build sim -- --scenario-file ... --policy ...`
   - `zig build run -- --scenario-file ... --policy ...`
8. confirm every required-core package command is covered by smoke validation
9. confirm M19/M20 references are appendix-only, housed in the package index, and explicitly bounded to offline observability
10. confirm M22 references are appendix-only, housed in the instructor guide, and limited to `docs/m22-library-sdk.md` plus `zig build m22-embed-smoke`
11. confirm optional appendix commands do not appear in required module steps
12. confirm docs do not imply browser/WASM, service scope, live capture, replay authority, or Linux-performance claims
13. run `zig build test --summary all`

## Minimum checks
- README links to `docs/courseware/m23-teaching-distribution.md` as the single M23 package entry
- other docs reference M23 only by pointing back to `docs/courseware/m23-teaching-distribution.md`
- package index links to onboarding, instructor guide, and assignment pack
- package index contains the package-level reproducibility checklist and the M19/M20 appendix section
- onboarding includes `zig build`, `zig build test --summary all`, and first-run simulator commands
- assignment pack lists committed scenario paths and the exact current M21 command pairs for all three modules
- instructor guide contains the M22 appendix section; assignment pack does not
- assignment pack does not require M19, M20, or M22 paths to complete the core package
- scenario-pack/doc alignment tests prove the required anchors derive from `listM21TeachingEntries()`
- boundary tests fail if M23 docs drift into forbidden scope claims
- CLI smoke covers every required-core command shown in M23 package docs
- optional appendix commands are classified separately and do not appear in required module steps

## Non-goals for this milestone
- semester-scale curriculum breadth
- second or third assignment packs
- public solution-key sprawl
- autograding or hosted teaching infrastructure
- browser/WASM delivery
- production-service or live-observability workflows
- M22 API expansion
- redefining the M21 anchor set or replacing its primary commands
- introducing standalone appendix docs beyond the four primary docs
