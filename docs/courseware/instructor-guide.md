# Instructor guide

Use this guide to deliver the first packaged teaching cut consistently.

Canonical package entrypoint:
- `docs/courseware/teaching-distribution.md`

## Suggested pacing
- Module 1: `short-vs-long` + `fcfs`
  - emphasize convoy effects and waiting-time interpretation
- Module 2: `sleep-wakeup` + `cfs-like`
  - emphasize blocked/wakeup reasoning and simulator-safe wording
- Module 3: `multicore-balancing` + `fcfs`
  - emphasize deterministic rebalance and bounded multicore claims

## Expected takeaways
- students should be able to connect traces and metrics to scheduling stories
- students should understand where the repo is intentionally simplified
- students should distinguish simulator reasoning from Linux-fidelity claims

## What not to claim
- no replay fidelity
- no Linux-performance interpretation
- no live observability capture in the package flow
- no requirement to use the SDK or observability branches in the core package

## Appendix — optional SDK embedder extension
This appendix is optional and must not be required to complete the package.

Optional references:
- `docs/library-sdk.md`

Optional command:

```sh
zig build embed-smoke
```

Use it only for advanced readers who want to see the bounded library facade.
