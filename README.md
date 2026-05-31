# zig-scheduler

`zig-scheduler` is a deterministic CPU scheduling simulator in Zig. It is built for teaching, experimentation, and reviewable comparisons between policies — not as a kernel scheduler, daemon, or production automation system. The repo is still simulator-first: the **simulator-first teaching path** lives in `docs/labs/simulator-teaching-pack.md`, the Linux-facing path stays limited to **offline, observability-only, version-pinned snapshot fixtures** — **not live capture,** tooling automation, replay, or **Linux-performance claims** — the narrow embedder facade is documented in `docs/library-sdk.md`, the research sandbox is documented in `docs/research-sandbox.md`, and the planning/governance artifacts now live under `docs/roadmap/`.

## Build

```sh
zig build
zig build test --summary all
zig build reports -- --check
```

## Run

Main interface:

```sh
zig build run
# or
zig-out/bin/zig-scheduler
```

Core simulator path:

```sh
zig build sim -- --scenario-file scenarios/basic/short-vs-long.zon --policy fcfs
zig build run -- --scenario-file scenarios/basic/short-vs-long.zon --policy fcfs

zig build sim -- --scenario-file scenarios/basic/sleep-wakeup.zon --policy cfs-like
zig build run -- --scenario-file scenarios/basic/sleep-wakeup.zon --policy cfs-like

zig build sim -- --scenario-file scenarios/basic/multicore-balancing.zon --policy fcfs
zig build run -- --scenario-file scenarios/basic/multicore-balancing.zon --policy fcfs
```

Snapshots, observability, and SDK smoke:

```sh
zig-out/bin/zig-scheduler --input docs/examples/exports/multicore-contention-fcfs.report.json --snapshot
zig build sim -- --scenario-file scenarios/basic/multicore-contention.zon --policy fcfs --format json | zig-out/bin/zig-scheduler --stdin --snapshot

zig-out/bin/zig-scheduler --observability
zig-out/bin/zig-scheduler --snapshot --comparison

zig build embed-smoke
zig build analyze -- --input docs/examples/exports/multicore-contention-fcfs.report.json
zig build bench
```


## Governance and roadmap status

The current production-grade roadmap is a **lab/product-quality roadmap**, not
permission to ship a live OS scheduler, daemon, service, agent, or automation
runtime. `docs/adr/0003-productionization-gate.md` still defers that
production branch indefinitely; a future runtime branch requires a new explicit
re-charter before any implementation starts.

Roadmap source-of-truth surfaces:

- `docs/project-architecture-and-status.md` — current repo identity, workstream
  status, and active proof surfaces
- `docs/roadmap/README.md` — information architecture for active plans, gates,
  drafts, and archived roadmap material
- `.omx/plans/prd-production-grade-scheduler-50-workstreams.md` — future
  production-grade scheduler laboratory roadmap, including later roadmap cleanup and
  governance workstreams
- `.omx/plans/test-spec-production-grade-scheduler-50-workstreams.md` —
  verification expectations for that roadmap

## Theory

The simulator advances in deterministic discrete ticks: tasks arrive, become runnable, may block and wake, get chosen by a policy, execute, and emit trace and metric updates. The point is to make scheduling behavior explainable and comparable on committed workloads, not to claim Linux kernel fidelity, replay authority, or Linux-performance meaning.

## Architecture

- **Scenario/model layer** — object-style ZON inputs, committed scenario packs, and result/value types
- **Engine layer** — deterministic execution, multicore behavior, blocking/wakeup, groups, and topology
- **Policy layer** — supported policies plus a clearly unstable experimental sandbox under `src/policies/experimental/`
- **Report/tooling layer** — versioned `zig-scheduler/report`, TUI, snapshots, analysis, benchmarks, and report pipeline
- **Observability boundary** — committed fixtures under `fixtures/linux-observability/`; this path does **not** widen `zig-scheduler/report` or `src/analysis`
- **Branch docs** — teaching pack: `docs/labs/simulator-teaching-pack.md`; courseware package: `docs/courseware/teaching-distribution.md`; SDK boundary: `docs/library-sdk.md`; sandbox governance: `docs/research-sandbox.md`; roadmap/gates: `docs/roadmap/`
