# Release checklist

This checklist is the M45 dry-run gate for simulator-lab/product-quality
releases. It preserves ADR 0003: no daemon, service, agent, production runtime,
or live automation is released from this branch unless a later approved ADR
explicitly re-charters that work.

## Required commands

1. `zig fmt --check build.zig build.zig.zon $(find src -name '*.zig' -print)`
2. `git diff --check`
3. `zig build test --summary all`
4. `zig build quality`
5. `zig build perf`
6. `zig build bench -- --format markdown`
7. `zig build reports -- --check`

## Required review notes

- Version bump or explicit no-version-change rationale.
- Changelog summary grouped by simulator, CLI/SDK, dashboard, docs, and tests.
- Contract migration notes for scenario input, report JSON, SDK exports, policy
  extension metadata, and dashboard snapshots.
- Benchmark baseline/budget status with any approved refresh called out.
- Performance gate output from `zig build perf`.
- Quality dashboard excerpt or path to generated output.
- Known limits that reaffirm this is a deterministic scheduler simulator and
  teaching laboratory, not a kernel scheduler or production automation runtime.

## Release blockers

- Any contradiction of `docs/adr/0003-productionization-gate.md`.
- Any unreviewed golden fixture, benchmark baseline, or dashboard snapshot diff.
- Any CLI/SDK behavior change without matching docs and compatibility tests.
- Any new ad hoc TUI mode that bypasses the unified dashboard plan.
