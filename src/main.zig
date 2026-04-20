const std = @import("std");
const sim = @import("zig_scheduler");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    try runCli(allocator, args);
}

fn runCli(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var policy: sim.PolicyKind = .fcfs;
    var scenario_name: ?[]const u8 = null;
    var scenario_file: ?[]const u8 = null;
    var override_quantum: ?u32 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try writeUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--policy")) {
            i += 1;
            if (i >= args.len) return error.MissingPolicyValue;
            policy = sim.PolicyKind.parse(args[i]) orelse return error.InvalidPolicy;
        } else if (std.mem.eql(u8, arg, "--scenario")) {
            i += 1;
            if (i >= args.len) return error.MissingScenarioValue;
            scenario_name = args[i];
        } else if (std.mem.eql(u8, arg, "--scenario-file")) {
            i += 1;
            if (i >= args.len) return error.MissingScenarioFileValue;
            scenario_file = args[i];
        } else if (std.mem.eql(u8, arg, "--quantum")) {
            i += 1;
            if (i >= args.len) return error.MissingQuantumValue;
            override_quantum = try std.fmt.parseInt(u32, args[i], 10);
        } else {
            return error.InvalidArgument;
        }
    }

    var scenario = if (scenario_file) |path|
        try sim.loadScenarioFile(allocator, path)
    else
        try sim.loadScenarioByName(allocator, scenario_name orelse "short-vs-long");
    defer scenario.deinit();

    if (override_quantum) |quantum| {
        if (quantum == 0) return error.InvalidQuantum;
        scenario.round_robin_quantum = quantum;
    }

    var result = try sim.simulate(allocator, &scenario, policy);
    defer result.deinit();

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    try sim.cli.writeSimulationReport(stdout, &scenario, &result);
}

fn writeUsage() !void {
    var stdout_buffer: [2048]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    try stdout.print(
        \\Usage: zig build run -- [--scenario <name> | --scenario-file <path>] [--policy <fcfs|rr|cfs>] [--quantum <ticks>]
        \\
        \\Examples:
        \\  zig build run -- --scenario short-vs-long --policy fcfs
        \\  zig build run -- --scenario equal-arrival-contention --policy rr --quantum 2
        \\  zig build run -- --scenario-file scenarios/basic/staggered-arrivals.zon --policy cfs
        \\
    , .{});
}
