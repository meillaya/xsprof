const std = @import("std");
const sim = @import("../root.zig");
const quality = @import("../quality/root.zig");

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .unlimited);
}

fn expectContainsAll(haystack: []const u8, needles: []const []const u8) !void {
    for (needles) |needle| try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

fn expectTraceEqual(a: []const sim.TraceEntry, b: []const sim.TraceEntry) !void {
    try std.testing.expectEqual(a.len, b.len);
    for (a, b) |left, right| {
        try std.testing.expectEqual(left.tick, right.tick);
        try std.testing.expectEqual(left.kind, right.kind);
        try std.testing.expectEqual(left.core_id, right.core_id);
        if (left.task_id) |left_id| {
            try std.testing.expect(right.task_id != null);
            try std.testing.expectEqualStrings(left_id, right.task_id.?);
        } else try std.testing.expect(right.task_id == null);
        if (left.group_id) |left_id| {
            try std.testing.expect(right.group_id != null);
            try std.testing.expectEqualStrings(left_id, right.group_id.?);
        } else try std.testing.expect(right.group_id == null);
        if (left.domain_id) |left_id| {
            try std.testing.expect(right.domain_id != null);
            try std.testing.expectEqualStrings(left_id, right.domain_id.?);
        } else try std.testing.expect(right.domain_id == null);
    }
}

fn expectTaskMetricsEqual(a: []const sim.TaskMetrics, b: []const sim.TaskMetrics) !void {
    try std.testing.expectEqual(a.len, b.len);
    for (a, b) |left, right| {
        try std.testing.expectEqualStrings(left.id, right.id);
        try std.testing.expectEqual(left.arrival_tick, right.arrival_tick);
        try std.testing.expectEqual(left.burst_ticks, right.burst_ticks);
        try std.testing.expectEqual(left.weight, right.weight);
        try std.testing.expectEqual(left.group_id != null, right.group_id != null);
        if (left.group_id) |left_group| try std.testing.expectEqualStrings(left_group, right.group_id.?);
        try std.testing.expectEqual(left.sleep_after_ticks, right.sleep_after_ticks);
        try std.testing.expectEqual(left.sleep_duration, right.sleep_duration);
        try std.testing.expectEqual(left.phase_count, right.phase_count);
        try std.testing.expectEqual(left.deadline_tick, right.deadline_tick);
        try std.testing.expectEqual(left.input_order, right.input_order);
        try std.testing.expectEqual(left.first_dispatch_tick, right.first_dispatch_tick);
        try std.testing.expectEqual(left.completion_time, right.completion_time);
        try std.testing.expectEqual(left.turnaround_time, right.turnaround_time);
        try std.testing.expectEqual(left.waiting_time, right.waiting_time);
        try std.testing.expectEqual(left.blocked_time, right.blocked_time);
        try std.testing.expectEqual(left.response_time, right.response_time);
        try std.testing.expectEqual(left.total_executed, right.total_executed);
    }
}

fn expectCompletionOrderEqual(a: *const sim.SimulationResult, b: *const sim.SimulationResult) !void {
    try std.testing.expectEqual(a.completion_order.len, b.completion_order.len);
    for (a.completion_order, b.completion_order) |left_index, right_index| {
        try std.testing.expectEqualStrings(a.tasks[left_index].id, b.tasks[right_index].id);
    }
}

test "determinism oracle compares repeated curated simulator runs" {
    const allocator = std.testing.allocator;
    const corpus = [_][]const u8{
        "short-vs-long",
        "sleep-wakeup",
        "multicore-balancing",
        "deadline-priority",
        "topology-domains",
    };
    const policies = [_]sim.PolicyKind{ .fcfs, .round_robin, .cfs_like, .deadline };

    for (corpus) |scenario_name| {
        var scenario = try sim.loadScenarioByName(allocator, scenario_name);
        defer scenario.deinit();
        for (policies) |policy| {
            var first = try sim.simulate(allocator, &scenario, policy);
            defer first.deinit();
            var second = try sim.simulate(allocator, &scenario, policy);
            defer second.deinit();

            try std.testing.expectEqual(first.final_tick, second.final_tick);
            try std.testing.expectEqual(first.core_count, second.core_count);
            try expectTraceEqual(first.trace, second.trace);
            try expectTaskMetricsEqual(first.tasks, second.tasks);
            try expectCompletionOrderEqual(&first, &second);
        }
    }
}

test "fault injection asserts stable parser diagnostics" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(error.MissingName, sim.parseScenarioText(allocator, "", ""));
    try std.testing.expectError(error.InvalidInteger, sim.parseScenarioText(allocator,
        \\name: bad-integer
        \\task: A now 1
    , "bad-integer"));
    try std.testing.expectError(error.ZeroBurstTicks, sim.parseScenarioText(allocator,
        \\.{
        \\    .name = "zero-burst",
        \\    .tasks = .{
        \\        .{ .id = "A", .arrival_tick = 0, .burst_ticks = 0 },
        \\    },
        \\}
    , "zero-burst"));
    try std.testing.expectError(error.InvalidDeadlineTick, sim.parseScenarioText(allocator,
        \\.{
        \\    .name = "bad-deadline",
        \\    .tasks = .{
        \\        .{ .id = "A", .arrival_tick = 4, .burst_ticks = 3, .deadline_tick = 5 },
        \\    },
        \\}
    , "bad-deadline"));
}

test "quality dashboard keeps gate count and simulator boundary explicit" {
    try std.testing.expectEqual(@as(usize, 10), quality.quality_gates.len);
    var saw_taxonomy = false;
    var saw_quality_dashboard = false;
    for (quality.quality_gates) |gate| {
        if (std.mem.eql(u8, gate.gate, "taxonomy")) saw_taxonomy = true;
        if (std.mem.eql(u8, gate.gate, "quality dashboard")) saw_quality_dashboard = true;
        try std.testing.expect(gate.owner.len != 0);
        try std.testing.expect(gate.command.len != 0);
    }
    try std.testing.expect(saw_taxonomy);
    try std.testing.expect(saw_quality_dashboard);

    const allocator = std.testing.allocator;
    const rendered = try quality.renderMarkdown(allocator);
    defer allocator.free(rendered);
    try expectContainsAll(rendered, &.{
        "zig-scheduler quality dashboard",
        "simulator-lab/product quality",
        "taxonomy",
        "quality dashboard",
        "zig build quality",
    });
}
