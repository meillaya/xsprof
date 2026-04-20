const std = @import("std");
const sim = @import("../root.zig");

fn loadShortVsLong(allocator: std.mem.Allocator) !sim.ScenarioOwned {
    return sim.loadScenarioByName(allocator, "short-vs-long");
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
