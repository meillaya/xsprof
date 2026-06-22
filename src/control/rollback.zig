const std = @import("std");
const daemon = @import("daemon.zig");
const journal = @import("journal.zig");
const lab_runner = @import("lab_runner.zig");
const protocol = @import("protocol.zig");

pub fn isRollbackAction(kind: protocol.ActionKind) bool {
    return kind == .rollback_lab_run or kind == .stop_lab_run or kind == .rollback or kind == .stop;
}

pub fn handleRunLabVm(
    allocator: std.mem.Allocator,
    io: std.Io,
    output: *std.ArrayList(u8),
    tracker: *journal.Tracker,
    action: protocol.OperatorAction,
    seq: *usize,
) !void {
    if (action.action_id.len == 0 or action.rollback_id.len == 0) {
        try appendTargetRefusal(allocator, output, action, seq.*, "lab_action_id_and_rollback_id_required");
        seq.* += 1;
        return;
    }
    if (action.target_id.len == 0) {
        try appendTargetRefusal(allocator, output, action, seq.*, "target_id_required");
        seq.* += 1;
        return;
    }
    const summary_path = try lab_runner.runVmFixture(allocator, io, output, action, seq);
    defer allocator.free(summary_path);
    try tracker.recordLab(allocator, action.action_id, action.target_id, action.rollback_id, summary_path);
    try appendLabActive(allocator, output, action, summary_path, seq.*);
    seq.* += 1;
}

pub fn handleRollback(
    allocator: std.mem.Allocator,
    io: std.Io,
    output: *std.ArrayList(u8),
    tracker: *journal.Tracker,
    action: protocol.OperatorAction,
    seq: *usize,
) !void {
    if (action.target_action_id.len == 0 or action.rollback_id.len == 0) {
        try appendTargetRefusal(allocator, output, action, seq.*, "target_action_id_and_rollback_id_required");
        seq.* += 1;
        return;
    }
    const lab = tracker.findLab(action.target_action_id) orelse {
        try appendTargetRefusal(allocator, output, action, seq.*, "stale_target");
        seq.* += 1;
        return;
    };
    if (!std.mem.eql(u8, lab.rollback_id, action.rollback_id)) {
        try appendTargetRefusal(allocator, output, action, seq.*, "stale_rollback_id");
        seq.* += 1;
        return;
    }
    if (lab.status == .rolled_back) {
        try appendRollbackCompleted(allocator, output, action, lab.artifact, true, seq.*);
        seq.* += 1;
        return;
    }
    const summary_path = try lab_runner.runRollbackDrill(allocator, io, output, action, seq);
    defer allocator.free(summary_path);
    try tracker.markRolledBack(allocator, action.target_action_id, summary_path);
    try appendRollbackCompleted(allocator, output, action, summary_path, false, seq.*);
    seq.* += 1;
}

fn appendLabActive(allocator: std.mem.Allocator, output: *std.ArrayList(u8), action: protocol.OperatorAction, artifact: []const u8, seq: usize) !void {
    var event: std.ArrayList(u8) = .empty;
    defer event.deinit(allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(allocator, &event);
    try journal.writeLabActive(&writer.writer, seq, action, artifact);
    event = writer.toArrayList();
    try appendEvent(allocator, output, event.items);
}

fn appendRollbackCompleted(allocator: std.mem.Allocator, output: *std.ArrayList(u8), action: protocol.OperatorAction, artifact: []const u8, idempotent: bool, seq: usize) !void {
    var event: std.ArrayList(u8) = .empty;
    defer event.deinit(allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(allocator, &event);
    try journal.writeRollbackCompleted(&writer.writer, seq, action, artifact, idempotent);
    event = writer.toArrayList();
    try appendEvent(allocator, output, event.items);
}

fn appendTargetRefusal(allocator: std.mem.Allocator, output: *std.ArrayList(u8), action: protocol.OperatorAction, seq: usize, reason: []const u8) !void {
    var event: std.ArrayList(u8) = .empty;
    defer event.deinit(allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(allocator, &event);
    try journal.writeTargetRefusal(&writer.writer, seq, action, reason);
    event = writer.toArrayList();
    try appendEvent(allocator, output, event.items);
}

fn appendEvent(allocator: std.mem.Allocator, output: *std.ArrayList(u8), event: []const u8) !void {
    try daemon.ensureCanWriteEvent(output.items.len, event);
    try output.appendSlice(allocator, event);
}
