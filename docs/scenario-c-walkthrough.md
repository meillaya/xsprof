# Simulator scenario C walkthrough

Canonical fixture: `scenarios/basic/short-vs-long.zon`

Scenario C from the approved test spec is the best explanatory example for simulator baseline because it makes latency and fairness tradeoffs visible with a very small workload.

## Scenario definition

- `L`: arrival `0`, burst `8`
- `S1`: arrival `1`, burst `2`
- `S2`: arrival `2`, burst `1`
- Round Robin quantum: `2`

## Metric formulas used in this walkthrough

- `completion_time = tick immediately after the task's final executed tick`
- `turnaround_time = completion_time - arrival_tick`
- `waiting_time = turnaround_time - burst_ticks`
- `response_time = first_dispatch_tick - arrival_tick`
- `throughput = completed_task_count / (last_completion_tick - earliest_arrival_tick)`

## FCFS interpretation

FCFS keeps the CPU on `L` until it completes. That makes the short jobs wait behind the long job, which is the classic convoy-style effect this simulator should teach.

### FCFS completion order

`L -> S1 -> S2`

### FCFS timeline sketch

- ticks `0..7`: `L`
- ticks `8..9`: `S1`
- tick `10`: `S2`

### FCFS expected metrics

| Task | Completion | Turnaround | Waiting | Response |
| --- | ---: | ---: | ---: | ---: |
| `L` | 8 | 8 | 0 | 0 |
| `S1` | 10 | 9 | 7 | 7 |
| `S2` | 11 | 9 | 8 | 8 |

Aggregate expectations:
- average waiting time = `5`
- average response time = `5`
- throughput = `3/11`

## Round Robin interpretation

Round Robin gives `L` the CPU first, but the fixed quantum allows short tasks to run much sooner after they arrive. This improves latency for `S1` and `S2` without claiming Linux-kernel fidelity.

### Round Robin dispatch slices

`L -> S1 -> S2 -> L`

### Round Robin timeline sketch

- ticks `0..1`: `L`
- ticks `2..3`: `S1`
- tick `4`: `S2`
- ticks `5..10`: `L`

### Round Robin expected metrics

| Task | Completion | Turnaround | Waiting | Response |
| --- | ---: | ---: | ---: | ---: |
| `L` | 11 | 11 | 3 | 0 |
| `S1` | 4 | 3 | 1 | 1 |
| `S2` | 5 | 3 | 2 | 2 |

Aggregate expectations:
- average waiting time = `2`
- average response time = `1`
- throughput = `3/11`

## Simplified CFS-inspired review target

simulator baseline does not freeze an exact Scenario C golden output for the CFS-inspired policy unless the implementation later freezes vruntime arithmetic more tightly.

Required review invariants:
- at least one short task completes before `L`
- repeated runs are deterministic
- docs explain why the observed order follows the chosen vruntime update rule

## What this scenario should teach

Scenario C is useful in docs and review because it exposes three teaching points quickly:

1. **FCFS can punish short jobs behind long work.**
2. **Round Robin improves responsiveness by time slicing.**
3. **A CFS-inspired policy should be described as fairness-oriented, not Linux-faithful.**

## Wording guardrails for docs and CLI output

When this scenario is referenced in docs, examples, or CLI help text:
- say the policies are **Linux-inspired** or **teaching models**
- call the fair policy **CFS-inspired** or **simplified CFS-like**
- avoid wording that says simulator baseline "implements Linux CFS"

## Review checklist for Scenario C implementation

- [ ] FCFS matches the exact oracle values above
- [ ] Round Robin matches the exact oracle values above
- [ ] CFS-inspired behavior is deterministic
- [ ] at least one short task completes before `L` under the CFS-inspired policy
- [ ] trace ordering is stable for repeated runs
- [ ] docs explain why the chosen fair-scheduling behavior occurs
