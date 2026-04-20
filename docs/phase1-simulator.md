# Phase 1 Simulator Semantics

## Tick order
Each simulation tick follows the same deterministic sequence:
1. incorporate arrivals for the current tick
2. evaluate policy dispatch/preemption decisions
3. execute exactly one tick of CPU time for the selected task
4. record resulting completion state at the tick boundary

## Tie breaking
- same-arrival ties fall back to scenario declaration order
- FCFS preserves ready-queue order
- Round Robin rotates the ready queue in deterministic FIFO order
- the CFS-inspired policy picks the runnable task with the lowest virtual runtime, then falls back to declaration order

## Round Robin rule
If a task reaches a quantum boundary and also finishes on that tick, completion wins and no preemption event is emitted.

## Metrics
- `completion_time = tick immediately after the final executed tick`
- `turnaround_time = completion_time - arrival_tick`
- `waiting_time = turnaround_time - burst_ticks`
- `response_time = first_dispatch_tick - arrival_tick`
- `throughput = completed_task_count / (last_completion_tick - earliest_arrival_tick)`
- `waiting_time_spread = max(waiting_time) - min(waiting_time)`

## Phase boundary
This project is a simulator only. It does not launch processes, integrate with the Linux kernel, or implement daemon/service behavior.
