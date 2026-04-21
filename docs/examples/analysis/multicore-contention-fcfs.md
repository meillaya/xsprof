# zig-scheduler analysis report

- Contract: `zig-scheduler/report` v1
- Scenario: `multicore-contention`
- Policy: `FCFS` (`fcfs`)
- Source: `file` `scenarios/basic/multicore-contention.zon`
- Core count: 2
- Task count: 4
- Completion order: `B -> A -> D -> C`

## Aggregate metrics

| metric | value |
| --- | ---: |
| average_waiting_time | 1.750 |
| average_response_time | 1.750 |
| throughput | 0.500 |
| throughput_ratio | 4/8 |
| waiting_time_spread | 4 |
| max_waiting_time | 4 |
| max_response_time | 4 |
| response_time_spread | 4 |

## Trace event counts

| event | count |
| --- | ---: |
| arrival | 4 |
| dispatch | 4 |
| tick | 14 |
| preempt | 0 |
| block | 0 |
| wakeup | 0 |
| complete | 4 |
| idle | 2 |

## Per-core activity

| core | arrivals | dispatches | busy_ticks | completions | idle_events | preemptions | blocks | wakeups |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0 | 2 | 2 | 8 | 2 | 0 | 0 | 0 | 0 |
| 1 | 2 | 2 | 6 | 2 | 2 | 0 | 0 | 0 |

## Per-task metrics (input order)

| task | arrival | burst | sleep_after | sleep_duration | phase_count | deadline | first_dispatch | completion | wait | blocked | response | turnaround | executed | weight |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| A | 0 | 5 | - | 0 | 1 | - | 0 | 5 | 0 | 0 | 0 | 5 | 5 | 1024 |
| B | 0 | 4 | - | 0 | 1 | - | 0 | 4 | 0 | 0 | 0 | 4 | 4 | 1024 |
| C | 1 | 3 | - | 0 | 1 | - | 5 | 8 | 4 | 0 | 4 | 7 | 3 | 1024 |
| D | 1 | 2 | - | 0 | 1 | - | 4 | 6 | 3 | 0 | 3 | 5 | 2 | 1024 |

## Export notes

- Phase 1 is an in-process simulator only; it does not spawn or control real processes.
- The CFS-inspired policy uses simple virtual-runtime-style accounting and is not faithful Linux CFS.
- The deadline-inspired policy is a deterministic teaching model, not a Linux real-time scheduler implementation.
- The group scheduling model is a simulator-safe teaching analogy, not Linux cgroups or kernel group scheduling fidelity.
