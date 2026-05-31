# Assignment pack 01

This assignment pack contains exactly three required modules derived from the
teaching shortlist. It does not widen the required scenario set.

For package context, start from:
- `docs/courseware/teaching-distribution.md`

## Module 1 — Convoy and baseline output reading

Scenario file:
- `scenarios/basic/short-vs-long.zon`

Required commands:

```sh
zig build sim -- --scenario-file scenarios/basic/short-vs-long.zon --policy fcfs
zig build run -- --scenario-file scenarios/basic/short-vs-long.zon --policy fcfs
```

Prompts:
- Which task completes first, and why?
- Where do you see convoy-style waiting in the output?
- Which metric most clearly captures the effect?

## Module 2 — Blocked/wakeup reasoning

Scenario file:
- `scenarios/basic/sleep-wakeup.zon`

Required commands:

```sh
zig build sim -- --scenario-file scenarios/basic/sleep-wakeup.zon --policy cfs-like
zig build run -- --scenario-file scenarios/basic/sleep-wakeup.zon --policy cfs-like
```

Prompts:
- Which events mark blocked vs wakeup behavior?
- What part of this scenario is a teaching simplification?
- How does the TUI help you inspect the sequence?

## Module 3 — Multicore balancing

Scenario file:
- `scenarios/basic/multicore-balancing.zon`

Required commands:

```sh
zig build sim -- --scenario-file scenarios/basic/multicore-balancing.zon --policy fcfs
zig build run -- --scenario-file scenarios/basic/multicore-balancing.zon --policy fcfs
```

Prompts:
- When does rebalance become visible?
- Why is this example useful for teaching multicore behavior?
- What claim should you avoid making about Linux scheduler domains?

## Reproducibility notes
- use only committed scenario files and supported commands
- do not replace the required command pairs with alternative primary commands
- optional appendix commands are not part of the required modules
