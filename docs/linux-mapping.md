# Linux Mapping Notes

## FCFS/FIFO
The FCFS policy is a baseline for observing convoy effects and response-time tradeoffs. It is Linux-relevant as a contrast point rather than a direct Linux scheduler replica.

## Round Robin
The Round Robin policy models time-sliced fairness and latency tradeoffs in a simplified user-space form. It helps explain why preemption and runnable-peer awareness matter.

## Simplified CFS-inspired policy
The CFS-inspired policy in Phase 1 is intentionally narrow:
- runnable task with the lowest virtual runtime wins
- each executed tick adds `1` to that task's virtual runtime
- equal virtual runtimes fall back to scenario declaration order

This is **not** faithful Linux CFS.

### Explicit omissions
- nice weights
- sleeper bonuses
- SMP or multi-core balancing
- cgroups or group scheduling
- kernel timing precision, interrupts, and scheduler-class interactions
- priority inheritance and other kernel edge cases
