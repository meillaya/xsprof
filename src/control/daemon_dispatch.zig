const std = @import("std");
const commands = @import("commands.zig");
const daemon = @import("daemon.zig");
const journal = @import("journal.zig");
const lab_runner = @import("lab_runner.zig");
const protocol = @import("protocol.zig");
const rollback = @import("rollback.zig");
const daemon_support = @import("daemon_support.zig");

pub const FollowFlush = daemon_support.FollowFlush;

pub const readGitSha = daemon_support.readGitSha;

pub fn appendReady(allocator: std.mem.Allocator, output: *std.ArrayList(u8), seq: usize) !void {
    var event: std.ArrayList(u8) = .empty;
    defer event.deinit(allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(allocator, &event);
    try writer.writer.print("{{\"schema\":\"zig-scheduler/daemon-event/v1\",\"seq\":{d},\"event\":\"state_changed\",\"state\":\"read_only\",\"status\":\"ready\",\"host_mutation\":false}}\n", .{seq});
    event = writer.toArrayList();
    try appendEvent(allocator, output, event.items);
}

pub fn appendOverflow(allocator: std.mem.Allocator, output: *std.ArrayList(u8), seq: usize) !void {
    var event: std.ArrayList(u8) = .empty;
    defer event.deinit(allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(allocator, &event);
    try writer.writer.print(
        "{{\"schema\":\"zig-scheduler/daemon-event/v1\",\"seq\":{d},\"event\":\"refusal\",\"state\":\"incident\",\"status\":\"refused\",\"reason\":\"journal_limit_exceeded\",\"host_mutation\":false}}\n",
        .{seq},
    );
    event = writer.toArrayList();
    try appendEvent(allocator, output, event.items);
}

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
        try appendMalformed(allocator, output, seq.*);
        seq.* += 1;
        return;
    };
    defer parsed.deinit();
    if (parsed.value.kind == .run_lab_microvm_live) {
        var validation_plan = commands.buildLabCommand(allocator, parsed.value) catch |err| switch (err) {
            error.InvalidField, error.InvalidAction => {
                try appendInvalidField(allocator, output, parsed.value, seq.*);
                seq.* += 1;
                return;
            },
            else => |e| return e,
        };
        validation_plan.deinit(allocator);
    }
    tracker.remember(allocator, parsed.value.action_id) catch |err| switch (err) {
        error.DuplicateActionId => {
            try appendDuplicate(allocator, output, parsed.value, seq.*);
            seq.* += 1;
            return;
        },
        error.InvalidActionId => {
            try appendInvalidActionId(allocator, output, parsed.value, seq.*);
            seq.* += 1;
            return;
        },
        else => |e| return e,
    };
    if (parsed.value.action_id.len != 0) {
        try appendJournalRecord(allocator, output, parsed.value, git_sha, seq.*);
        seq.* += 1;
    }
    try dispatchParsedAction(allocator, io, environ, output, tracker, state_dir, line, seq, follow_flush, parsed.value);
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
    try appendEvent(allocator, output, event.items);
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
        try appendInvalidField(allocator, output, action, seq.*);
        seq.* += 1;
        return;
    }
    var live_plan = commands.buildLabCommand(allocator, action) catch |err| switch (err) {
        error.InvalidField, error.InvalidAction => {
            try appendInvalidField(allocator, output, action, seq.*);
            seq.* += 1;
            return;
        },
        else => |e| return e,
    };
    defer live_plan.deinit(allocator);
    lab_runner.appendMicrovmLiveStartEventsForPlan(allocator, output, action, seq, live_plan.out_dir) catch |err| switch (err) {
        error.InvalidField, error.InvalidAction => {
            try appendInvalidField(allocator, output, action, seq.*);
            seq.* += 1;
            return;
        },
        else => |e| return e,
    };
    try tracker.recordLab(allocator, action.action_id, action.rollback_id, live_plan.out_dir);
    try follow_flush.flush(output.items);
    try state_dir.writeFile(io, .{ .sub_path = "events.jsonl", .data = output.items });
    lab_runner.runMicrovmLive(allocator, io, environ, output, action, seq, true) catch |err| switch (err) {
        error.InvalidField, error.InvalidAction => {
            try appendInvalidField(allocator, output, action, seq.*);
            seq.* += 1;
            return;
        },
        else => |e| return e,
    };
    try follow_flush.flush(output.items);
}

fn appendJournalRecord(allocator: std.mem.Allocator, output: *std.ArrayList(u8), action: protocol.OperatorAction, git_sha: []const u8, seq: usize) !void {
    var event: std.ArrayList(u8) = .empty;
    defer event.deinit(allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(allocator, &event);
    try journal.writeRecord(&writer.writer, seq, action, git_sha);
    event = writer.toArrayList();
    try appendEvent(allocator, output, event.items);
}

fn appendDuplicate(allocator: std.mem.Allocator, output: *std.ArrayList(u8), action: protocol.OperatorAction, seq: usize) !void {
    var event: std.ArrayList(u8) = .empty;
    defer event.deinit(allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(allocator, &event);
    try journal.writeDuplicateRefusal(&writer.writer, seq, action);
    event = writer.toArrayList();
    try appendEvent(allocator, output, event.items);
}

fn appendInvalidActionId(allocator: std.mem.Allocator, output: *std.ArrayList(u8), action: protocol.OperatorAction, seq: usize) !void {
    var event: std.ArrayList(u8) = .empty;
    defer event.deinit(allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(allocator, &event);
    try journal.writeInvalidActionIdRefusal(&writer.writer, seq, action);
    event = writer.toArrayList();
    try appendEvent(allocator, output, event.items);
}

fn appendInvalidField(allocator: std.mem.Allocator, output: *std.ArrayList(u8), action: protocol.OperatorAction, seq: usize) !void {
    var event: std.ArrayList(u8) = .empty;
    defer event.deinit(allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(allocator, &event);
    try writer.writer.print(
        "{{\"schema\":\"zig-scheduler/daemon-event/v1\",\"seq\":{d},\"event\":\"refusal\",\"action\":\"{s}\",\"action_id\":",
        .{ seq, @tagName(action.kind) },
    );
    try writeJsonString(&writer.writer, action.action_id);
    try writer.writer.writeAll(",\"state\":\"refused_host\",\"status\":\"refused\",\"reason\":\"invalid_field\",\"host_mutation\":false}\n");
    event = writer.toArrayList();
    try appendEvent(allocator, output, event.items);
}

fn appendMalformed(allocator: std.mem.Allocator, output: *std.ArrayList(u8), seq: usize) !void {
    var event: std.ArrayList(u8) = .empty;
    defer event.deinit(allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(allocator, &event);
    try daemon.writeActionResult(&writer.writer, allocator, "{not-json", seq);
    event = writer.toArrayList();
    try appendEvent(allocator, output, event.items);
}

fn appendEvent(allocator: std.mem.Allocator, output: *std.ArrayList(u8), event: []const u8) !void {
    try daemon.ensureCanWriteEvent(output.items.len, event);
    try output.appendSlice(allocator, event);
}

fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |byte| switch (byte) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => if (byte < 0x20) try writer.print("\\u{x:0>4}", .{byte}) else try writer.writeByte(byte),
    };
    try writer.writeByte('"');
}
