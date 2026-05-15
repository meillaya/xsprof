const std = @import("std");
const scheduler = @import("zig_scheduler_internal");

pub const InputSource = union(enum) {
    picker,
    input_file: []const u8,
    stdin_report,
    simulate_builtin: []const u8,
    simulate_file: []const u8,
    observability_default,
    observability_manifest: []const u8,
    comparison_default,
    comparison_pairing: []const u8,
};

pub const RuntimeMode = enum {
    interactive,
    snapshot,
};

pub const default_snapshot_width: u16 = 120;
pub const default_snapshot_height: u16 = 40;

pub const Options = struct {
    input_source: InputSource = .picker,
    runtime_mode: RuntimeMode = .interactive,
    policy: ?scheduler.PolicyKind = null,
    snapshot_width: u16 = default_snapshot_width,
    snapshot_height: u16 = default_snapshot_height,
    snapshot_tick: ?u32 = null,
};

pub fn parseArgs(args: []const []const u8) !Options {
    var options = Options{};
    var saw_snapshot_width = false;
    var saw_snapshot_height = false;
    var saw_snapshot_tick = false;
    var index: usize = 0;

    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--snapshot")) {
            options.runtime_mode = .snapshot;
            continue;
        }
        if (std.mem.eql(u8, arg, "--width")) {
            saw_snapshot_width = true;
            options.snapshot_width = try parseDimension(try nextArg(args, &index));
            continue;
        }
        if (std.mem.eql(u8, arg, "--height")) {
            saw_snapshot_height = true;
            options.snapshot_height = try parseDimension(try nextArg(args, &index));
            continue;
        }
        if (std.mem.eql(u8, arg, "--tick")) {
            saw_snapshot_tick = true;
            options.snapshot_tick = try parseTick(try nextArg(args, &index));
            continue;
        }
        if (std.mem.eql(u8, arg, "--input")) {
            if (options.input_source != .picker) return error.InvalidArguments;
            options.input_source = .{ .input_file = try nextArg(args, &index) };
            continue;
        }
        if (std.mem.eql(u8, arg, "--stdin")) {
            if (options.input_source != .picker) return error.InvalidArguments;
            options.input_source = .stdin_report;
            continue;
        }
        if (std.mem.eql(u8, arg, "--scenario")) {
            if (options.input_source != .picker) return error.InvalidArguments;
            options.input_source = .{ .simulate_builtin = try nextArg(args, &index) };
            continue;
        }
        if (std.mem.eql(u8, arg, "--scenario-file")) {
            if (options.input_source != .picker) return error.InvalidArguments;
            options.input_source = .{ .simulate_file = try nextArg(args, &index) };
            continue;
        }
        if (std.mem.eql(u8, arg, "--observability")) {
            if (options.input_source != .picker) return error.InvalidArguments;
            options.input_source = .observability_default;
            continue;
        }
        if (std.mem.eql(u8, arg, "--observability-manifest")) {
            if (options.input_source != .picker) return error.InvalidArguments;
            options.input_source = .{ .observability_manifest = try nextArg(args, &index) };
            continue;
        }
        if (std.mem.eql(u8, arg, "--comparison")) {
            if (options.input_source != .picker) return error.InvalidArguments;
            options.input_source = .comparison_default;
            continue;
        }
        if (std.mem.eql(u8, arg, "--comparison-pairing")) {
            if (options.input_source != .picker) return error.InvalidArguments;
            options.input_source = .{ .comparison_pairing = try nextArg(args, &index) };
            continue;
        }
        if (std.mem.eql(u8, arg, "--policy")) {
            options.policy = scheduler.cli.parsePolicy(try nextArg(args, &index)) orelse return error.InvalidPolicy;
            continue;
        }
        if (std.mem.eql(u8, arg, "--help")) return error.InvalidArguments;
        return error.InvalidArguments;
    }

    switch (options.input_source) {
        .picker => {
            if (options.policy != null) return error.InvalidArguments;
            if (options.runtime_mode == .snapshot) return error.InvalidArguments;
        },
        .input_file => {
            if (options.policy != null) return error.InvalidArguments;
        },
        .stdin_report => {
            if (options.policy != null) return error.InvalidArguments;
            if (options.runtime_mode != .snapshot) return error.InvalidArguments;
        },
        .simulate_builtin, .simulate_file => {
            if (options.policy == null) return error.InvalidArguments;
        },
        .observability_default, .observability_manifest, .comparison_default, .comparison_pairing => {
            if (options.policy != null) return error.InvalidArguments;
            if (options.snapshot_tick != null) return error.InvalidArguments;
        },
    }

    if (options.runtime_mode != .snapshot and (saw_snapshot_width or saw_snapshot_height or saw_snapshot_tick)) {
        return error.InvalidArguments;
    }

    return options;
}

fn nextArg(args: []const []const u8, index: *usize) ![]const u8 {
    index.* += 1;
    if (index.* >= args.len) return error.InvalidArguments;
    return args[index.*];
}

fn parseDimension(raw: []const u8) !u16 {
    const value = std.fmt.parseUnsigned(u16, raw, 10) catch return error.InvalidArguments;
    if (value == 0) return error.InvalidArguments;
    return value;
}

fn parseTick(raw: []const u8) !u32 {
    return std.fmt.parseUnsigned(u32, raw, 10) catch error.InvalidArguments;
}

test "no args launches interactive picker" {
    const options = try parseArgs(&.{});
    try std.testing.expectEqual(InputSource.picker, options.input_source);
    try std.testing.expectEqual(RuntimeMode.interactive, options.runtime_mode);
    try std.testing.expectEqual(default_snapshot_width, options.snapshot_width);
    try std.testing.expectEqual(default_snapshot_height, options.snapshot_height);
    try std.testing.expectEqual(@as(?u32, null), options.snapshot_tick);
}

test "snapshot parsing stays orthogonal to report and simulation sources" {
    const input_options = try parseArgs(&.{ "--snapshot", "--input", "fixture.report.json", "--width", "132", "--height", "44", "--tick", "7" });
    try std.testing.expectEqual(RuntimeMode.snapshot, input_options.runtime_mode);
    try std.testing.expectEqualStrings("fixture.report.json", input_options.input_source.input_file);
    try std.testing.expectEqual(@as(u16, 132), input_options.snapshot_width);
    try std.testing.expectEqual(@as(u16, 44), input_options.snapshot_height);
    try std.testing.expectEqual(@as(?u32, 7), input_options.snapshot_tick);

    const stdin_options = try parseArgs(&.{ "--stdin", "--snapshot" });
    try std.testing.expectEqual(RuntimeMode.snapshot, stdin_options.runtime_mode);
    try std.testing.expectEqual(InputSource.stdin_report, stdin_options.input_source);

    const builtin_options = try parseArgs(&.{ "--scenario", "short-vs-long", "--policy", "fcfs", "--snapshot" });
    try std.testing.expectEqual(RuntimeMode.snapshot, builtin_options.runtime_mode);
    try std.testing.expectEqualStrings("short-vs-long", builtin_options.input_source.simulate_builtin);
    try std.testing.expectEqual(scheduler.PolicyKind.fcfs, builtin_options.policy.?);

    const file_options = try parseArgs(&.{ "--snapshot", "--scenario-file", "scenarios/basic/group-fairness.zon", "--policy", "cfs-like" });
    try std.testing.expectEqual(RuntimeMode.snapshot, file_options.runtime_mode);
    try std.testing.expectEqualStrings("scenarios/basic/group-fairness.zon", file_options.input_source.simulate_file);
    try std.testing.expectEqual(scheduler.PolicyKind.cfs_like, file_options.policy.?);

    const observability_default_options = try parseArgs(&.{ "--snapshot", "--observability", "--width", "100" });
    try std.testing.expectEqual(RuntimeMode.snapshot, observability_default_options.runtime_mode);
    try std.testing.expectEqual(InputSource.observability_default, observability_default_options.input_source);
    try std.testing.expectEqual(@as(u16, 100), observability_default_options.snapshot_width);

    const observability_manifest_options = try parseArgs(&.{ "--observability-manifest", "fixtures/linux-observability/manifests/tracefs-sched-demo.json" });
    try std.testing.expectEqual(RuntimeMode.interactive, observability_manifest_options.runtime_mode);
    try std.testing.expectEqualStrings("fixtures/linux-observability/manifests/tracefs-sched-demo.json", observability_manifest_options.input_source.observability_manifest);

    const comparison_default_options = try parseArgs(&.{"--comparison"});
    try std.testing.expectEqual(RuntimeMode.interactive, comparison_default_options.runtime_mode);
    try std.testing.expectEqual(InputSource.comparison_default, comparison_default_options.input_source);

    const comparison_pairing_options = try parseArgs(&.{ "--snapshot", "--comparison-pairing", "fixtures/linux-observability/pairings/sleep-wakeup-vs-tracefs-sched-demo.json" });
    try std.testing.expectEqual(RuntimeMode.snapshot, comparison_pairing_options.runtime_mode);
    try std.testing.expectEqualStrings("fixtures/linux-observability/pairings/sleep-wakeup-vs-tracefs-sched-demo.json", comparison_pairing_options.input_source.comparison_pairing);
}

test "interactive report and simulation parsing stays stable" {
    const input_options = try parseArgs(&.{ "--input", "fixture.report.json" });
    try std.testing.expectEqual(RuntimeMode.interactive, input_options.runtime_mode);
    try std.testing.expectEqualStrings("fixture.report.json", input_options.input_source.input_file);

    const builtin_options = try parseArgs(&.{ "--scenario", "short-vs-long", "--policy", "fcfs" });
    try std.testing.expectEqual(RuntimeMode.interactive, builtin_options.runtime_mode);
    try std.testing.expectEqualStrings("short-vs-long", builtin_options.input_source.simulate_builtin);
    try std.testing.expectEqual(scheduler.PolicyKind.fcfs, builtin_options.policy.?);

    const file_options = try parseArgs(&.{ "--scenario-file", "scenarios/basic/group-fairness.zon", "--policy", "cfs-like" });
    try std.testing.expectEqual(RuntimeMode.interactive, file_options.runtime_mode);
    try std.testing.expectEqualStrings("scenarios/basic/group-fairness.zon", file_options.input_source.simulate_file);
    try std.testing.expectEqual(scheduler.PolicyKind.cfs_like, file_options.policy.?);

    const observability_options = try parseArgs(&.{"--observability"});
    try std.testing.expectEqual(RuntimeMode.interactive, observability_options.runtime_mode);
    try std.testing.expectEqual(InputSource.observability_default, observability_options.input_source);

    const comparison_options = try parseArgs(&.{"--comparison"});
    try std.testing.expectEqual(RuntimeMode.interactive, comparison_options.runtime_mode);
    try std.testing.expectEqual(InputSource.comparison_default, comparison_options.input_source);
}

test "invalid snapshot and tty combinations stay rejected" {
    try std.testing.expectError(error.InvalidArguments, parseArgs(&.{"--stdin"}));
    try std.testing.expectError(error.InvalidArguments, parseArgs(&.{"--snapshot"}));
    try std.testing.expectError(error.InvalidArguments, parseArgs(&.{ "--width", "120", "--input", "fixture.report.json" }));
    try std.testing.expectError(error.InvalidArguments, parseArgs(&.{ "--height", "40", "--scenario", "short-vs-long", "--policy", "fcfs" }));
    try std.testing.expectError(error.InvalidArguments, parseArgs(&.{ "--tick", "3", "--scenario", "short-vs-long", "--policy", "fcfs" }));
    try std.testing.expectError(error.InvalidArguments, parseArgs(&.{ "--snapshot", "--width", "0", "--input", "fixture.report.json" }));
    try std.testing.expectError(error.InvalidArguments, parseArgs(&.{ "--snapshot", "--height", "bogus", "--input", "fixture.report.json" }));
    try std.testing.expectError(error.InvalidArguments, parseArgs(&.{ "--snapshot", "--scenario", "short-vs-long" }));
    try std.testing.expectError(error.InvalidPolicy, parseArgs(&.{ "--snapshot", "--scenario", "short-vs-long", "--policy", "bogus" }));
    try std.testing.expectError(error.InvalidArguments, parseArgs(&.{ "--scenario", "short-vs-long", "--scenario-file", "x", "--policy", "fcfs" }));
    try std.testing.expectError(error.InvalidArguments, parseArgs(&.{ "--observability", "--policy", "fcfs" }));
    try std.testing.expectError(error.InvalidArguments, parseArgs(&.{ "--comparison", "--tick", "3", "--snapshot" }));
    try std.testing.expectError(error.InvalidArguments, parseArgs(&.{ "--observability", "--input", "fixture.report.json" }));
    try std.testing.expectError(error.InvalidArguments, parseArgs(&.{ "--comparison", "--scenario-file", "scenarios/basic/group-fairness.zon", "--policy", "fcfs" }));

    const legacy_observability_flag = "--m" ++ "19";
    const legacy_comparison_flag = "--m" ++ "20";
    try std.testing.expectError(error.InvalidArguments, parseArgs(&.{legacy_observability_flag}));
    try std.testing.expectError(error.InvalidArguments, parseArgs(&.{legacy_comparison_flag}));
}
