const std = @import("std");
const scheduler = @import("zig_scheduler_internal");

pub fn runWithArgs(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const options = try scheduler.cli.parseArgs(args);

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

pub fn writeUsage(writer: anytype, exe_name: []const u8) !void {
    try writer.print(
        "usage: {s} [list | show <scenario-name> | --scenario <name> --policy <policy> [--quantum <ticks>] [--format text|json] | --scenario-file <path> --policy <policy> [--quantum <ticks>] [--format text|json]]\n",
        .{exe_name},
    );
}

fn writeScenarioList(writer: anytype) !void {
    try writer.writeAll("Phase 1 scenario packs:\n");
    for (scheduler.scenario_packs.listScenarioPacks()) |pack| {
        try writer.print("Pack {s} ({s})\n", .{ pack.key, pack.directory });
        for (pack.scenarios) |entry| {
            try writer.print("  - {s} [{s}:{s}]: {s}\n", .{ entry.key, pack.key, entry.key, entry.description });
        }
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

test "list command exposes scenario pack registry layout" {
    const allocator = std.testing.allocator;
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);
    var writer = buffer.writer(allocator);

    try writeScenarioList(&writer);

    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "Phase 1 scenario packs:") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "Pack core/basic (scenarios/basic)") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "short-vs-long [core/basic:short-vs-long]") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "starvation-pressure [core/basic:starvation-pressure]") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "topology-domains [core/basic:topology-domains]") != null);
}

test "usage text advertises sim entrypoint" {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);
    var writer = buffer.writer(std.testing.allocator);
    try writeUsage(&writer, "zig-scheduler sim");
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "zig-scheduler sim") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "--scenario-file <path>") != null);
}
