# M17 canonical scenario corpus

M17 turns the existing fixture set into an explicit curriculum-grade corpus for
teaching demos and automated regression use.

## Manual demos

Use the simulator CLI for deterministic walkthroughs:

```sh
zig build sim -- --scenario-file scenarios/basic/short-vs-long.zon --policy fcfs
zig build sim -- --scenario-file scenarios/basic/starvation-pressure.zon --policy cfs-like --format json
zig build sim -- --scenario-file scenarios/basic/topology-domains.zon --policy fcfs --format json
```

Use the TUI-first binary for interactive inspection:

```sh
zig build run -- --scenario-file scenarios/basic/multicore-balancing.zon --policy fcfs
zig build run -- --scenario-file scenarios/basic/multi-phase-io.zon --policy round_robin
```

## M21 simulator-first teaching shortlist

The current simulator-first “start here” path is intentionally smaller than the
full canonical corpus:

- `short-vs-long` + `fcfs`
- `sleep-wakeup` + `cfs-like`
- `multicore-balancing` + `fcfs`

Use the canonical teaching index for commands, snapshot suggestions, and
review notes:

- `docs/labs/simulator-teaching-pack.md`

## Canonical scenarios

| scenario | theme | recommended policy | explanation doc | role |
| --- | --- | --- | --- | --- |
| `short-vs-long` | convoy | `fcfs` + compare with `round_robin` | `docs/phase1-scenario-c-walkthrough.md` | manual demos + automated regression |
| `sleep-wakeup` | blocked/wakeup burstiness | `cfs-like` | `docs/phase1-simulator.md` | manual demos + automated regression |
| `multi-phase-io` | phased bursty I/O | `round_robin` | `docs/phase1-simulator.md` | manual demos + automated regression |
| `starvation-pressure` | starvation pressure | `cfs-like` | `docs/m8-fairness-probes.md` | manual demos + automated regression |
| `deadline-priority` | deadline comparison | `deadline` | `docs/m10-deadline-policy.md` | manual demos + automated regression |
| `group-fairness` | group fairness | `cfs-like` | `docs/m11-group-scheduling.md` | manual demos + automated regression |
| `multicore-balancing` | balancing | `fcfs` | `docs/m17-scenario-corpus.md` | manual demos + automated regression |
| `topology-domains` | topology | `fcfs` | `docs/m12-topology-simulation.md` | manual demos + automated regression |
| `latency-probe` | fairness/latency spread | `round_robin` | `docs/m8-fairness-probes.md` | manual demos + automated regression |

## Why these scenarios are canonical

- They cover the main teaching milestones without leaving the simulator-local
  scope.
- They are deterministic and committed, so they can be used in automated
  regression checks.
- They expose recognizable scheduling stories: convoy effects, bursty I/O,
  starvation pressure, balancing, topology, deadline pressure, and group
  fairness.

## Corpus rules

- Keep scenario wording simulator-local and evidence-based.
- Prefer committed fixtures over ad hoc one-off examples.
- Treat canonical scenarios as stable teaching surfaces: update docs, metadata,
  and regression checks together.
- Optional regression-pack fixtures remain separate from this core corpus.

## Balancing note

`multicore-balancing` is intentionally small: one idle core becomes available
while queued work remains elsewhere, so the trace exposes deterministic
rebalance behavior without claiming Linux scheduler-domain fidelity.
