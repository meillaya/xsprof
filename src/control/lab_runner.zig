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

pub const MicrovmLiveResult = struct {
    lifecycle_events: usize = 0,
    rollback_seen: bool = false,
    cleanup_seen: bool = false,
    incident_seen: bool = false,
};

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
) RunError!MicrovmLiveResult {
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

    var live_result = MicrovmLiveResult{};
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_reader = child.stdout.?.readerStreaming(io, &stdout_buffer);
    while (try stdout_reader.interface.takeDelimiter('\n')) |line| {
        const line_info = live_summary.appendRunnerLifecycleLine(allocator, output, seq, action, line) catch {
            try events.appendEvent(allocator, output, seq, "incident", @tagName(action.kind), "unsafe_to_assume", "unsafe_to_assume", "malformed_runner_event", plan.out_dir);
            live_result.lifecycle_events += 1;
            live_result.incident_seen = true;
            if (follow_flush) |flush| try flush.flush(output.items);
            continue;
        };
        switch (line_info.kind) {
            .ignored => {},
            .rollback => {
                live_result.lifecycle_events += 1;
                live_result.rollback_seen = live_result.rollback_seen or line_info.clears_active;
                live_result.incident_seen = live_result.incident_seen or line_info.incident_terminal;
                if (follow_flush) |flush| try flush.flush(output.items);
            },
            .cleanup => {
                live_result.lifecycle_events += 1;
                live_result.cleanup_seen = live_result.cleanup_seen or line_info.clears_active;
                live_result.incident_seen = live_result.incident_seen or line_info.incident_terminal;
                if (follow_flush) |flush| try flush.flush(output.items);
            },
            .incident => {
                live_result.lifecycle_events += 1;
                live_result.incident_seen = true;
                if (follow_flush) |flush| try flush.flush(output.items);
            },
            else => {
                live_result.lifecycle_events += 1;
                live_result.incident_seen = live_result.incident_seen or line_info.incident_terminal;
                if (follow_flush) |flush| try flush.flush(output.items);
            },
        }
    }
    const term = try child.wait(io);

    const summary_path = try std.fmt.allocPrint(allocator, "{s}/summary.json", .{plan.out_dir});
    defer allocator.free(summary_path);
    if (live_result.lifecycle_events == 0) {
        try events.appendEvent(allocator, output, seq, "incident", @tagName(action.kind), "unsafe_to_assume", "unsafe_to_assume", "lost_stream", plan.out_dir);
        live_result.incident_seen = true;
        if (follow_flush) |flush| try flush.flush(output.items);
    }
    if (term != .exited or term.exited != 0) {
        try events.appendEvent(allocator, output, seq, "stage_finished", @tagName(action.kind), "REFUSE", "refused_host", "microvm_runner_refused", plan.out_dir);
        return live_result;
    }
    if (live_result.incident_seen) {
        try events.appendEvent(allocator, output, seq, "stage_finished", @tagName(action.kind), "INCIDENT", "unsafe_to_assume", "microvm_runner_incident", plan.out_dir);
        return live_result;
    }

    const git_sha = try live_summary.readGitSha(allocator, io);
    defer allocator.free(git_sha);
    live_summary.validateLiveBundle(allocator, io, summary_path, git_sha) catch {
        try events.appendEvent(allocator, output, seq, "incident", @tagName(action.kind), "unsafe_to_assume", "unsafe_to_assume", "live_bundle_rejected", summary_path);
        live_result.incident_seen = true;
        try events.appendEvent(allocator, output, seq, "stage_finished", @tagName(action.kind), "INCIDENT", "unsafe_to_assume", "live_bundle_rejected", summary_path);
        return live_result;
    };
    try events.appendEvent(allocator, output, seq, "stage_finished", @tagName(action.kind), "PASS", "vm_live_complete", "microvm live bundle accepted", summary_path);
    return live_result;
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
    try events.appendEvent(allocator, output, seq, "stage_finished", @tagName(action.kind), "INCIDENT", "incident", "incident rollback/fallback summary captured", summary_path);
    return summary_path;
}

test "lab runner behavior tests are linked" {
    std.testing.refAllDecls(@import("lab_runner_tests.zig"));
    std.testing.refAllDecls(summary);
    std.testing.refAllDecls(live_summary);
}
