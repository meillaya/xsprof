const std = @import("std");
const sim = @import("../root.zig");

fn loadShortVsLong(allocator: std.mem.Allocator) !sim.ScenarioOwned {
    return sim.loadScenarioByName(allocator, "short-vs-long");
}

fn expectNoDuplicateTaskTicksPerTick(trace: []const sim.TraceEntry) !void {
    for (trace, 0..) |entry, index| {
        if (entry.kind != .tick) continue;
        const task_id = entry.task_id orelse continue;

        for (trace[index + 1 ..]) |other| {
            if (other.tick != entry.tick) continue;
            if (other.kind != .tick) continue;
            try std.testing.expect(other.task_id != null);
            try std.testing.expect(!std.mem.eql(u8, task_id, other.task_id.?));
        }
    }
}

test "scenario parser loads deterministic task order" {
    const allocator = std.testing.allocator;
    var scenario = try sim.loadScenarioByName(allocator, "staggered-arrivals");
    defer scenario.deinit();

    try std.testing.expectEqualStrings("staggered-arrivals", scenario.name);
    try std.testing.expectEqual(@as(u32, 2), scenario.round_robin_quantum);
    try std.testing.expectEqual(@as(usize, 3), scenario.tasks.len);
    try std.testing.expectEqualStrings("A", scenario.tasks[0].id);
    try std.testing.expectEqual(@as(u32, 4), scenario.tasks[2].arrival_tick);
}

test "engine records idle ticks before first arrival" {
    const allocator = std.testing.allocator;
    var scenario = try sim.parseScenarioText(
        allocator,
        "name: delayed\nrr_quantum: 2\ntask: X 2 1\n",
        "delayed",
    );
    defer scenario.deinit();

    var result = try sim.simulate(allocator, &scenario, .fcfs);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 6), result.trace.len);
    try std.testing.expectEqual(sim.TraceEventKind.idle, result.trace[0].kind);
    try std.testing.expectEqual(@as(u32, 0), result.trace[0].tick);
    try std.testing.expectEqual(sim.TraceEventKind.idle, result.trace[1].kind);
    try std.testing.expectEqual(@as(u32, 1), result.trace[1].tick);
    try std.testing.expectEqual(sim.TraceEventKind.arrival, result.trace[2].kind);
}

test "simulation terminates with consistent per-task accounting" {
    const allocator = std.testing.allocator;
    var scenario = try loadShortVsLong(allocator);
    defer scenario.deinit();

    var result = try sim.simulate(allocator, &scenario, .fcfs);
    defer result.deinit();

    for (result.tasks) |task| {
        try std.testing.expectEqual(task.burst_ticks, task.total_executed);
        try std.testing.expect(task.completion_time >= task.arrival_tick);
        try std.testing.expect(task.waiting_time <= task.turnaround_time);
    }
}

test "simulation never records the same task executing twice in one tick" {
    const allocator = std.testing.allocator;
    var short_vs_long = try loadShortVsLong(allocator);
    defer short_vs_long.deinit();

    const weighted_source =
        \\.{
        \\    .name = "weighted-no-double-run",
        \\    .tasks = .{
        \\        .{ .id = "light", .arrival_tick = 0, .burst_ticks = 4, .weight = 512 },
        \\        .{ .id = "heavy", .arrival_tick = 0, .burst_ticks = 4, .weight = 2048 },
        \\        .{ .id = "default", .arrival_tick = 0, .burst_ticks = 2 },
        \\    },
        \\}
    ;
    var weighted = try sim.parseScenarioText(allocator, weighted_source, "weighted-no-double-run");
    defer weighted.deinit();

    const cases = [_]struct {
        policy: sim.PolicyKind,
        scenario: *const sim.ScenarioOwned,
    }{
        .{ .policy = .fcfs, .scenario = &short_vs_long },
        .{ .policy = .round_robin, .scenario = &short_vs_long },
        .{ .policy = .cfs_like, .scenario = &short_vs_long },
        .{ .policy = .cfs_like, .scenario = &weighted },
    };

    for (cases) |case| {
        var result = try sim.simulate(allocator, case.scenario, case.policy);
        defer result.deinit();

        try expectNoDuplicateTaskTicksPerTick(result.trace);
    }
}
