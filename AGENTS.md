# PROJECT KNOWLEDGE BASE

**Generated:** 2026-06-10T23:16:00-04:00
**Branch:** master

## OVERVIEW
`zig-scheduler` root is now the fail-closed Linux scheduler operator surface. The deterministic simulator/lab was archived under `simulator/` and must be run from that package root.

## ROOT SCOPE
- Root code is Linux-scheduler-facing preflight, dry-run planning, and lab-gated `sched_ext` readiness work.
- Root must not claim production readiness.
- Root must not load BPF programs or mutate cgroups, cpusets, affinities, priorities, or scheduler state in the initial implementation.
- Root UI surfaces have been removed by request; do not restore TUI/WebView code without explicit new scope.

## STRUCTURE
```text
./
├── build.zig                    # root Linux scheduler build/test/run graph
├── src/main.zig                 # fail-closed root CLI
├── src/preflight_main.zig       # read-only preflight entrypoint
├── src/controller/              # dry-run-only control-plan contracts
├── src/sched_ext/               # sched_ext fact/readiness helpers; no load path
├── src/observability/           # read-only host fact collection
├── qa/                          # external restructuring acceptance checks
├── tools/                       # root QA helpers
└── simulator/                   # archived deterministic simulator package
```


## GOVERNANCE SOURCES
- `AGENTS.md` is the root operator guidance for future agents.
- `WORKLOG.md` records historical checkpoints, current posture, and future-agent operating notes.
- `docs/` contains tracked policy, runbook, release, and security sources consumed by governance gates.
- Do not rely on ignored local `.omo/` or `.omx/` files for repository behavior or future-agent instructions.

## COMMANDS
```bash
zig build test --summary all
zig build linux-preflight -- --json
zig build run -- --help
zig fmt --check build.zig build.zig.zon $(find src -name '*.zig' -print)
git diff --check
```

Simulator commands must be run from `simulator/`.

## SAFETY RULES
- Read-only file opens for host preflight are allowed.
- Writes to `/sys`, `/proc`, cgroups, scheduler APIs, or BPF syscalls are forbidden unless a later explicit user approval changes scope.
- Any future mutation-capable feature requires lab tuple evidence, rollback drill, audit id, security review, and explicit approval.
- Unsafe verbs (`load`, `attach`, `enable`, `mutate`, `apply`) must refuse with non-zero exit.

## UI RULES
- No root TUI/WebView surface exists after the removal milestone.
- Do not reintroduce root UI code, build steps, fixtures, or package artifacts without explicit user direction.
