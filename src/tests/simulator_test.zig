const std = @import("std");
const sim = @import("../root.zig");

fn loadShortVsLong(allocator: std.mem.Allocator) !sim.ScenarioOwned {
    return sim.loadScenarioByName(allocator, "short-vs-long");
}

fn loadWeightedFixture(allocator: std.mem.Allocator) !sim.ScenarioOwned {
    return sim.loadScenarioFile(allocator, "scenarios/basic/weighted-fairness.zon");
}

fn taskIndexById(tasks: []const sim.TaskMetrics, id: []const u8) ?usize {
    for (tasks, 0..) |task, index| {
        if (std.mem.eql(u8, task.id, id)) return index;
    }
    return null;
}

fn expectNoDuplicateTaskTicksPerTick(trace: []const sim.TraceEntry) !void {
    for (trace, 0..) |entry, index| {
        if (entry.kind != .tick) continue;
        const task_id = entry.task_id orelse return error.MissingTaskId;
        for (trace[index + 1 ..]) |other| {
            if (other.tick != entry.tick) continue;
            if (other.kind != .tick) continue;
            try std.testing.expect(!std.mem.eql(u8, task_id, other.task_id orelse return error.MissingTaskId));
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

test "per-core execution reconciliation matches task totals and total work" {
    const allocator = std.testing.allocator;
    var scenario = try loadWeightedFixture(allocator);
    defer scenario.deinit();

    const policies = [_]sim.PolicyKind{ .fcfs, .round_robin, .cfs_like };
    for (policies) |policy| {
        var result = try sim.simulate(allocator, &scenario, policy);
        defer result.deinit();

        try expectNoDuplicateTaskTicksPerTick(result.trace);

        const core_count: usize = @intCast(result.core_count);
        try std.testing.expect(core_count >= 1);

        const per_core = try allocator.alloc(u32, core_count);
        defer allocator.free(per_core);
        @memset(per_core, 0);

        const per_task = try allocator.alloc(u32, result.tasks.len);
        defer allocator.free(per_task);
        @memset(per_task, 0);

        var total_tick_events: u32 = 0;
        for (result.trace) |entry| {
            if (entry.kind != .tick) continue;

            const core_id = entry.core_id orelse return error.MissingCoreIdentity;
            try std.testing.expect(core_id < result.core_count);

            const core_index: usize = @intCast(core_id);
            per_core[core_index] += 1;
            total_tick_events += 1;

            const task_id = entry.task_id orelse return error.MissingTaskId;
            const task_index = taskIndexById(result.tasks, task_id) orelse return error.UnknownTaskId;
            per_task[task_index] += 1;
        }

        var summed_core_ticks: u32 = 0;
        for (per_core) |count| summed_core_ticks += count;
        try std.testing.expectEqual(total_tick_events, summed_core_ticks);

        var expected_total_work: u32 = 0;
        for (result.tasks, per_task) |task, counted_ticks| {
            expected_total_work += task.burst_ticks;
            try std.testing.expectEqual(task.total_executed, counted_ticks);
            try std.testing.expectEqual(task.burst_ticks, counted_ticks);
        }

        try std.testing.expectEqual(expected_total_work, total_tick_events);
    }
}
