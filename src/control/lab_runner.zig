const std = @import("std");
const commands = @import("commands.zig");
const daemon_support = @import("daemon_support.zig");
const env_builder = @import("env_builder.zig");
const protocol = @import("protocol.zig");
const errors = @import("lab_runner/errors.zig");
const events = @import("lab_runner/events.zig");
const live_summary = @import("lab_runner/live_summary.zig");
const summary = @import("lab_runner/summary.zig");

pub const RunError = errors.RunError;

pub fn runHostSafe(
    allocator: std.mem.Allocator,
    io: std.Io,
    output: *std.ArrayList(u8),
    action: protocol.OperatorAction,
    seq: *usize,
) RunError!void {
    var plan = try commands.buildLabCommand(allocator, action);
    defer plan.deinit(allocator);
    try events.appendEvent(allocator, output, seq, "stage_started", @tagName(action.kind), "queued", "read_only", "", "");

    var env_map = try env_builder.build(allocator, plan.env, false, null);
    defer env_map.deinit();
    const result = try std.process.run(allocator, io, .{
        .argv = plan.args(),
        .environ_map = &env_map,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(256 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const summary_path = try std.fmt.allocPrint(allocator, "{s}/summary.json", .{plan.out_dir});
    defer allocator.free(summary_path);
    if (result.term != .exited or result.term.exited != 0) {
        try events.appendEvent(allocator, output, seq, "incident", @tagName(action.kind), "REFUSE", "incident", "lab harness returned nonzero", summary_path);
        return;
    }
    try summary.appendSummaryStages(allocator, io, output, seq, summary_path);
    try events.appendEvent(allocator, output, seq, "stage_finished", @tagName(action.kind), "PASS", "read_only", "host-safe lab summary captured", summary_path);
}

pub fn runVmFixture(
    allocator: std.mem.Allocator,
    io: std.Io,
    output: *std.ArrayList(u8),
    action: protocol.OperatorAction,
    seq: *usize,
) RunError![]u8 {
    var plan = try commands.buildLabCommand(allocator, action);
    defer plan.deinit(allocator);
    try events.appendEvent(allocator, output, seq, "stage_started", @tagName(action.kind), "queued", "verifier_only", "", "");
    var env_map = try env_builder.build(allocator, plan.env, false, null);
    defer env_map.deinit();
    const result = try std.process.run(allocator, io, .{
        .argv = plan.args(),
        .environ_map = &env_map,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(256 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const summary_path = try std.fmt.allocPrint(allocator, "{s}/summary.json", .{plan.out_dir});
    errdefer allocator.free(summary_path);
    if (result.term != .exited or result.term.exited != 0) {
        try events.appendEvent(allocator, output, seq, "incident", @tagName(action.kind), "REFUSE", "incident", "VM lab harness refused", summary_path);
        return error.InvalidSummary;
    }
    try summary.appendSummaryStages(allocator, io, output, seq, summary_path);
    try events.appendEvent(allocator, output, seq, "stage_finished", @tagName(action.kind), "PASS", "partial_switch_lab", "fixture VM lab summary captured", summary_path);
    return summary_path;
}

pub fn runMicrovmLive(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    output: *std.ArrayList(u8),
    action: protocol.OperatorAction,
    seq: *usize,
    start_events_already_emitted: bool,
    follow_flush: ?*daemon_support.FollowFlush,
) RunError!void {
    var plan = try commands.buildLabCommand(allocator, action);
    defer plan.deinit(allocator);
    if (!start_events_already_emitted) {
        try appendMicrovmLiveStartEventsForPlan(allocator, output, action, seq, plan.out_dir);
    }

    var env_map = try env_builder.build(allocator, plan.env, true, environ);
    defer env_map.deinit();
    var child = try std.process.spawn(io, .{
        .argv = plan.args(),
        .environ_map = &env_map,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer child.kill(io);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_reader = child.stdout.?.readerStreaming(io, &stdout_buffer);
    while (try stdout_reader.interface.takeDelimiter('\n')) |line| {
        if (try live_summary.appendRunnerLifecycleLine(allocator, output, seq, action, line)) {
            if (follow_flush) |flush| try flush.flush(output.items);
        }
    }
    const term = try child.wait(io);

    const summary_path = try std.fmt.allocPrint(allocator, "{s}/summary.json", .{plan.out_dir});
    defer allocator.free(summary_path);
    if (term != .exited or term.exited != 0) {
        try events.appendEvent(allocator, output, seq, "stage_finished", @tagName(action.kind), "REFUSE", "refused_host", "microvm_runner_refused", plan.out_dir);
        return;
    }

    const git_sha = try live_summary.readGitSha(allocator, io);
    defer allocator.free(git_sha);
    live_summary.validateLiveBundle(allocator, io, summary_path, git_sha) catch {
        try events.appendEvent(allocator, output, seq, "incident", @tagName(action.kind), "unsafe_to_assume", "unsafe_to_assume", "live_bundle_rejected", summary_path);
        return;
    };
    try events.appendEvent(allocator, output, seq, "stage_finished", @tagName(action.kind), "PASS", "vm_live_complete", "microvm live bundle accepted", summary_path);
}

pub fn appendMicrovmLiveStartEvents(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    action: protocol.OperatorAction,
    seq: *usize,
) RunError!void {
    var plan = try commands.buildLabCommand(allocator, action);
    defer plan.deinit(allocator);
    try appendMicrovmLiveStartEventsForPlan(allocator, output, action, seq, plan.out_dir);
}

pub fn appendMicrovmLiveStartEventsForPlan(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    action: protocol.OperatorAction,
    seq: *usize,
    out_dir: []const u8,
) RunError!void {
    try events.appendEvent(allocator, output, seq, "stage_started", @tagName(action.kind), "queued", "vm_only_pending", "microvm_live_runner_start", out_dir);
    try events.appendLabActiveEvent(allocator, output, seq, action, out_dir);
    try events.appendEvent(allocator, output, seq, "stage_started", @tagName(action.kind), "active", "microvm_runner_subprocess", "microvm runner subprocess active", out_dir);
}

pub fn runRollbackDrill(
    allocator: std.mem.Allocator,
    io: std.Io,
    output: *std.ArrayList(u8),
    action: protocol.OperatorAction,
    seq: *usize,
) RunError![]u8 {
    var plan = try commands.buildLabCommand(allocator, action);
    defer plan.deinit(allocator);
    try events.appendEvent(allocator, output, seq, "stage_started", @tagName(action.kind), "queued", "rollback_pending", "", "");
    var env_map = try env_builder.build(allocator, plan.env, false, null);
    defer env_map.deinit();
    const result = try std.process.run(allocator, io, .{
        .argv = plan.args(),
        .environ_map = &env_map,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(256 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const summary_path = try std.fmt.allocPrint(allocator, "{s}/summary.json", .{plan.out_dir});
    errdefer allocator.free(summary_path);
    if (result.term != .exited or result.term.exited != 0) {
        try events.appendEvent(allocator, output, seq, "incident", @tagName(action.kind), "unsafe_to_assume", "incident", "rollback drill failed", summary_path);
        return error.InvalidSummary;
    }
    try events.appendEvent(allocator, output, seq, "stage_finished", @tagName(action.kind), "PASS", "rolled_back", "rollback drill summary captured", summary_path);
    return summary_path;
}

pub fn runIncidentDrill(
    allocator: std.mem.Allocator,
    io: std.Io,
    output: *std.ArrayList(u8),
    action: protocol.OperatorAction,
    seq: *usize,
) RunError![]u8 {
    var plan = try commands.buildLabCommand(allocator, action);
    defer plan.deinit(allocator);
    try events.appendEvent(allocator, output, seq, "stage_started", @tagName(action.kind), "queued", "incident", "", "");
    var env_map = try env_builder.build(allocator, plan.env, false, null);
    defer env_map.deinit();
    const result = try std.process.run(allocator, io, .{
        .argv = plan.args(),
        .environ_map = &env_map,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(256 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const summary_path = try std.fmt.allocPrint(allocator, "{s}/summary.json", .{plan.out_dir});
    errdefer allocator.free(summary_path);
    if (result.term != .exited or result.term.exited != 0) {
        try events.appendEvent(allocator, output, seq, "incident", @tagName(action.kind), "unsafe_to_assume", "incident", "incident drill failed", summary_path);
        return error.InvalidSummary;
    }
    try events.appendEvent(allocator, output, seq, "incident", @tagName(action.kind), "INCIDENT", "incident", "verifier_rejection scheduler_exit lost_stream", summary_path);
    try events.appendEvent(allocator, output, seq, "stage_finished", @tagName(action.kind), "PASS", "rolled_back", "incident rollback/fallback summary captured", summary_path);
    return summary_path;
}

test "live microvm start events publish active rollback target before runner blocks" {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    var seq: usize = 1;
    try appendMicrovmLiveStartEvents(std.testing.allocator, &output, .{
        .kind = .run_lab_microvm_live,
        .action_id = "live-active",
        .run_id = "live-active",
        .target_id = "target-live-active",
        .rollback_id = "RB-live-active",
    }, &seq);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"event\":\"lab_run_active\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"action_id\":\"live-active\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"rollback_id\":\"RB-live-active\"") != null);
}

test "lab runner split helper modules are linked" {
    std.testing.refAllDecls(summary);
    std.testing.refAllDecls(live_summary);
}
