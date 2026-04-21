const std = @import("std");
const scheduler = @import("../root.zig");

test "builtin golden scenario fixture matches plan inputs" {
    var scenario = try scheduler.loadBuiltinScenario(std.testing.allocator, .short_vs_long);
    defer scenario.deinit();

    try std.testing.expectEqualStrings("short-vs-long", scenario.name);
    try std.testing.expectEqual(@as(u32, 2), scenario.round_robin_quantum);
    try std.testing.expectEqual(@as(usize, 3), scenario.tasks.len);

    try expectTask(scenario.tasks[0], "L", 0, 8, 0);
    try expectTask(scenario.tasks[1], "S1", 1, 2, 1);
    try expectTask(scenario.tasks[2], "S2", 2, 1, 2);
}

test "named scenario loader resolves arrivals fixture" {
    var scenario = try scheduler.loadNamedScenario(std.testing.allocator, "staggered-arrivals");
    defer scenario.deinit();

    try std.testing.expectEqualStrings("staggered-arrivals", scenario.name);
    try std.testing.expectEqual(@as(usize, 3), scenario.tasks.len);
}

test "canonical object style scenario files load by path" {
    var scenario = try scheduler.loadScenarioFile(std.testing.allocator, "scenarios/basic/arrivals.zon");
    defer scenario.deinit();

    try std.testing.expectEqualStrings("arrivals", scenario.name);
    try std.testing.expectEqual(@as(u32, 2), scenario.round_robin_quantum);
    try std.testing.expectEqual(@as(usize, 4), scenario.tasks.len);
    try expectTask(scenario.tasks[0], "A", 0, 5, 0);
    try expectTask(scenario.tasks[3], "D", 6, 1, 3);
}

test "canonical object style scenario files parse task weights" {
    var scenario = try scheduler.loadScenarioFile(std.testing.allocator, "scenarios/basic/weighted-fairness.zon");
    defer scenario.deinit();

    try std.testing.expectEqualStrings("weighted-fairness", scenario.name);
    try std.testing.expectEqual(@as(usize, 3), scenario.tasks.len);
    try expectTaskWithWeight(scenario.tasks[0], "light", 0, 4, 512, 0);
    try expectTaskWithWeight(scenario.tasks[1], "heavy", 0, 4, 2048, 1);
    try expectTaskWithWeight(scenario.tasks[2], "default", 0, 2, scheduler.default_task_weight, 2);
}

test "legacy line oriented scenario text remains supported" {
    const source =
        \\name: legacy-demo
        \\rr_quantum: 3
        \\task: A 0 2
        \\task: B 1 1
        \\
    ;

    var scenario = try scheduler.parseScenarioText(std.testing.allocator, source, "legacy-demo");
    defer scenario.deinit();

    try std.testing.expectEqualStrings("legacy-demo", scenario.name);
    try std.testing.expectEqual(@as(u32, 3), scenario.round_robin_quantum);
    try std.testing.expectEqual(@as(usize, 2), scenario.tasks.len);
    try expectTask(scenario.tasks[0], "A", 0, 2, 0);
    try expectTask(scenario.tasks[1], "B", 1, 1, 1);
}

test "legacy line oriented task weights remain supported as an optional compatibility field" {
    const source =
        \\name: weighted-legacy-demo
        \\rr_quantum: 3
        \\task: A 0 2 2048
        \\task: B 1 1
        \\
    ;

    var scenario = try scheduler.parseScenarioText(std.testing.allocator, source, "weighted-legacy-demo");
    defer scenario.deinit();

    try expectTaskWithWeight(scenario.tasks[0], "A", 0, 2, 2048, 0);
    try expectTaskWithWeight(scenario.tasks[1], "B", 1, 1, scheduler.default_task_weight, 1);
}

test "zero task weight is rejected" {
    const source =
        \\.{
        \\    .name = "invalid-weight",
        \\    .tasks = .{
        \\        .{ .id = "A", .arrival_tick = 0, .burst_ticks = 2, .weight = 0 },
        \\    },
        \\}
    ;

    try std.testing.expectError(
        error.InvalidWeight,
        scheduler.parseScenarioText(std.testing.allocator, source, "invalid-weight"),
    );
}

test "task weights above the supported range are rejected" {
    const source =
        \\.{
        \\    .name = "too-heavy",
        \\    .tasks = .{
        \\        .{ .id = "A", .arrival_tick = 0, .burst_ticks = 2, .weight = 4097 },
        \\    },
        \\}
    ;

    try std.testing.expectError(
        error.InvalidWeight,
        scheduler.parseScenarioText(std.testing.allocator, source, "too-heavy"),
    );
}

test "duplicate task ids are rejected" {
    const source =
        \\name: duplicate-task-ids
        \\rr_quantum: 1
        \\task: A 0 2
        \\task: A 1 1
        \\
    ;

    try std.testing.expectError(
        error.DuplicateTaskId,
        scheduler.parseScenarioText(std.testing.allocator, source, "duplicate-task-ids"),
    );
}

fn expectTask(
    task: scheduler.TaskSpec,
    expected_id: []const u8,
    expected_arrival: u32,
    expected_burst: u32,
    expected_order: u32,
) !void {
    try expectTaskWithWeight(task, expected_id, expected_arrival, expected_burst, scheduler.default_task_weight, expected_order);
}

fn expectTaskWithWeight(
    task: scheduler.TaskSpec,
    expected_id: []const u8,
    expected_arrival: u32,
    expected_burst: u32,
    expected_weight: u32,
    expected_order: u32,
) !void {
    try std.testing.expectEqualStrings(expected_id, task.id);
    try std.testing.expectEqual(expected_arrival, task.arrival_tick);
    try std.testing.expectEqual(expected_burst, task.burst_ticks);
    try std.testing.expectEqual(expected_weight, task.weight);
    try std.testing.expectEqual(expected_order, task.input_order);
}
