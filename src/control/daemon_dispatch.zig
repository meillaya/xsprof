const std = @import("std");
const commands = @import("commands.zig");
const daemon = @import("daemon.zig");
const daemon_events = @import("daemon_events.zig");
const journal = @import("journal.zig");
const lab_runner = @import("lab_runner.zig");
const protocol = @import("protocol.zig");
const rollback = @import("rollback.zig");
const daemon_support = @import("daemon_support.zig");

pub const FollowFlush = daemon_support.FollowFlush;

pub const readGitSha = daemon_support.readGitSha;

pub const appendReady = daemon_events.appendReady;
pub const appendOverflow = daemon_events.appendOverflow;

pub fn appendAction(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    output: *std.ArrayList(u8),
    tracker: *journal.Tracker,
    state_dir: *std.Io.Dir,
    git_sha: []const u8,
    line: []const u8,
    seq: *usize,
    follow_flush: *FollowFlush,
) !void {
    var parsed = protocol.parseActionJson(allocator, std.mem.trim(u8, line, " \t\r\n")) catch {
        try daemon_events.appendMalformed(allocator, output, seq.*);
        seq.* += 1;
        return;
    };
    defer parsed.deinit();
    if (parsed.value.kind == .run_lab_microvm_live) {
        var validation_plan = commands.buildLabCommand(allocator, parsed.value) catch |err| switch (err) {
            error.InvalidField, error.InvalidAction => {
                try daemon_events.appendInvalidField(allocator, output, parsed.value, seq.*);
                seq.* += 1;
                return;
            },
            else => |e| return e,
        };
        validation_plan.deinit(allocator);
    }
    tracker.remember(allocator, parsed.value.action_id) catch |err| switch (err) {
        error.DuplicateActionId => {
            try daemon_events.appendDuplicate(allocator, output, parsed.value, seq.*);
            seq.* += 1;
            return;
        },
        error.InvalidActionId => {
            try daemon_events.appendInvalidActionId(allocator, output, parsed.value, seq.*);
            seq.* += 1;
            return;
        },
        else => |e| return e,
    };
    if (targetOwningRunRequiresTarget(parsed.value.kind) and parsed.value.target_id.len == 0) {
        try daemon_events.appendTargetRefusal(allocator, output, parsed.value, seq.*, "target_id_required");
        seq.* += 1;
        return;
    }
    if (targetOwningRunRequiresTarget(parsed.value.kind) and tracker.activeTarget(parsed.value.target_id)) {
        try daemon_events.appendDuplicateTarget(allocator, output, parsed.value, seq.*);
        seq.* += 1;
        return;
    }
    if (rollback.isRollbackAction(parsed.value.kind)) {
        if (parsed.value.target_action_id.len == 0 or parsed.value.rollback_id.len == 0) {
            try daemon_events.appendTargetRefusal(allocator, output, parsed.value, seq.*, "target_action_id_and_rollback_id_required");
            seq.* += 1;
            return;
        }
        const lab = tracker.findLab(parsed.value.target_action_id) orelse {
            try daemon_events.appendTargetRefusal(allocator, output, parsed.value, seq.*, "stale_target");
            seq.* += 1;
            return;
        };
        if (!std.mem.eql(u8, lab.rollback_id, parsed.value.rollback_id)) {
            try daemon_events.appendTargetRefusal(allocator, output, parsed.value, seq.*, "stale_rollback_id");
            seq.* += 1;
            return;
        }
    }
    if (parsed.value.action_id.len != 0) {
        try daemon_events.appendJournalRecord(allocator, output, parsed.value, git_sha, seq.*);
        seq.* += 1;
    }
    try dispatchParsedAction(allocator, io, environ, output, tracker, state_dir, line, seq, follow_flush, parsed.value);
}

fn targetOwningRunRequiresTarget(kind: protocol.ActionKind) bool {
    return kind == .run_lab_vm or kind == .run_lab_microvm_live;
}

fn dispatchParsedAction(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    output: *std.ArrayList(u8),
    tracker: *journal.Tracker,
    state_dir: *std.Io.Dir,
    line: []const u8,
    seq: *usize,
    follow_flush: *FollowFlush,
    action: protocol.OperatorAction,
) !void {
    if (action.kind == .run_lab_host_safe) {
        try lab_runner.runHostSafe(allocator, io, output, action, seq);
        return;
    }
    if (action.kind == .run_lab_vm) {
        try rollback.handleRunLabVm(allocator, io, output, tracker, action, seq);
        return;
    }
    if (action.kind == .run_lab_microvm_live) {
        try dispatchLiveMicrovmAction(allocator, io, environ, output, tracker, state_dir, seq, follow_flush, action);
        return;
    }
    if (rollback.isRollbackAction(action.kind)) {
        try rollback.handleRollback(allocator, io, output, tracker, action, seq);
        return;
    }
    if (action.kind == .incident_drill) {
        const summary_path = try lab_runner.runIncidentDrill(allocator, io, output, action, seq);
        allocator.free(summary_path);
        return;
    }

    var event: std.ArrayList(u8) = .empty;
    defer event.deinit(allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(allocator, &event);
    try daemon.writeActionResult(&writer.writer, allocator, line, seq.*);
    event = writer.toArrayList();
    try daemon_events.appendEvent(allocator, output, event.items);
    seq.* += 1;
}

fn dispatchLiveMicrovmAction(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    output: *std.ArrayList(u8),
    tracker: *journal.Tracker,
    state_dir: *std.Io.Dir,
    seq: *usize,
    follow_flush: *FollowFlush,
    action: protocol.OperatorAction,
) !void {
    if (action.action_id.len == 0 or action.rollback_id.len == 0) {
        try daemon_events.appendInvalidField(allocator, output, action, seq.*);
        seq.* += 1;
        return;
    }
    var live_plan = commands.buildLabCommand(allocator, action) catch |err| switch (err) {
        error.InvalidField, error.InvalidAction => {
            try daemon_events.appendInvalidField(allocator, output, action, seq.*);
            seq.* += 1;
            return;
        },
        else => |e| return e,
    };
    defer live_plan.deinit(allocator);
    lab_runner.appendMicrovmLiveStartEventsForPlan(allocator, output, action, seq, live_plan.out_dir) catch |err| switch (err) {
        error.InvalidField, error.InvalidAction => {
            try daemon_events.appendInvalidField(allocator, output, action, seq.*);
            seq.* += 1;
            return;
        },
        else => |e| return e,
    };
    tracker.recordLab(allocator, action.action_id, action.target_id, action.rollback_id, live_plan.out_dir) catch |err| switch (err) {
        error.DuplicateTargetId => {
            try daemon_events.appendDuplicateTarget(allocator, output, action, seq.*);
            seq.* += 1;
            return;
        },
        else => |e| return e,
    };
    try follow_flush.flush(output.items);
    try state_dir.writeFile(io, .{ .sub_path = "events.jsonl", .data = output.items });
    const live_result = lab_runner.runMicrovmLive(allocator, io, environ, output, action, seq, true, follow_flush) catch |err| switch (err) {
        error.InvalidField, error.InvalidAction => {
            try daemon_events.appendInvalidField(allocator, output, action, seq.*);
            seq.* += 1;
            return;
        },
        else => |e| return e,
    };
    if (live_result.rollback_seen or live_result.cleanup_seen) {
        try tracker.markRolledBack(allocator, action.action_id, live_plan.out_dir);
    }
    try follow_flush.flush(output.items);
}
