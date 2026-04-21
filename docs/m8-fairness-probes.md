# M8 fairness and latency probes

M8 adds deterministic probe fixtures and metrics for fairness-oriented discussion across policies.

## Scope and caution
- These fixtures are simulator-local teaching probes.
- They help compare policy tradeoffs with concrete evidence.
- They are **not formal starvation proofs**.
- They do **not** claim Linux scheduler behavior, Linux latency numbers, or Linux fairness guarantees.

## Probe fixtures
- `scenarios/basic/latency-probe.zon`
  - long batch task plus repeated short arrivals
  - useful for comparing response-time and latency spread across policies
- `scenarios/basic/starvation-pressure.zon`
  - equal-arrival weighted contention with one low-weight task
  - useful for exposing starvation pressure and motivating future aging discussions

## Probe metrics
The simulator export now includes these aggregate probe metrics:
- `max_waiting_time`
- `max_response_time`
- `response_time_spread`

Use them together with:
- `average_waiting_time`
- `average_response_time`
- `waiting_time_spread`
- per-task waiting and response values

## Example workflow
Compare the latency probe under FCFS and Round Robin:

```sh
zig build sim -- --scenario-file scenarios/basic/latency-probe.zon --policy fcfs --format json
zig build sim -- --scenario-file scenarios/basic/latency-probe.zon --policy rr --format json
```

Compare the starvation-pressure probe under CFS-inspired scheduling:

```sh
zig build sim -- --scenario-file scenarios/basic/starvation-pressure.zon --policy cfs-like --format json
```

## Evidence-based interpretation
- If `max_response_time` drops under Round Robin relative to FCFS, that is evidence of better short-task latency in this simulator workload.
- If `max_waiting_time` and `waiting_time_spread` grow under a weighted fairness probe, that is evidence of starvation pressure on some tasks in this simulator workload.
- If a future milestone adds aging strategies, these same fixtures can be reused to compare whether the pressure decreases.

Keep explanations evidence-based: describe what the deterministic fixture and metrics show in this repo, and avoid projecting beyond that scope.
