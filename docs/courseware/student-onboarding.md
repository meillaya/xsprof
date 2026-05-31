# Student onboarding

This guide gets a learner from repo checkout to the first bounded teaching run.

For package context, start from:
- `docs/courseware/teaching-distribution.md`

## 1. Validate the local repo state

```sh
zig build
zig build test --summary all
```

## 2. First simulator run: convoy contrast

```sh
zig build sim -- --scenario-file scenarios/basic/short-vs-long.zon --policy fcfs
zig build run -- --scenario-file scenarios/basic/short-vs-long.zon --policy fcfs
```

## 3. Continue through the required modules

Second module:

```sh
zig build sim -- --scenario-file scenarios/basic/sleep-wakeup.zon --policy cfs-like
zig build run -- --scenario-file scenarios/basic/sleep-wakeup.zon --policy cfs-like
```

Third module:

```sh
zig build sim -- --scenario-file scenarios/basic/multicore-balancing.zon --policy fcfs
zig build run -- --scenario-file scenarios/basic/multicore-balancing.zon --policy fcfs
```

## What to keep in mind
- the simulator is a teaching model, not a Linux kernel implementation
- the required path uses only the three teaching anchor scenarios
- optional appendices are not needed to complete the core package

## Where to go next
- assignment work: `docs/courseware/assignment-pack-01.md`
- package overview: `docs/courseware/teaching-distribution.md`
