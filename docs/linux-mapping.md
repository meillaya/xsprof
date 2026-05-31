# Linux Mapping Notes

This repository's simulator baseline deliverable is a **user-space, in-process CPU scheduling simulator** written in Zig.
It is designed to teach Linux scheduler ideas **without** claiming to be the Linux kernel scheduler.

## Scope boundary

simulator baseline remains:
- simulator only
- user-space only
- single-process and in-process only
- deterministic and testable

Current repo scope does **not** include:
- real process execution
- kernel integration
- eBPF hooks or scheduler hooks
- daemon, service, or cron behavior
- faithful Linux SMP scheduling

## Simulator concept to Linux concept mapping

| Simulator concept | simulator baseline meaning | Linux concept it helps teach | Important simplification |
| --- | --- | --- | --- |
| Task | Simulated schedulable workload with arrival tick and CPU burst ticks | schedulable entity / `task_struct`-like mental model | Not a real process or thread |
| Arrival tick | When a task becomes runnable in the simulation | initial enqueue into a runnable set | No interrupts or wakeup races |
| Burst ticks | CPU demand required to complete a task | CPU time demand / runtime | No syscalls or real execution |
| Deterministic sleep/wakeup | Optional single blocked interval declared in the scenario | simplified sleep / wakeup mental model | No wait queues, interrupts, I/O completion, or Linux wakeup fidelity |
| Multi-phase workload | Alternating `cpu` / `wait` segments within one task | simplified CPU burst plus I/O wait intuition | No syscalls, devices, async completion, or Linux task-state fidelity |
| Ready queue / runnable set | Tasks eligible to run | run queue / runnable tasks | Simplified per-core run queues, not Linux runqueue fidelity |
| Dispatch | Selecting the next runnable task | scheduler pick-next decision | No context-switch overhead modeling |
| Tick execution | One unit of CPU progress | time accounting / runtime accumulation | Fixed discrete ticks, not kernel timing precision |
| Quantum | Time slice before Round Robin preemption | RR time slice / periodic preemption | Simplified fixed quantum |
| Preemption | Current task loses CPU before completion | scheduler preemption | No interrupt latency or kernel preemption model |
| Completion | Task finishes all required burst ticks | task exhausts CPU demand | No exit, cleanup, signals, or wait semantics |
| Trace entries | Ordered scheduler events | tracepoints / scheduling timeline | Educational event model, not kernel trace fidelity |
| Response time | First dispatch minus arrival | initial scheduling latency | Ignores wakeup and migration overhead after the first dispatch |
| Blocked time | Ticks spent in the deterministic blocked state | blocked / sleeping time intuition | Educational accounting only, not a Linux KPI |
| Waiting-time spread | Fairness visibility across tasks | fairness/latency skew intuition | Educational proxy, not a Linux scheduler KPI |
| Max waiting / response probe metrics | Worst-case latency pressure in a deterministic scenario | starvation/latency discussion aid | Probe-only metrics, not Linux scheduler guarantees |

## Policy mapping

### FCFS / FIFO baseline

FCFS is a baseline for observing convoy effects and response-time tradeoffs.

Linux relevance:
- teaches what happens when runnable order dominates scheduling decisions
- gives a simple contrast against more time-sliced or fairness-oriented policies

Important caveat:
- this is **not** Linux's normal scheduler behavior
- describe it as a baseline comparison policy, not a Linux-faithful default

### Round Robin

Round Robin models time-sliced fairness and latency tradeoffs in a simplified user-space form.

Linux relevance:
- captures the high-level intuition of time slicing
- helps explain why preemption and runnable-peer awareness matter

Important caveat:
- this is a teaching model, not a full Linux real-time scheduler implementation
- no priorities, runtime throttling, class interactions, or kernel latency effects are modeled

### Simplified CFS-inspired policy

The CFS-inspired policy is intentionally narrow:
- runnable task with the lowest virtual runtime wins
- each executed tick adds a deterministic weight-adjusted amount to that task's virtual runtime over a bounded simulator weight range
- equal virtual runtimes fall back to scenario declaration order

This is **not** faithful Linux CFS.

Linux relevance:
- lowest-vruntime selection approximates the core mental model behind fair scheduling
- demonstrates why fairness accounting changes completion order relative to FCFS

Explicit omissions:
- Linux's full nice-to-weight table
- sleeper bonuses
- Linux wait-queue semantics and wakeup races
- Linux SMP balancing heuristics, scheduler-domain behavior, and per-CPU runqueue fidelity
- cgroups or group scheduling
- kernel timing precision, interrupts, and scheduler-class interactions
- priority inheritance and other kernel edge cases

## Deterministic rules that docs and code must preserve

1. For tick `t`, arrivals are incorporated before dispatch for tick `t`.
2. Ties fall back to stable scenario declaration order.
3. If Round Robin quantum expiry and completion coincide on the same tick, completion wins.
4. Idle ticks are explicit in the engine and raw trace.
5. Raw trace event kinds include:
   - `arrival`
   - `dispatch`
   - `tick`
   - `preempt`
   - `complete`
   - `idle`

## Why Scenario C matters

Scenario C is the clearest teaching example:
- `L`: arrival `0`, burst `8`
- `S1`: arrival `1`, burst `2`
- `S2`: arrival `2`, burst `1`
- Round Robin quantum: `2`

It should be used to explain:
- FCFS convoy effects
- Round Robin latency improvements for short jobs
- how CFS-inspired accounting changes ordering pressure without claiming kernel fidelity

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

### Deadline-inspired teaching policy

The deadline-inspired policy is intentionally small:
- runnable task with the earliest declared absolute deadline wins
- earlier-deadline arrivals can trigger deterministic preemption
- ties fall back to scenario declaration order

Important caveat:
- this is not Linux SCHED_DEADLINE or any kernel real-time class
- no admission control, runtime budgets, replenishment, or utilization guarantees are modeled
- deadlines are teaching inputs, not correctness proofs

### Group scheduling analogy

The group scheduling model is intentionally narrow:
- tasks may belong to declared groups
- groups may carry a teaching `weight` and `quota_ticks` cap
- the current implementation uses those values only as deterministic simulator heuristics for group fairness discussion

Important caveat:
- this is not Linux cgroups, CFS group scheduling, or kernel bandwidth control
- no hierarchy depth beyond one declared group layer is modeled
- no kernel accounting, throttling periods, or controller integration is modeled


### Topology-aware multicore analogy

The topology model is intentionally narrow:
- cores may be grouped into declared topology domains
- arrival placement first chooses a least-loaded domain, then a least-loaded core within that domain
- idle-core steals prefer same-domain donors before cross-domain steals

Important caveat:
- this is not Linux scheduler-domain logic, NUMA balancing, or cache-affinity fidelity
- no memory locality costs or hardware discovery are modeled
- domain ids are teaching labels, not measured hardware topology

