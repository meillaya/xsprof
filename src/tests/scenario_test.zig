const std = @import("std");
const scheduler = @import("../lib.zig");

test "builtin golden scenario fixture matches plan inputs" {
    const scenario = try scheduler.loadBuiltinScenario(std.testing.allocator, .short_vs_long);
    defer scheduler.freeScenario(std.testing.allocator, scenario);

    try std.testing.expectEqualStrings("short-vs-long", scenario.name);
    try std.testing.expectEqual(@as(u32, 2), scenario.quantum);
    try std.testing.expectEqual(@as(usize, 3), scenario.tasks.len);

    try expectTask(scenario.tasks[0], "L", 0, 8, 0);
    try expectTask(scenario.tasks[1], "S1", 1, 2, 1);
    try expectTask(scenario.tasks[2], "S2", 2, 1, 2);
}

test "named scenario loader resolves arrivals fixture" {
    const scenario = try scheduler.loadNamedScenario(std.testing.allocator, "arrivals");
    defer scheduler.freeScenario(std.testing.allocator, scenario);

    try std.testing.expectEqualStrings("arrivals", scenario.name);
    try std.testing.expectEqual(@as(usize, 4), scenario.tasks.len);
}

test "duplicate task ids are rejected" {
    const source: [:0]const u8 =
        \\.{
        \\  .name = "duplicate-task-ids",
        \\  .description = "two tasks share the same identifier",
        \\  .quantum = 1,
        \\  .tasks = .{
        \\    .{ .id = "A", .arrival_tick = 0, .burst_ticks = 2 },
        \\    .{ .id = "A", .arrival_tick = 1, .burst_ticks = 1 },
        \\  },
        \\}
    ;

    try std.testing.expectError(
        error.DuplicateTaskId,
        scheduler.parseScenario(std.testing.allocator, source),
    );
}

fn expectTask(
    task: scheduler.TaskSpec,
    expected_id: []const u8,
    expected_arrival: u32,
    expected_burst: u32,
    expected_order: u32,
) !void {
    try std.testing.expectEqualStrings(expected_id, task.id);
    try std.testing.expectEqual(expected_arrival, task.arrival_tick);
    try std.testing.expectEqual(expected_burst, task.burst_ticks);
    try std.testing.expectEqual(expected_order, task.order);
}
