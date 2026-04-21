const scheduler = @import("zig_scheduler");

pub const Case = struct {
    name: []const u8,
    scenario_path: []const u8,
    policy: scheduler.PolicyKind,
};

pub const default_cases = [_]Case{
    .{ .name = "arrivals-fcfs", .scenario_path = "scenarios/basic/arrivals.zon", .policy = .fcfs },
    .{ .name = "short-vs-long-rr", .scenario_path = "scenarios/basic/short-vs-long.zon", .policy = .round_robin },
    .{ .name = "weighted-fairness-cfs", .scenario_path = "scenarios/basic/weighted-fairness.zon", .policy = .cfs_like },
    .{ .name = "multicore-contention-fcfs", .scenario_path = "scenarios/basic/multicore-contention.zon", .policy = .fcfs },
    .{ .name = "multicore-rr-quantum-rr", .scenario_path = "scenarios/basic/multicore-rr-quantum.zon", .policy = .round_robin },
    .{ .name = "multicore-weighted-cfs", .scenario_path = "scenarios/basic/multicore-weighted.zon", .policy = .cfs_like },
};
