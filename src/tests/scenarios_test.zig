const std = @import("std");
const sim = @import("../root.zig");

fn expectApprox(actual: f64, expected: f64) !void {
    try std.testing.expectApproxEqAbs(expected, actual, 0.000001);
}

test "scenario C FCFS golden oracle" {
    const allocator = std.testing.allocator;
    var scenario = try sim.loadScenarioByName(allocator, "short-vs-long");
    defer scenario.deinit();

    var result = try sim.simulate(allocator, &scenario, .fcfs);
    defer result.deinit();

    try std.testing.expectEqualStrings("L", result.completionTaskId(0));
    try std.testing.expectEqualStrings("S1", result.completionTaskId(1));
    try std.testing.expectEqualStrings("S2", result.completionTaskId(2));

    const l = result.taskById("L").?;
    const s1 = result.taskById("S1").?;
    const s2 = result.taskById("S2").?;

    try std.testing.expectEqual(@as(u32, 8), l.completion_time);
    try std.testing.expectEqual(@as(u32, 10), s1.completion_time);
    try std.testing.expectEqual(@as(u32, 11), s2.completion_time);
    try std.testing.expectEqual(@as(u32, 0), l.waiting_time);
    try std.testing.expectEqual(@as(u32, 7), s1.waiting_time);
    try std.testing.expectEqual(@as(u32, 8), s2.waiting_time);
    try std.testing.expectEqual(@as(u32, 0), l.response_time);
    try std.testing.expectEqual(@as(u32, 7), s1.response_time);
    try std.testing.expectEqual(@as(u32, 8), s2.response_time);
    try expectApprox(result.aggregate.average_waiting_time, 5.0);
    try expectApprox(result.aggregate.average_response_time, 5.0);
    try std.testing.expectEqual(@as(u32, 3), result.aggregate.throughput_numerator);
    try std.testing.expectEqual(@as(u32, 11), result.aggregate.throughput_denominator);
}

test "scenario C Round Robin golden oracle" {
    const allocator = std.testing.allocator;
    var scenario = try sim.loadScenarioByName(allocator, "short-vs-long");
    defer scenario.deinit();

    var result = try sim.simulate(allocator, &scenario, .round_robin);
    defer result.deinit();

    try std.testing.expectEqualStrings("S1", result.completionTaskId(0));
    try std.testing.expectEqualStrings("S2", result.completionTaskId(1));
    try std.testing.expectEqualStrings("L", result.completionTaskId(2));

    const l = result.taskById("L").?;
    const s1 = result.taskById("S1").?;
    const s2 = result.taskById("S2").?;

    try std.testing.expectEqual(@as(u32, 11), l.completion_time);
    try std.testing.expectEqual(@as(u32, 4), s1.completion_time);
    try std.testing.expectEqual(@as(u32, 5), s2.completion_time);
    try std.testing.expectEqual(@as(u32, 3), l.waiting_time);
    try std.testing.expectEqual(@as(u32, 1), s1.waiting_time);
    try std.testing.expectEqual(@as(u32, 2), s2.waiting_time);
    try std.testing.expectEqual(@as(u32, 0), l.response_time);
    try std.testing.expectEqual(@as(u32, 1), s1.response_time);
    try std.testing.expectEqual(@as(u32, 2), s2.response_time);
    try expectApprox(result.aggregate.average_waiting_time, 2.0);
    try expectApprox(result.aggregate.average_response_time, 1.0);
    try std.testing.expectEqual(@as(u32, 11), result.aggregate.throughput_denominator);

    const expected_dispatch = [_][]const u8{ "L", "S1", "S2", "L" };
    var dispatch_index: usize = 0;
    for (result.trace) |entry| {
        if (entry.kind != .dispatch) continue;
        if (dispatch_index >= expected_dispatch.len) break;
        try std.testing.expectEqualStrings(expected_dispatch[dispatch_index], entry.task_id.?);
        dispatch_index += 1;
    }
    try std.testing.expectEqual(expected_dispatch.len, dispatch_index);
}

test "scenario C CFS inspired invariants" {
    const allocator = std.testing.allocator;
    var scenario = try sim.loadScenarioByName(allocator, "short-vs-long");
    defer scenario.deinit();

    var result = try sim.simulate(allocator, &scenario, .cfs_like);
    defer result.deinit();

    try std.testing.expect(!std.mem.eql(u8, result.completionTaskId(0), "L"));
    try std.testing.expectEqualStrings("short-vs-long", result.scenario_name);
}

test "weighted CFS fairness can overcome declaration order under equal contention" {
    const allocator = std.testing.allocator;
    var scenario = try sim.loadScenarioFile(allocator, "scenarios/basic/weighted-fairness.zon");
    defer scenario.deinit();

    var result = try sim.simulate(allocator, &scenario, .cfs_like);
    defer result.deinit();

    const light = result.taskById("light").?;
    const heavy = result.taskById("heavy").?;

    try std.testing.expect(heavy.completion_time < light.completion_time);
    try std.testing.expect(heavy.waiting_time <= light.waiting_time);
}

test "weight model covers the documented range without saturation inside it" {
    try std.testing.expect(sim.policies.cfs_like.vruntimeDelta(sim.max_task_weight) < sim.policies.cfs_like.vruntimeDelta(sim.default_task_weight));
    try std.testing.expectEqual(@as(u64, 1), sim.policies.cfs_like.vruntimeDelta(sim.max_task_weight));
}

test "weighted scenarios remain compatible with FCFS and Round Robin semantics" {
    const allocator = std.testing.allocator;
    const weighted_source =
        \\.{
        \\    .name = "weighted-compat",
        \\    .tasks = .{
        \\        .{ .id = "A", .arrival_tick = 0, .burst_ticks = 4, .weight = 2048 },
        \\        .{ .id = "B", .arrival_tick = 0, .burst_ticks = 2, .weight = 256 },
        \\        .{ .id = "C", .arrival_tick = 1, .burst_ticks = 1 },
        \\    },
        \\}
    ;
    const unweighted_source =
        \\.{
        \\    .name = "weighted-compat",
        \\    .tasks = .{
        \\        .{ .id = "A", .arrival_tick = 0, .burst_ticks = 4 },
        \\        .{ .id = "B", .arrival_tick = 0, .burst_ticks = 2 },
        \\        .{ .id = "C", .arrival_tick = 1, .burst_ticks = 1 },
        \\    },
        \\}
    ;

    var weighted = try sim.parseScenarioText(allocator, weighted_source, "weighted-compat");
    defer weighted.deinit();
    var unweighted = try sim.parseScenarioText(allocator, unweighted_source, "weighted-compat");
    defer unweighted.deinit();

    const policies = [_]sim.PolicyKind{ .fcfs, .round_robin };
    for (policies) |policy| {
        var weighted_result = try sim.simulate(allocator, &weighted, policy);
        defer weighted_result.deinit();
        var unweighted_result = try sim.simulate(allocator, &unweighted, policy);
        defer unweighted_result.deinit();

        try std.testing.expectEqual(weighted_result.completion_order.len, unweighted_result.completion_order.len);
        for (weighted_result.completion_order, unweighted_result.completion_order) |lhs, rhs| {
            try std.testing.expectEqual(lhs, rhs);
        }
        for (weighted_result.tasks, unweighted_result.tasks) |lhs, rhs| {
            try std.testing.expectEqualStrings(lhs.id, rhs.id);
            try std.testing.expectEqual(lhs.completion_time, rhs.completion_time);
            try std.testing.expectEqual(lhs.waiting_time, rhs.waiting_time);
            try std.testing.expectEqual(lhs.response_time, rhs.response_time);
        }
    }
}
