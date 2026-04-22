# Project Architecture and Status

## Purpose

`zig-scheduler` is a deterministic CPU scheduling simulator written in Zig.
It is designed as a teaching and experimentation environment, not as a
kernel component, daemon, or production scheduler.

The current project identity is fixed by
`docs/adr/0001-m5-project-identity.md`,
`docs/adr/0002-m18-linux-observability-gate.md`, and the M19 execution
boundary documented in `docs/m19-curated-linux-observability.md`:

- the **implementation today** is still a simulator-first mainline
- the **roadmap** is a broader scheduler laboratory with a simulator-only mainline
- Linux-facing, productized, and research-heavy branches remain explicitly gated
- the M19 Linux-observability surface is limited to **offline,
  observability-only, version-pinned snapshot fixtures** with a separate import
  boundary unless a later gate re-charters it

## Theory in one page

The simulator treats scheduling as a sequence of discrete ticks.
At each tick, the engine incorporates newly runnable work, asks the active
scheduling class what should run next, executes one tick of work per active
core, and records the resulting trace and metrics.

This gives the project three useful properties:

1. **Determinism** — the same scenario and policy should always produce the same trace.
2. **Explainability** — each policy decision is visible in the trace.
3. **Comparability** — policies can be compared on identical workloads.

The simulator intentionally prefers explicit, reviewable approximations over
kernel fidelity. Every feature is framed as a teaching model rather than an
attempt to reproduce Linux scheduler internals exactly.

## Core simulation model

The engine is built around a small set of concepts:

- **tasks** with arrival times and CPU demand
- **optional phases** for CPU/wait alternation
- **optional deadlines** for deadline-oriented experiments
- **optional groups** for simulator-safe group fairness experiments
- **optional topology domains** for simple multicore placement distinctions
- **policies** that choose which runnable task should run next

The main execution loop is conceptually:

```text
for each tick:
  wake blocked tasks whose wake time has arrived
  enqueue arrivals for the current tick
  evaluate policy-driven preemption
  dispatch runnable tasks onto idle cores
  execute one tick per running core
  emit trace entries and update metrics
```

That loop is kept in `src/sim/engine.zig`, while policy-specific choices are
routed through `src/policies/class.zig`.

## Architecture overview

### 1. Scenario layer

The scenario system owns the public input contract.
It accepts:

- curated built-ins via `--scenario <name>`
- arbitrary `.zon` fixtures via `--scenario-file <path>`

The canonical format is object-style ZON.
Legacy line-oriented `.zon` input still exists as a compatibility path.

Primary files:

```text
src/sim/scenario.zig
src/sim/types.zig
scenarios/basic/
scenarios/regressions/
```

### 2. Engine layer

The engine owns common simulator behavior:

- arrivals and wakeups
- ready/running/blocked transitions
- multicore execution
- topology-aware placement and stealing
- trace creation
- per-task and aggregate metric computation

Primary files:

```text
src/sim/engine.zig
src/sim/metrics.zig
src/sim/trace.zig
src/sim/types.zig
```

### 3. Scheduling-class boundary

The engine does not import concrete policy modules directly.
Instead, policy behavior is routed through a scheduling-class boundary.

That boundary currently supports:

- FCFS
- Round Robin
- CFS-inspired
- deadline-inspired

Primary files:

```text
src/policies/class.zig
src/policies/fcfs.zig
src/policies/round_robin.zig
src/policies/cfs_like.zig
src/policies/deadline.zig
```

This keeps policy growth reviewable and prevents the engine core from turning
into a large policy switchboard.

### 4. Reporting/export layer

The simulator emits a stable versioned JSON export contract:

```json
{
  "schema": "zig-scheduler/report",
  "version": 1
}
```

That export includes source metadata, policy information, topology/group data,
trace events, per-task metrics, and aggregate metrics.

Primary files:

```text
src/contract/report.zig
src/cli/report.zig
src/cli/output.zig
```

### 5. Downstream analysis/benchmark layer

Downstream tooling is intentionally built on exported data instead of engine
internals where practical.

Current downstream surfaces include:

- Markdown analysis reports
- SVG visualizations
- reproducible benchmark baselines

Primary files:

```text
src/analysis/
src/bench/
docs/examples/
docs/benchmarks/
```

### 6. Property/generator layer

The property layer creates valid deterministic scenarios, materializes them
through the same parser used by normal fixtures, checks invariants, and shrinks
failing cases into reproducible regression artifacts.

Primary files:

```text
src/testing/property.zig
src/tests/property_test.zig
scenarios/regressions/
```

## Repository structure

```text
src/
  sim/        # scenario types, engine, metrics, trace, packs
  policies/   # scheduling classes and concrete policy logic
  cli/        # argument parsing and output surfaces
  analysis/   # export-driven reporting and visualization
  bench/      # reproducible benchmark harness
  testing/    # generator/shrinker/property helpers
  tests/      # regression, contract, and behavior tests

scenarios/
  basic/      # curated teaching fixtures
  regressions/# minimized failure-preserving fixtures

docs/
  adr/        # architecture decisions
  benchmarks/ # reproducible benchmark outputs
  *.md        # milestone-specific docs and deep dives

fixtures/
  linux-observability/ # offline M19 fixtures, manifests, and support matrix
```

## Implementation details achieved so far

### M1.5 — CLI / scenario I/O / report-export polish

The project established a stable CLI surface, public scenario-file loading,
and a versioned JSON export contract.

### M2 / M2.5 — fairness semantics and export hardening

Weighted fairness semantics were added for the CFS-inspired path, and the trace
and export contract were frozen tightly enough for downstream consumers.

### M3 / M3.5 — multicore simulation and stronger fixtures

The simulator moved from single-core to deterministic multicore behavior.
Fixture coverage was expanded to include balancing, simultaneous completions,
and multicore RR pressure.

### M4 / M4.5 — analysis and benchmark surfaces

The repo added export-driven analysis and reproducible benchmark baselines.
These surfaces are deterministic and committed as artifacts.

### M5 — identity gate

An ADR was landed to lock the repo’s current simulator-only truth while keeping
the broader roadmap explicit and gated.

### M6 / M7 — blocked transitions and multi-phase workloads

The simulator now models:

- deterministic blocked/wakeup behavior
- alternating CPU/wait phases
- backward-compatible single-sleep shorthand

### M8 — fairness probes

Fairness and latency probe fixtures were added, along with probe-style metrics
such as:

- `max_waiting_time`
- `max_response_time`
- `response_time_spread`

### M9 — scheduling-class architecture

Policy logic was isolated behind an explicit scheduling-class boundary so new
families can be added without re-tangling the engine.

### M10 — deadline-inspired policy

A deterministic deadline-oriented teaching policy was added, with optional
per-task `deadline_tick` inputs and reproducible cross-policy comparisons.

### M11 — group scheduling model

The simulator now supports group membership plus group weights/quota-like caps.
The current group behavior is intentionally narrow and framed as a teaching
analogy, not as Linux cgroup fidelity.

### M12 — topology-aware simulation

The multicore model now supports declared topology domains and domain-aware
placement/stealing rules. Traces expose `domain_id` alongside `core_id`.

### M13 — generator, shrinker, and property-style testing

The repo now contains a deterministic generator/shrinker/property harness plus
regression fixture save-path guidance under `scenarios/regressions/`.

### M14 — scenario-pack convention and extension boundary

The project now documents and tests a stable extension boundary:

- built-in scenario registry remains explicit and reviewable
- extra scenario packs are just canonical `.zon` trees loaded by path
- policy extension remains routed through the scheduling-class boundary
- core behavior stays operable without optional extras

### M15 — interactive TUI trace explorer

The repo now includes a local interactive trace explorer plus explicit
snapshot rendering. The default `zig-scheduler` entrypoint is TUI-first, while
the dedicated `zig-scheduler-tui` binary remains available for direct launch.

### M16 — reproducible lab notebooks / report pipeline

M16 now provides one canonical regeneration path for the committed export,
analysis, benchmark, and notebook artifacts:

```sh
zig build reports
```

### M17 — scenario corpus expansion and curriculum-grade examples

M17 adds an explicit canonical scenario corpus on top of the existing fixture
set. The core pack identifies curriculum-grade scenarios with stable metadata
(theme, explanation doc, recommended policy, demo/regression role), and the
repo documents the corpus in `docs/m17-scenario-corpus.md`.

### M18 — Linux-observability planning gate

M18 approved the narrow charter in `docs/adr/0002-m18-linux-observability-gate.md`.
The repo still treats Linux observability as a separate bounded branch rather
than a simulator-mainline feature.

### M19 — curated Linux-observability snapshots

M19 now implements the first approved offline import cut under that gate.

The TUI can now open this surface explicitly via `--m19` / `--m19-manifest`,
but it stays a separate observability-only lane rather than a widening of the
simulator report or analysis contracts.

### M20 — simulator-to-trace comparison summary

M20 now implements the approved narrow comparison cut between one committed
simulator pairing and one committed M19 fixture family, using a separate
`zig-scheduler/observability-comparison` v1 payload that remains outside the
main simulator export/report surfaces.

The TUI can now open this comparison explicitly via `--m20` / `--m20-pairing`,
while keeping picker/explorer/diff simulator-only and preserving the
observability-only, non-fidelity boundary.

## Building, running, and testing

### Build

```sh
zig build
```

### Run a built-in scenario

```sh
zig build run -- --scenario short-vs-long --policy fcfs
```

### Run a scenario file

```sh
zig build run -- --scenario-file scenarios/basic/group-fairness.zon --policy cfs-like
```

### Run JSON export

```sh
zig build sim -- --scenario-file scenarios/basic/deadline-priority.zon --policy deadline --format json
```

### Run analysis

```sh
zig build analyze -- --input docs/examples/exports/multicore-contention-fcfs.report.json
zig build analyze -- --input docs/examples/exports/multicore-contention-fcfs.report.json --format svg
```

### Run benchmarks

```sh
zig build bench
zig build bench -- --format json
```

### Regenerate the reproducible report pack

```sh
zig build reports
zig build reports -- --output-dir zig-out/m16-smoke
zig build reports -- --check
```

### Run tests

```sh
zig build test --summary all
```

## What has been achieved so far

At this point, the project has achieved:

- a stable public scenario and JSON export contract
- deterministic multicore scheduling
- analysis and benchmark surfaces built on exported artifacts
- blocked/wakeup and multi-phase workload modeling
- fairness, deadline, group, and topology teaching surfaces
- a deterministic scenario generator/shrinker/property harness
- a documented extension boundary for future packs and policy families
- a TUI-first local trace explorer with deterministic snapshot rendering
- a canonical report-regeneration path for committed teaching artifacts
- an explicit curriculum-grade scenario corpus for demos and regression use
- a bounded offline Linux-observability import branch plus a separate M20
  comparison contract

In short: the repo has moved from a minimal teaching simulator into a
well-structured scheduling laboratory with explicit scope boundaries, a
stronger local teaching surface, and a still-bounded Linux-observability side
branch.

## Current milestone status

As of 2026-04-22, the implemented milestone picture is:

- the mainline simulator branch is implemented through **M17**
- the Linux-observability branch approved by **M18** is implemented through
  **M20**
- the current proof surface is green under `zig build test --summary all` and
  `zig build reports -- --check`

### M19 — curated Linux-observability snapshots

M19 now implements the first approved offline import cut under that gate.

The implemented boundary is intentionally narrow:
- offline snapshot fixtures only
- observability-only wording only
- approved capture families only
- explicit version tuples only
- committed scrubbed fixtures + manifests only
- one literal approved tuple in `fixtures/linux-observability/support-matrix.json`
- a separate loader/summary path in `src/observability/root.zig`

The first approved family is:
- `tracefs-sched-snapshot`

Still out of scope after M19:
- live tracing in-repo
- capture tooling/automation in-repo
- `perf sched`, generic `perf.data`, `perf script`, `trace_pipe`, or non-sched tracepoints
- replay-fidelity claims
- Linux-performance or calibration claims
- widening `zig-scheduler/report` or `src/analysis`

Proof surfaces for this branch now live in:
- `docs/m19-curated-linux-observability.md`
- `fixtures/linux-observability/`
- `src/observability/root.zig`
- `src/tests/linux_observability_test.zig`

### M20 — simulator-to-trace comparison summary

M20 now implements the approved next Linux-facing cut, but it remains
intentionally narrow and separate from the simulator export/report mainline.

The implemented M20 boundary is:
- one simulator scenario + policy pairing only (`sleep-wakeup` + `cfs_like`)
- one M19 fixture manifest only
- one committed pairing manifest only
- one separate `zig-scheduler/observability-comparison` v1 contract only
- library + docs + tests proof surfaces only

M20 still must not:
- widen `zig-scheduler/report`
- widen `src/analysis/*`
- claim replay fidelity, kernel accuracy, calibration authority, or Linux-performance meaning
- add task↔PID identity matching or raw event-by-event alignment

Implemented proof/documentation surfaces for this cut are:
- `docs/m20-simulator-to-trace-comparison.md`
- `src/observability/comparison.zig`
- `src/tests/observability_comparison_test.zig`

## Next recommended milestone

### M21 — [Optional distribution branch] simulator-first teaching surface polish

The recommended next cut is to deepen the repo's local teaching/demo lane
without changing the simulator-first truth of the project.

Goal:
- make the existing CLI, TUI, snapshot, and report surfaces easier to teach,
  demo, and review from committed fixtures

Recommended scope:
- a single simulator-first shortlist for exactly these anchors:
  - `short-vs-long` + `fcfs`
  - `sleep-wakeup` + `cfs-like`
  - `multicore-balancing` + `fcfs`
- stronger walkthrough/docs coverage for those anchors
- more deterministic snapshot surfaces for the TUI path
- one repo-native teaching index at `docs/labs/simulator-teaching-pack.md`
- clearer local demo playbooks for instructors, reviewers, and contributors

This milestone should preserve the current boundaries:
- no browser/WASM path as a required or default surface
- no widening of `zig-scheduler/report` or `src/analysis/*`
- no change to the M19/M20 observability-only proof boundary
- no Linux-performance, replay-fidelity, or calibration claims
- no packaging/courseware expansion beyond repo-native docs/artifacts; that
  remains later M23-scale work

Planned proof surfaces for this route should stay close to the current repo
shape:
- `docs/m21-simulator-first-teaching-surface.md`
- `docs/labs/simulator-teaching-pack.md`
- README + project-status updates
- deterministic TUI snapshot tests for picker/help plus the three anchors

## Notes on implementation philosophy

The guiding architecture rule so far has been:

```text
keep public contracts stable,
keep engine semantics explicit,
keep policy behavior isolated,
keep downstream tooling deterministic,
and keep every claim narrower than the implementation can prove.
```

That is why the codebase prefers committed fixtures, explicit trace fields,
small milestones, and simulator-scoped wording.

## References

These are the core resources that should be used to rebuild a project like this
from scratch in an evidence-based way.

- **The Linux kernel scheduler documentation**
  - `Documentation/scheduler/` in the Linux kernel tree
  - required for correct scope framing, terminology, and explicit omission lists
- **CFS design/material by Ingo Molnár and related kernel docs**
  - required to understand vruntime-style fairness and what this repo simplifies
- **Linux `sched(7)` manual page**
  - required for baseline policy terminology and non-overclaiming around Linux classes
- **Linux cgroups / CPU controller documentation**
  - required before implementing deeper group scheduling analogies beyond the current simulator-safe model
- **Linux SCHED_DEADLINE / EDF-related kernel documentation and papers**
  - required before any stronger real-time claims or more faithful deadline semantics
- **NUMA and scheduler-domain documentation in the Linux kernel tree**
  - required before deepening topology costs, migration heuristics, or locality claims
- **Queueing/scheduling textbooks or lecture notes covering FCFS, RR, EDF, weighted fair scheduling, starvation, and latency tradeoffs**
  - required for the teaching theory behind the simulator’s milestone progression
- **Zig language and standard library references**
  - required for implementing deterministic parsers, data models, tests, and CLI/report surfaces in Zig
- **Property-based testing literature**
  - e.g. QuickCheck-style generator/shrinker design references
  - required for designing useful generators, shrinkers, and invariant suites
- **TUI design/accessibility references**
  - required for M15 and the recommended M21 teaching-surface polish work

When extending the repo, prefer official docs, seminal scheduler papers, and
the repo’s own committed fixtures/contracts before adding new abstractions.
