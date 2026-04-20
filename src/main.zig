const std = @import("std");
const scheduler = @import("zig_scheduler");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    if (args.len <= 1 or std.mem.eql(u8, args[1], "list")) {
        try writeScenarioList(stdout);
        try stdout.flush();
        return;
    }

    if (args.len == 3 and std.mem.eql(u8, args[1], "show")) {
        const scenario = try scheduler.loadNamedScenario(allocator, args[2]);
        defer scheduler.freeScenario(allocator, scenario);

        try stdout.print("Scenario: {s}\n", .{scenario.name});
        try stdout.print("Description: {s}\n", .{scenario.description});
        try stdout.print("Quantum: {}\n", .{scenario.quantum});
        try stdout.writeAll("Tasks:\n");
        for (scenario.tasks) |task| {
            try stdout.print(
                "  [{d}] {s}: arrival={d}, burst={d}\n",
                .{ task.order, task.id, task.arrival_tick, task.burst_ticks },
            );
        }
        try stdout.flush();
        return;
    }

    try stdout.writeAll(
        \\Usage:
        \\  zig build run -- list
        \\  zig build run -- show <scenario-name>
        \\
    );
    try stdout.flush();
}

fn writeScenarioList(writer: anytype) !void {
    try writer.writeAll("Phase 1 canned scenarios:\n");
    for (scheduler.listBuiltinScenarios()) |entry| {
        try writer.print("  - {s}: {s}\n", .{ entry.key, entry.description });
    }
}

test "list command metadata stays stable" {
    const scenarios = scheduler.listBuiltinScenarios();
    try std.testing.expectEqual(@as(usize, 3), scenarios.len);
    try std.testing.expectEqualStrings("arrivals", scenarios[0].key);
    try std.testing.expectEqualStrings("contention", scenarios[1].key);
    try std.testing.expectEqualStrings("short-vs-long", scenarios[2].key);
}
