const std = @import("std");
const types = @import("../sim/types.zig");

pub const Command = enum {
    list,
    show,
    run,
};

pub const InputSource = union(enum) {
    builtin: []const u8,
    file: []const u8,
};

pub const OutputFormat = enum {
    text,
    json,
};

pub const Options = struct {
    command: Command = .list,
    show_name: ?[]const u8 = null,
    input_source: ?InputSource = null,
    policy: ?types.PolicyKind = null,
    quantum_override: ?u32 = null,
    output_format: OutputFormat = .text,
};

pub fn parseArgs(args: []const []const u8) !Options {
    var options = Options{};
    if (args.len == 0 or std.mem.eql(u8, args[0], "list")) return options;
    if (std.mem.eql(u8, args[0], "show")) {
        if (args.len != 2) return error.InvalidArguments;
        options.command = .show;
        options.show_name = args[1];
        return options;
    }

    options.command = .run;

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--scenario")) {
            if (options.input_source != null) return error.InvalidArguments;
            options.input_source = .{ .builtin = try nextArg(args, &index) };
            continue;
        }
        if (std.mem.eql(u8, arg, "--scenario-file")) {
            if (options.input_source != null) return error.InvalidArguments;
            options.input_source = .{ .file = try nextArg(args, &index) };
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
        if (std.mem.eql(u8, arg, "--format")) {
            options.output_format = parseFormat(try nextArg(args, &index)) orelse return error.InvalidArguments;
            continue;
        }
        if (std.mem.eql(u8, arg, "--help")) return error.InvalidArguments;
        return error.InvalidArguments;
    }

    if (options.input_source == null or options.policy == null) return error.InvalidArguments;
    return options;
}

fn nextArg(args: []const []const u8, index: *usize) ![]const u8 {
    index.* += 1;
    if (index.* >= args.len) return error.InvalidArguments;
    return args[index.*];
}

fn parseFormat(value: []const u8) ?OutputFormat {
    if (std.mem.eql(u8, value, "text")) return .text;
    if (std.mem.eql(u8, value, "human")) return .text;
    if (std.mem.eql(u8, value, "json")) return .json;
    return null;
}

pub fn parsePolicy(value: []const u8) ?types.PolicyKind {
    if (std.mem.eql(u8, value, "fcfs")) return .fcfs;
    if (std.mem.eql(u8, value, "rr")) return .round_robin;
    if (std.mem.eql(u8, value, "round-robin")) return .round_robin;
    if (std.mem.eql(u8, value, "round_robin")) return .round_robin;
    if (std.mem.eql(u8, value, "cfs")) return .cfs_like;
    if (std.mem.eql(u8, value, "cfs-like")) return .cfs_like;
    if (std.mem.eql(u8, value, "cfs_like")) return .cfs_like;
    return null;
}

test "policy aliases parse" {
    try std.testing.expectEqual(types.PolicyKind.round_robin, parsePolicy("rr").?);
    try std.testing.expectEqual(types.PolicyKind.round_robin, parsePolicy("round-robin").?);
    try std.testing.expectEqual(types.PolicyKind.cfs_like, parsePolicy("cfs-like").?);
    try std.testing.expect(parsePolicy("bogus") == null);
}

test "show command parsing stays stable" {
    const options = try parseArgs(&.{ "show", "short-vs-long" });
    try std.testing.expectEqual(Command.show, options.command);
    try std.testing.expectEqualStrings("short-vs-long", options.show_name.?);
    try std.testing.expect(options.input_source == null);
    try std.testing.expect(options.policy == null);
    try std.testing.expect(options.quantum_override == null);
    try std.testing.expectEqual(OutputFormat.text, options.output_format);
}

test "run command parsing stays stable for builtins" {
    const options = try parseArgs(&.{ "--scenario", "short-vs-long", "--policy", "rr", "--quantum", "2", "--format", "json" });
    try std.testing.expectEqual(Command.run, options.command);
    try std.testing.expectEqualStrings("short-vs-long", options.input_source.?.builtin);
    try std.testing.expectEqual(types.PolicyKind.round_robin, options.policy.?);
    try std.testing.expectEqual(@as(u32, 2), options.quantum_override.?);
    try std.testing.expectEqual(OutputFormat.json, options.output_format);
}

test "run command parsing supports scenario files" {
    const options = try parseArgs(&.{ "--scenario-file", "scenarios/basic/arrivals.zon", "--policy", "fcfs" });
    try std.testing.expectEqual(Command.run, options.command);
    try std.testing.expectEqualStrings("scenarios/basic/arrivals.zon", options.input_source.?.file);
    try std.testing.expectEqual(types.PolicyKind.fcfs, options.policy.?);
    try std.testing.expect(options.quantum_override == null);
    try std.testing.expectEqual(OutputFormat.text, options.output_format);
}

test "invalid argument parsing stays rejected" {
    try std.testing.expectError(error.InvalidArguments, parseArgs(&.{ "show" }));
    try std.testing.expectError(error.InvalidArguments, parseArgs(&.{ "--scenario", "short-vs-long" }));
    try std.testing.expectError(error.InvalidArguments, parseArgs(&.{ "--scenario", "short-vs-long", "--scenario-file", "scenarios/basic/arrivals.zon", "--policy", "fcfs" }));
    try std.testing.expectError(error.InvalidArguments, parseArgs(&.{ "--scenario-file", "scenarios/basic/arrivals.zon", "--policy", "fcfs", "--format", "bogus" }));
    try std.testing.expectError(error.InvalidPolicy, parseArgs(&.{ "--scenario", "short-vs-long", "--policy", "bogus" }));
}
