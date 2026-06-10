# SIMULATOR PACKAGE GUIDANCE

This subtree is the archived deterministic CPU scheduling simulator/lab. It preserves repeatable scenario runs, policy comparison, teaching/research workflows, offline observability fixtures, simulator TUI snapshots, report generation, quality/perf dashboards, and SDK examples.

## Commands
```bash
zig build test --summary all
zig build quality
zig build reports -- --check
zig build embed-smoke
zig build sim -- list
zig build sim -- --scenario short-vs-long --policy fcfs --format json
zig build tui -- --snapshot --scenario short-vs-long --policy fcfs --width 100 --height 30
zig fmt --check build.zig build.zig.zon $(find src -name '*.zig' -print)
git diff --check
```

## Boundaries
- Keep simulator behavior deterministic.
- Do not make simulator benchmarks or offline fixtures claim Linux scheduler fidelity.
- Preserve simulator CLI/SDK/report schema compatibility unless intentionally versioned.
- Keep child guidance under `src/sim/`, `src/tests/`, and `src/tui/` authoritative for those subtrees.
