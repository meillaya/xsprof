# Project Architecture and Status

## Purpose

`zig-scheduler` is a deterministic CPU scheduling simulator written in Zig.
It is designed as a teaching and experimentation environment, not as a
kernel component, daemon, or production scheduler.

The current project identity is fixed by
`docs/adr/0001-m5-project-identity.md`,
`docs/adr/0002-m18-linux-observability-gate.md`, and the M19 execution
boundary documented in `docs/m19-curated-linux-observability.md`:

- the **main simulator path** remains deterministic and simulator-first
- the **roadmap** is a broader scheduler laboratory with a simulator-first mainline
- Linux-facing, productized, and research-heavy branches remain explicitly gated
- the M19 Linux-observability lane is limited to **offline,
  observability-only, version-pinned snapshot fixtures** ending at a bounded
  observability summary, unless a later gate re-charters it

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

In short: the repo has moved from a minimal teaching simulator into a
well-structured scheduling laboratory with explicit scope boundaries.

## Next major milestones

### M15 — interactive TUI trace explorer

Add a local interactive trace explorer that can inspect representative runs
without replacing the export/report path.

### M16 — reproducible lab notebooks / report pipeline

M16 adds one canonical regeneration path for the curated report pack:

```sh
zig build reports
```

That command regenerates:

- `docs/examples/exports/multicore-contention-fcfs.report.json`
- `docs/examples/analysis/multicore-contention-fcfs.md`
- `docs/examples/analysis/multicore-contention-fcfs.svg`
- `docs/benchmarks/m45-baselines.md`
- `docs/benchmarks/m45-baselines.json`
- `docs/labs/reproducible-report-pack.md`

The intent is to keep teaching/research artifacts reproducible from committed
fixtures with one repo-native path, while preserving the simulator-local
wording and deterministic contract checks established by earlier milestones.

### M17 — scenario corpus expansion and curriculum-grade examples

M17 adds an explicit canonical scenario corpus on top of the existing fixture
set. The core pack now identifies curriculum-grade scenarios with stable
metadata (theme, explanation doc, recommended policy, demo/regression role),
and the repo documents the corpus in `docs/m17-scenario-corpus.md`.

The canonical scenarios cover:

- convoy effects (`short-vs-long`)
- bursty blocked/wakeup and phased I/O (`sleep-wakeup`, `multi-phase-io`)
- starvation pressure (`starvation-pressure`)
- deterministic multicore rebalancing (`multicore-balancing`)
- topology-aware placement (`topology-domains`)
- plus deadline, group-fairness, and latency/fairness comparison examples

The intent is to make the scenario corpus usable both as a teaching/demo lane
and as a stable automated regression surface.

### M18 — Linux-observability planning gate

M18 is now approved in `docs/adr/0002-m18-linux-observability-gate.md`.

The approved outcome is intentionally narrow:
- offline snapshot fixtures only
- observability-only wording only
- approved capture families only
- explicit version tuples only
- committed scrubbed fixtures + manifests only

Still out of scope after M18:
- live tracing in-repo
- capture tooling/automation in-repo
- replay-fidelity claims
- Linux-performance or calibration claims

M19 now executes only inside the milestone-specific PRD/test-spec boundary
summarized in `docs/m19-curated-linux-observability.md`.

### M19 — curated Linux-observability snapshots

M19 is the first implementation cut inside the optional Linux-observability
branch. Its contract is intentionally narrower than the simulator/report
mainline:

- admit only committed scrubbed fixtures under `fixtures/linux-observability/`
- admit only the `tracefs-sched-snapshot` capture family in the initial cut
- pin loading to one approved literal tuple and fail closed on anything else
- stop at manifest validation plus an observability-only normalized summary
- keep imported Linux fixtures separate from `scenarios/` and simulator-native
  regression assets

The initial approved tuple is fixed to:

- `family = tracefs-sched-snapshot`
- `kernel_release = linux-6.6`
- `tool_version = tracefs-kernel-6.6`
- `tracefs_root = /sys/kernel/tracing`
- `capture_recipe = instance=m19-snapshot; events=sched_switch,sched_wakeup,sched_wakeup_new,sched_process_fork,sched_process_exit; snapshot=1`
- `trace_clock = global`
- `enabled_sched_events = sched_switch,sched_wakeup,sched_wakeup_new,sched_process_fork,sched_process_exit`
- `scope = system-wide dedicated instance`
- `mode = snapshot`
- `time_window = single bounded snapshot`
- `snapshot_format_version = tracefs-sched-text-v1`
- `scrub_policy_version = linux-observability-scrub-v1`

Still out of scope in M19:

- live tracing or capture tooling in the repo
- `perf sched`, generic `perf.data`, `perf script`, `trace_pipe`, or non-sched tracepoint families
- replay-fidelity, calibration, or Linux-performance claims
- widening the existing `zig-scheduler/report` contract or `src/analysis` surfaces

The documentation/proof surfaces for this boundary are:

- `docs/adr/0002-m18-linux-observability-gate.md`
- `docs/m19-curated-linux-observability.md`
- `README.md`
- this project status document

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
  - required for M15 and later interactive teaching surfaces

When extending the repo, prefer official docs, seminal scheduler papers, and
the repo’s own committed fixtures/contracts before adding new abstractions.
