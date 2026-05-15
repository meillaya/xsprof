# M76 LTS simulator-lab release plan

This is the M76 decision package for the production-grade scheduler roadmap. It
packages an LTS simulator-lab release and does not authorize daemon, service, agent, production runtime, kernel scheduling, live capture, or host automation implementation.

## Release position

- Decision: reaffirm deferred production runtime via `docs/adr/0004-m75-lts-simulator-lab-release.md`.
- Scope: deterministic scheduler simulator, courseware/lab surface, CLI/SDK,
  report pipeline, smart dashboard spine, quality gates, performance gates, and
  semantics vocabulary.
- Boundary: ADR 0003 remains active; M75 did not re-charter production runtime.

## Required release evidence

1. `zig build quality`
2. `zig build perf`
3. `zig build dashboard`
4. `zig build semantics`
5. `zig build reports -- --check`
6. `zig fmt --check build.zig build.zig.zon $(find src -name '*.zig' -print)`
7. `git diff --check`
8. `zig build test --summary all`
9. final ai-slop-cleaner pass over changed files
10. final code-review verdict: APPROVE with architecture status CLEAR

## Release artifact index

| Artifact | Purpose |
| --- | --- |
| `docs/quality-gates.md` | M37-M46 quality gate ownership and governance |
| `docs/performance-gates.md` | M47-M56 performance budgets and reproducible gate |
| `docs/scheduler-semantics-v2.md` | M57-M66 semantics vocabulary |
| `docs/smart-dashboard-spine.md` | M67-M74 dashboard screen IA and no-ad-hoc rule |
| `docs/adr/0004-m75-lts-simulator-lab-release.md` | M75 decision to ship LTS simulator-lab rather than runtime |
| `docs/lts-simulator-lab-release-plan.md` | M76 release package checklist |

## Future runtime branch prerequisites

A future runtime branch needs all of the following before code starts:

- superseding ADR that explicitly replaces ADR 0003/0004 for that branch only;
- PRD and test spec for daemon/service/agent behavior;
- security/threat model, privilege boundaries, and operations model;
- live-observability/capture policy if any host integration is proposed;
- migration plan proving simulator-lab contracts remain stable.
