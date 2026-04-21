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

## Trace event counts

| event | count |
| --- | ---: |
| arrival | 4 |
| dispatch | 4 |
| tick | 14 |
| preempt | 0 |
| complete | 4 |
| idle | 2 |

## Per-core activity

| core | arrivals | dispatches | busy_ticks | completions | idle_events | preemptions |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0 | 2 | 2 | 8 | 2 | 0 | 0 |
| 1 | 2 | 2 | 6 | 2 | 2 | 0 |

## Per-task metrics (input order)

| task | arrival | burst | first_dispatch | completion | wait | response | turnaround | executed | weight |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| A | 0 | 5 | 0 | 5 | 0 | 0 | 5 | 5 | 1024 |
| B | 0 | 4 | 0 | 4 | 0 | 0 | 4 | 4 | 1024 |
| C | 1 | 3 | 5 | 8 | 4 | 4 | 7 | 3 | 1024 |
| D | 1 | 2 | 4 | 6 | 3 | 3 | 5 | 2 | 1024 |

## Export notes

- Phase 1 is an in-process simulator only; it does not spawn or control real processes.
- The CFS-inspired policy uses simple virtual-runtime-style accounting and is not faithful Linux CFS.
