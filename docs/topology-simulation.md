# topology-aware simulation

the simulator introduces a deterministic topology layer on top of the existing multicore simulator.

## Scope and caveats
- This is a simulator-local teaching model.
- Scenarios may declare `topology_domains` to group cores into one higher-level distinction.
- Trace events expose `domain_id` alongside `core_id` for task-scoped events.
- This is **not** Linux NUMA balancing, scheduler domains, or cache-affinity fidelity.

## Scenario surface
```zig
.{
    .core_count = 4,
    .topology_domains = .{
        .{ .id = "node0", .cores = .{ 0, 1 } },
        .{ .id = "node1", .cores = .{ 2, 3 } },
    },
}
```

## Canonical fixture
- `scenarios/basic/topology-domains.zon`

## Current deterministic rules
- arrivals choose the least-loaded topology domain, then the least-loaded core inside that domain
- idle-core stealing prefers same-domain donors before cross-domain donors
- topology information is exported via top-level `topology_domains` and trace-level `domain_id`

## Evidence-based interpretation
Use this workstream to explain how a simple topology distinction can change placement and migration behavior in the simulator. Avoid projecting the result onto Linux NUMA or scheduler-domain guarantees.
