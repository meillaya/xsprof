# M10 deadline-inspired teaching policy

M10 adds a deterministic deadline-inspired teaching policy for cross-policy comparison.

## Scope and caveats
- This is a simulator-local teaching policy.
- It prefers the runnable task with the earliest declared absolute `deadline_tick`.
- It may preempt when a newly runnable task has an earlier deadline than the current task.
- It is **not** Linux SCHED_DEADLINE, EDF with admission control, or a real-time guarantee mechanism.

## CLI
```sh
zig build sim -- --scenario-file scenarios/basic/deadline-priority.zon --policy deadline --format json
```

Accepted aliases:
- `deadline`
- `edf`

## Canonical fixture
- `scenarios/basic/deadline-priority.zon`

This fixture mixes a long batch task with earlier-deadline short tasks so the deadline-inspired policy can be compared reproducibly against FCFS and Round Robin.

## Evidence-based interpretation
- If short urgent tasks complete earlier under the deadline-inspired policy than under FCFS, that is evidence the fixture is surfacing deadline pressure in this simulator.
- If the deadline-inspired policy changes completion order or response time, that is a deterministic cross-policy comparison, not a Linux scheduling claim.

## Output contract
The versioned JSON export includes per-task `deadline_tick` values when present. Existing scenarios without deadlines remain valid; the field is optional and ignored by non-deadline policies.
