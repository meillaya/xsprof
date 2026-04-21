const std = @import("std");
const scheduler = @import("zig_scheduler");

pub const LaunchMode = enum {
    picker,
    input_file,
    stdin_report,
    simulate_builtin,
    simulate_file,
};

pub const Options = struct {
    mode: LaunchMode = .picker,
    input_path: ?[]const u8 = null,
    scenario_name: ?[]const u8 = null,
    scenario_file: ?[]const u8 = null,
    policy: ?scheduler.PolicyKind = null,
};

pub fn parseArgs(args: []const []const u8) !Options {
    var options = Options{};
    var index: usize = 0;

    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--input")) {
            if (options.mode != .picker) return error.InvalidArguments;
            options.mode = .input_file;
            options.input_path = try nextArg(args, &index);
            continue;
        }
        if (std.mem.eql(u8, arg, "--stdin")) {
            if (options.mode != .picker) return error.InvalidArguments;
            options.mode = .stdin_report;
            continue;
        }
        if (std.mem.eql(u8, arg, "--scenario")) {
            if (options.mode != .picker) return error.InvalidArguments;
            options.mode = .simulate_builtin;
            options.scenario_name = try nextArg(args, &index);
            continue;
        }
        if (std.mem.eql(u8, arg, "--scenario-file")) {
            if (options.mode != .picker) return error.InvalidArguments;
            options.mode = .simulate_file;
            options.scenario_file = try nextArg(args, &index);
            continue;
        }
        if (std.mem.eql(u8, arg, "--policy")) {
            options.policy = scheduler.cli.parsePolicy(try nextArg(args, &index)) orelse return error.InvalidPolicy;
            continue;
        }
        if (std.mem.eql(u8, arg, "--help")) return error.InvalidArguments;
        return error.InvalidArguments;
    }

    switch (options.mode) {
        .picker => {
            if (options.policy != null) return error.InvalidArguments;
        },
        .input_file, .stdin_report => {
            if (options.policy != null) return error.InvalidArguments;
        },
        .simulate_builtin, .simulate_file => {
            if (options.policy == null) return error.InvalidArguments;
        },
    }

    return options;
}

fn nextArg(args: []const []const u8, index: *usize) ![]const u8 {
    index.* += 1;
    if (index.* >= args.len) return error.InvalidArguments;
    return args[index.*];
}

test "no args launches picker" {
    const options = try parseArgs(&.{});
    try std.testing.expectEqual(LaunchMode.picker, options.mode);
}

test "input report path parses" {
    const options = try parseArgs(&.{ "--input", "fixture.report.json" });
    try std.testing.expectEqual(LaunchMode.input_file, options.mode);
    try std.testing.expectEqualStrings("fixture.report.json", options.input_path.?);
}

test "stdin report parses" {
    const options = try parseArgs(&.{"--stdin"});
    try std.testing.expectEqual(LaunchMode.stdin_report, options.mode);
}

test "scenario simulation parses" {
    const options = try parseArgs(&.{ "--scenario", "short-vs-long", "--policy", "fcfs" });
    try std.testing.expectEqual(LaunchMode.simulate_builtin, options.mode);
    try std.testing.expectEqualStrings("short-vs-long", options.scenario_name.?);
    try std.testing.expectEqual(scheduler.PolicyKind.fcfs, options.policy.?);
}

test "scenario file simulation parses" {
    const options = try parseArgs(&.{ "--scenario-file", "scenarios/basic/group-fairness.zon", "--policy", "cfs-like" });
    try std.testing.expectEqual(LaunchMode.simulate_file, options.mode);
    try std.testing.expectEqualStrings("scenarios/basic/group-fairness.zon", options.scenario_file.?);
    try std.testing.expectEqual(scheduler.PolicyKind.cfs_like, options.policy.?);
}

test "invalid combinations stay rejected" {
    try std.testing.expectError(error.InvalidArguments, parseArgs(&.{ "--input", "fixture.report.json", "--policy", "fcfs" }));
    try std.testing.expectError(error.InvalidArguments, parseArgs(&.{ "--stdin", "--policy", "fcfs" }));
    try std.testing.expectError(error.InvalidArguments, parseArgs(&.{ "--scenario", "short-vs-long" }));
    try std.testing.expectError(error.InvalidPolicy, parseArgs(&.{ "--scenario", "short-vs-long", "--policy", "bogus" }));
    try std.testing.expectError(error.InvalidArguments, parseArgs(&.{ "--scenario", "short-vs-long", "--scenario-file", "x", "--policy", "fcfs" }));
}
