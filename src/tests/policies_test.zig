const std = @import("std");
const sim = @import("../root.zig");

fn loadScenario(allocator: std.mem.Allocator, name: []const u8) !sim.ScenarioOwned {
    return sim.loadScenarioByName(allocator, name);
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
