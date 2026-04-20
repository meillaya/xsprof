# Phase 1 Linux Scheduler Mapping

This repository's Phase 1 deliverable is a **user-space, in-process CPU scheduling simulator** written in Zig.
It is intentionally designed to teach Linux scheduler ideas **without** pretending to be the Linux kernel scheduler.

## Scope boundary

Phase 1 must remain:
- simulator only
- user-space only
- single-process/in-process only
- deterministic and testable

Phase 1 must **not** include:
- real process execution
- kernel integration
- eBPF hooks or scheduler hooks
- daemon/service/cron behavior
- SMP or multi-core scheduling

## Simulator concept to Linux concept mapping

| Simulator concept | Phase 1 meaning | Linux concept it helps teach | Important simplification |
| --- | --- | --- | --- |
| Task | A simulated schedulable workload with arrival tick and CPU burst ticks | schedulable entity (`task_struct`-like mental model) | Not a real process or thread |
| Arrival tick | When a task becomes runnable in the simulation | wakeup/enqueue into a runnable set | No interrupts, blocking I/O, or wakeup races |
| Burst ticks | CPU demand required to complete a task | CPU time demand / runtime | No syscalls, sleeps, or mixed CPU/I/O behavior |
| Ready queue / runnable set | Tasks eligible to run | run queue / runnable tasks | Single-core only; no per-CPU run queues |
| Dispatch | Selecting the next runnable task | scheduler pick-next decision | No context-switch overhead modeling |
| Tick execution | One unit of CPU progress | time accounting / runtime accumulation | Fixed discrete ticks, not kernel timing precision |
| Quantum | Time slice before Round Robin preemption | RR time slice / periodic preemption | Simplified fixed quantum |
| Preemption | Current task loses CPU before completion | scheduler preemption | No interrupt latency or kernel preemption model |
| Completion | Task finishes all required burst ticks | task exhausts CPU demand | No exit, cleanup, signals, or wait semantics |
| Trace entries | Ordered scheduler events | tracepoints / scheduling timeline | Educational event model, not kernel trace fidelity |
| Response time | First dispatch minus arrival | initial scheduling latency | Ignores wakeup and migration overhead |
| Waiting time spread | Fairness visibility across tasks | fairness/latency skew intuition | Crude educational proxy, not a Linux scheduler KPI |

## Policy mapping

### FCFS / FIFO baseline

Use FCFS as a baseline for reasoning about queue order and convoy effects.

Linux relevance:
- teaches what happens when runnable order dominates scheduling decisions
- gives a simple contrast against more time-sliced or fairness-oriented policies

Important caveat:
- this is **not** Linux's normal scheduler behavior
- Phase 1 should describe it as a baseline comparison policy, not as a Linux-faithful default

### Round Robin

Use Round Robin to show time slicing and latency/fairness tradeoffs.

Linux relevance:
- resembles the high-level intuition of time-sliced scheduling
- helps explain why short tasks can finish sooner when long tasks are periodically preempted

Important caveat:
- Phase 1 Round Robin is a teaching model, not a full Linux real-time scheduler implementation
- no priorities, runtime throttling, class interactions, or kernel latency effects are modeled

### Simplified CFS-inspired policy

Use the CFS-inspired policy to teach the idea of fairness via accumulated virtual runtime style accounting.

Required positioning:
- describe this policy as **CFS-inspired** or **simplified CFS-like**
- do **not** describe it as faithful Linux CFS

Linux relevance:
- lowest-vruntime selection approximates the core mental model behind fair scheduling
- demonstrates why fairness accounting changes completion order relative to FCFS

Required omissions to document explicitly:
- no nice weights
- no sleeper bonus heuristics
- no SMP balancing
- no per-CPU run queues
- no cgroups or group scheduling
- no scheduler classes beyond current scope
- no kernel timing precision or interrupt behavior

## Deterministic simulation semantics that docs must preserve

The educational value depends on stable rules. Documentation and tests should agree on these points:

1. For tick `t`, arrivals are incorporated before dispatch for tick `t`.
2. Ties fall back to stable scenario input declaration order.
3. If Round Robin quantum expiry and completion coincide on the same tick, completion wins.
4. Idle ticks are explicit in the engine and raw trace.
5. Raw trace event kinds should include at least:
   - `arrival`
   - `dispatch`
   - `tick`
   - `preempt`
   - `complete`
   - `idle`

## Why Scenario C matters

Scenario C from the test spec is the clearest teaching example:
- `L`: arrival `0`, burst `8`
- `S1`: arrival `1`, burst `2`
- `S2`: arrival `2`, burst `1`
- Round Robin quantum: `2`

This scenario should be used in docs to explain:
- FCFS convoy effects
- Round Robin latency improvements for short jobs
- how CFS-inspired accounting changes the ordering pressure without claiming kernel fidelity

## Documentation wording guardrails

Preferred wording:
- "Linux-inspired"
- "CFS-inspired"
- "simplified CFS-like"
- "user-space simulator"
- "educational model"

Avoid wording that overclaims fidelity:
- "implements Linux CFS"
- "real Linux scheduler"
- "kernel-faithful"
- "process scheduler for Linux"

## Review checklist for future implementation PRs

Before merging implementation work, confirm the docs and code still agree that:
- Phase 1 simulates tasks rather than launching processes
- policy names do not overclaim Linux fidelity
- deterministic rules are encoded in tests, not implied informally
- omitted Linux concerns are listed explicitly
- output and docs explain both latency and fairness tradeoffs
