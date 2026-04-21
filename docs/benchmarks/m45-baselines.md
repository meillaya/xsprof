# zig-scheduler benchmark baselines

- Contract: `zig-scheduler/benchmark-baseline` v1
- Simulator-local benchmark baseline only; not a Linux performance claim.
- Metrics are deterministic output-size and trace-volume baselines over committed fixtures.

## Case matrix

| case | policy | cores | tasks | trace_events | export_bytes | analysis_md_bytes | analysis_svg_bytes |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| arrivals-fcfs | fcfs | 1 | 4 | 23 | 2671 | 1391 | 2931 |
| short-vs-long-rr | round_robin | 1 | 3 | 22 | 2444 | 1368 | 2619 |
| weighted-fairness-cfs | cfs_like | 1 | 3 | 27 | 2865 | 1397 | 2638 |
| multicore-contention-fcfs | fcfs | 2 | 4 | 28 | 2928 | 1440 | 2941 |
| multicore-rr-quantum-rr | round_robin | 2 | 4 | 30 | 3069 | 1454 | 2949 |
| multicore-weighted-cfs | cfs_like | 2 | 4 | 38 | 3634 | 1475 | 2963 |

## Aggregate totals

| metric | value |
| --- | ---: |
| case_count | 6 |
| total_export_bytes | 17611 |
| total_analysis_markdown_bytes | 8525 |
| total_analysis_svg_bytes | 17041 |
| total_trace_events | 168 |
| max_export_bytes | 3634 |
| max_trace_events | 38 |

## Fixture coverage

- `scenarios/basic/arrivals.zon` -> `arrivals-fcfs` (`fcfs`)
- `scenarios/basic/short-vs-long.zon` -> `short-vs-long-rr` (`round_robin`)
- `scenarios/basic/weighted-fairness.zon` -> `weighted-fairness-cfs` (`cfs_like`)
- `scenarios/basic/multicore-contention.zon` -> `multicore-contention-fcfs` (`fcfs`)
- `scenarios/basic/multicore-rr-quantum.zon` -> `multicore-rr-quantum-rr` (`round_robin`)
- `scenarios/basic/multicore-weighted.zon` -> `multicore-weighted-cfs` (`cfs_like`)
