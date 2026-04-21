const std = @import("std");
const scheduler = @import("zig_scheduler");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const options = try scheduler.cli.parseArgs(args[1..]);

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    switch (options.command) {
        .list => try writeScenarioList(stdout),
        .show => try writeScenarioDetails(stdout, allocator, options.show_name.?),
        .run => try runSimulation(stdout, allocator, options),
    }

    try stdout.flush();
}

fn writeScenarioList(writer: anytype) !void {
    try writer.writeAll("Phase 1 canned scenarios:\n");
    for (scheduler.listBuiltinScenarios()) |entry| {
        try writer.print("  - {s}: {s}\n", .{ entry.key, entry.description });
    }
}

fn writeScenarioDetails(writer: anytype, allocator: std.mem.Allocator, name: []const u8) !void {
    var scenario = try scheduler.loadScenarioByName(allocator, name);
    defer scenario.deinit();

    try writer.print("Scenario: {s}\n", .{scenario.name});
    try writer.print("Round Robin Quantum: {d}\n", .{scenario.round_robin_quantum});
    try writer.writeAll("Tasks:\n");
    for (scenario.tasks) |task| {
        try writer.print(
            "  [{d}] {s}: arrival={d}, burst={d}\n",
            .{ task.input_order, task.id, task.arrival_tick, task.burst_ticks },
        );
    }
}

fn runSimulation(writer: anytype, allocator: std.mem.Allocator, options: scheduler.cli.Options) !void {
    const input_source = options.input_source.?;
    var scenario = try loadScenarioForRun(allocator, input_source);
    defer scenario.deinit();

    if (options.quantum_override) |quantum| {
        scenario.round_robin_quantum = quantum;
    }

    var result = try scheduler.simulate(allocator, &scenario, options.policy.?);
    defer result.deinit();

    const report = scheduler.cli.SimulationReport.init(sourceInfoFromInput(input_source), &scenario, &result);
    switch (options.output_format) {
        .text => try scheduler.cli.writeHumanReport(writer, report),
        .json => try scheduler.cli.writeJsonReport(writer, report),
    }
}

fn loadScenarioForRun(allocator: std.mem.Allocator, input_source: scheduler.cli.InputSource) !scheduler.ScenarioOwned {
    return switch (input_source) {
        .builtin => |name| scheduler.loadScenarioByName(allocator, name),
        .file => |path| scheduler.loadScenarioFile(allocator, path),
    };
}

fn sourceInfoFromInput(input_source: scheduler.cli.InputSource) scheduler.cli.SourceInfo {
    return switch (input_source) {
        .builtin => |name| .{ .kind = .builtin, .value = name },
        .file => |path| .{ .kind = .file, .value = path },
    };
}

test "list command metadata stays stable" {
    const scenarios = scheduler.listBuiltinScenarios();
    try std.testing.expectEqual(@as(usize, 3), scenarios.len);
    try std.testing.expectEqualStrings("staggered-arrivals", scenarios[0].key);
    try std.testing.expectEqualStrings("equal-arrival-contention", scenarios[1].key);
    try std.testing.expectEqualStrings("short-vs-long", scenarios[2].key);
}
