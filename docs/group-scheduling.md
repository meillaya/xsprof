# M11 group scheduling model

M11 introduces a simulator-safe group scheduling model for teaching group fairness ideas.

## Scope and caveats
- This is a deterministic teaching model.
- Scenarios may declare top-level groups and task membership via `group_id`.
- Groups currently support `weight` and `quota_ticks`.
- The CFS-inspired policy is the main consumer of these fields in the current milestone.
- This is **not** Linux cgroups, kernel group scheduling, or bandwidth control.

## Scenario surface
```zig
.{
    .groups = .{
        .{ .id = "interactive", .weight = 2048, .quota_ticks = 1 },
        .{ .id = "batch", .weight = 512, .quota_ticks = 1 },
    },
    .tasks = .{
        .{ .id = "uiA", .arrival_tick = 0, .burst_ticks = 3, .group_id = "interactive" },
        .{ .id = "bg", .arrival_tick = 0, .burst_ticks = 6, .group_id = "batch" },
    },
}
```

## Canonical fixture
- `scenarios/basic/group-fairness.zon`

## Current semantics
- Group `weight` contributes to effective fairness weighting for the CFS-inspired policy.
- Group `quota_ticks` acts as a deterministic cap that helps keep other runnable groups visible when they are competing.
- Non-group-aware policies keep their existing semantics; group metadata is still parsed and exported.

## Output contract
The versioned export now includes:
- top-level `groups`
- per-task `group_id`
- per-trace-entry `group_id` when the event is task-scoped

## Evidence-based interpretation
Use this milestone to discuss how grouped workloads can change fairness outcomes inside this simulator. Avoid projecting the results onto Linux cgroups or kernel scheduler guarantees.
