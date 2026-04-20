const std = @import("std");
const scheduler = @import("zig_scheduler");

const Command = enum {
    list,
    show,
    run,
};

const Options = struct {
    command: Command = .list,
    scenario_name: ?[]const u8 = null,
    policy: ?scheduler.PolicyKind = null,
    quantum_override: ?u32 = null,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const options = try parseArgs(args[1..]);

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    switch (options.command) {
        .list => try writeScenarioList(stdout),
        .show => try writeScenarioDetails(stdout, allocator, options.scenario_name.?),
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

fn runSimulation(writer: anytype, allocator: std.mem.Allocator, options: Options) !void {
    var scenario = try scheduler.loadScenarioByName(allocator, options.scenario_name.?);
    defer scenario.deinit();

    if (options.quantum_override) |quantum| {
        scenario.round_robin_quantum = quantum;
    }

    var result = try scheduler.simulate(allocator, &scenario, options.policy.?);
    defer result.deinit();

    try scheduler.cli.writeSimulationReport(writer, &scenario, &result);
}

fn parseArgs(args: []const []const u8) !Options {
    var options = Options{};
    if (args.len == 0 or std.mem.eql(u8, args[0], "list")) return options;
    if (std.mem.eql(u8, args[0], "show")) {
        if (args.len != 2) return error.InvalidArguments;
        options.command = .show;
        options.scenario_name = args[1];
        return options;
    }

    options.command = .run;

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--scenario")) {
            options.scenario_name = try nextArg(args, &index);
            continue;
        }
        if (std.mem.eql(u8, arg, "--policy")) {
            options.policy = parsePolicy(try nextArg(args, &index)) orelse return error.InvalidPolicy;
            continue;
        }
        if (std.mem.eql(u8, arg, "--quantum")) {
            options.quantum_override = std.fmt.parseInt(u32, try nextArg(args, &index), 10) catch return error.InvalidArguments;
            continue;
        }
        if (std.mem.eql(u8, arg, "--help")) return error.InvalidArguments;
        return error.InvalidArguments;
    }

    if (options.scenario_name == null or options.policy == null) return error.InvalidArguments;
    return options;
}

fn nextArg(args: []const []const u8, index: *usize) ![]const u8 {
    index.* += 1;
    if (index.* >= args.len) return error.InvalidArguments;
    return args[index.*];
}

fn parsePolicy(value: []const u8) ?scheduler.PolicyKind {
    if (std.mem.eql(u8, value, "fcfs")) return .fcfs;
    if (std.mem.eql(u8, value, "rr")) return .round_robin;
    if (std.mem.eql(u8, value, "round-robin")) return .round_robin;
    if (std.mem.eql(u8, value, "round_robin")) return .round_robin;
    if (std.mem.eql(u8, value, "cfs")) return .cfs_like;
    if (std.mem.eql(u8, value, "cfs-like")) return .cfs_like;
    if (std.mem.eql(u8, value, "cfs_like")) return .cfs_like;
    return null;
}

test "list command metadata stays stable" {
    const scenarios = scheduler.listBuiltinScenarios();
    try std.testing.expectEqual(@as(usize, 3), scenarios.len);
    try std.testing.expectEqualStrings("staggered-arrivals", scenarios[0].key);
    try std.testing.expectEqualStrings("equal-arrival-contention", scenarios[1].key);
    try std.testing.expectEqualStrings("short-vs-long", scenarios[2].key);
}

test "policy aliases parse" {
    try std.testing.expectEqual(scheduler.PolicyKind.round_robin, parsePolicy("rr").?);
    try std.testing.expectEqual(scheduler.PolicyKind.round_robin, parsePolicy("round-robin").?);
    try std.testing.expectEqual(scheduler.PolicyKind.cfs_like, parsePolicy("cfs-like").?);
    try std.testing.expect(parsePolicy("bogus") == null);
}

test "show command parsing stays stable" {
    const options = try parseArgs(&.{ "show", "short-vs-long" });
    try std.testing.expectEqual(Command.show, options.command);
    try std.testing.expectEqualStrings("short-vs-long", options.scenario_name.?);
    try std.testing.expect(options.policy == null);
    try std.testing.expect(options.quantum_override == null);
}

test "run command parsing stays stable" {
    const options = try parseArgs(&.{ "--scenario", "short-vs-long", "--policy", "rr", "--quantum", "2" });
    try std.testing.expectEqual(Command.run, options.command);
    try std.testing.expectEqualStrings("short-vs-long", options.scenario_name.?);
    try std.testing.expectEqual(scheduler.PolicyKind.round_robin, options.policy.?);
    try std.testing.expectEqual(@as(u32, 2), options.quantum_override.?);
}

test "invalid argument parsing stays rejected" {
    try std.testing.expectError(error.InvalidArguments, parseArgs(&.{ "show" }));
    try std.testing.expectError(error.InvalidArguments, parseArgs(&.{ "--scenario", "short-vs-long" }));
    try std.testing.expectError(error.InvalidPolicy, parseArgs(&.{ "--scenario", "short-vs-long", "--policy", "bogus" }));
}
