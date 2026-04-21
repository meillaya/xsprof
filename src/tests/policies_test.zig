const std = @import("std");
const sim = @import("../root.zig");

fn loadScenario(allocator: std.mem.Allocator, name: []const u8) !sim.ScenarioOwned {
    return sim.loadScenarioByName(allocator, name);
}

fn loadWeightedFixture(allocator: std.mem.Allocator) !sim.ScenarioOwned {
    return sim.loadScenarioFile(allocator, "scenarios/basic/weighted-fairness.zon");
}

fn loadMulticoreFixture(allocator: std.mem.Allocator) !sim.ScenarioOwned {
    return sim.loadScenarioFile(allocator, "scenarios/basic/multicore-contention.zon");
}

test "fcfs preserves equal-arrival input order" {
    const allocator = std.testing.allocator;
    var scenario = try loadScenario(allocator, "equal-arrival-contention");
    defer scenario.deinit();

    var result = try sim.simulate(allocator, &scenario, .fcfs);
    defer result.deinit();

    try std.testing.expectEqualStrings("A", result.completionTaskId(0));
    try std.testing.expectEqualStrings("B", result.completionTaskId(1));
    try std.testing.expectEqualStrings("C", result.completionTaskId(2));
}

test "round robin preempts on quantum boundary when peers are runnable" {
    const allocator = std.testing.allocator;
    var scenario = try loadScenario(allocator, "short-vs-long");
    defer scenario.deinit();

    var result = try sim.simulate(allocator, &scenario, .round_robin);
    defer result.deinit();

    var saw_preempt = false;
    for (result.trace) |entry| {
        if (entry.kind == .preempt and std.mem.eql(u8, entry.task_id.?, "L")) {
            saw_preempt = true;
            try std.testing.expectEqual(@as(u32, 2), entry.tick);
            break;
        }
    }
    try std.testing.expect(saw_preempt);
}

test "cfs inspired policy is deterministic across repeated runs" {
    const allocator = std.testing.allocator;
    var scenario = try loadScenario(allocator, "equal-arrival-contention");
    defer scenario.deinit();

    var first = try sim.simulate(allocator, &scenario, .cfs_like);
    defer first.deinit();
    var second = try sim.simulate(allocator, &scenario, .cfs_like);
    defer second.deinit();

    try std.testing.expectEqual(first.trace.len, second.trace.len);
    for (first.trace, second.trace) |lhs, rhs| {
        try std.testing.expectEqual(lhs.kind, rhs.kind);
        try std.testing.expectEqual(lhs.tick, rhs.tick);
        if (lhs.task_id) |lhs_id| {
            try std.testing.expectEqualStrings(lhs_id, rhs.task_id.?);
        } else {
            try std.testing.expect(rhs.task_id == null);
        }
    }
}

test "weighted scenarios stay deterministic across repeated runs for every policy" {
    const allocator = std.testing.allocator;
    var scenario = try loadWeightedFixture(allocator);
    defer scenario.deinit();

    const policies = [_]sim.PolicyKind{ .fcfs, .round_robin, .cfs_like };
    for (policies) |policy| {
        var first = try sim.simulate(allocator, &scenario, policy);
        defer first.deinit();
        var second = try sim.simulate(allocator, &scenario, policy);
        defer second.deinit();

        try std.testing.expectEqual(first.trace.len, second.trace.len);
        try std.testing.expectEqual(first.tasks.len, second.tasks.len);
        try std.testing.expectEqual(first.completion_order.len, second.completion_order.len);

        for (first.trace, second.trace) |lhs, rhs| {
            try std.testing.expectEqual(lhs.kind, rhs.kind);
            try std.testing.expectEqual(lhs.tick, rhs.tick);
            if (lhs.task_id) |lhs_id| {
                try std.testing.expectEqualStrings(lhs_id, rhs.task_id.?);
            } else {
                try std.testing.expect(rhs.task_id == null);
            }
        }

        for (first.tasks, second.tasks) |lhs, rhs| {
            try std.testing.expectEqualStrings(lhs.id, rhs.id);
            try std.testing.expectEqual(lhs.weight, rhs.weight);
            try std.testing.expectEqual(lhs.completion_time, rhs.completion_time);
            try std.testing.expectEqual(lhs.waiting_time, rhs.waiting_time);
            try std.testing.expectEqual(lhs.response_time, rhs.response_time);
        }
    }
}

test "multicore fixtures stay deterministic across repeated runs for every policy" {
    const allocator = std.testing.allocator;
    var scenario = try loadMulticoreFixture(allocator);
    defer scenario.deinit();

    const policies = [_]sim.PolicyKind{ .fcfs, .round_robin, .cfs_like };
    for (policies) |policy| {
        var first = try sim.simulate(allocator, &scenario, policy);
        defer first.deinit();
        var second = try sim.simulate(allocator, &scenario, policy);
        defer second.deinit();

        try std.testing.expectEqual(first.core_count, second.core_count);
        try std.testing.expectEqual(first.trace.len, second.trace.len);
        for (first.trace, second.trace) |lhs, rhs| {
            try std.testing.expectEqual(lhs.tick, rhs.tick);
            try std.testing.expectEqual(lhs.kind, rhs.kind);
            try std.testing.expectEqual(lhs.core_id, rhs.core_id);
            if (lhs.task_id) |lhs_id| {
                try std.testing.expectEqualStrings(lhs_id, rhs.task_id.?);
            } else {
                try std.testing.expect(rhs.task_id == null);
            }
        }
    }
}
