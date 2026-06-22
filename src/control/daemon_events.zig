const std = @import("std");
const daemon = @import("daemon.zig");
const journal = @import("journal.zig");
const protocol = @import("protocol.zig");

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

pub fn appendJournalRecord(allocator: std.mem.Allocator, output: *std.ArrayList(u8), action: protocol.OperatorAction, git_sha: []const u8, seq: usize) !void {
    var event: std.ArrayList(u8) = .empty;
    defer event.deinit(allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(allocator, &event);
    try journal.writeRecord(&writer.writer, seq, action, git_sha);
    event = writer.toArrayList();
    try appendEvent(allocator, output, event.items);
}

pub fn appendDuplicate(allocator: std.mem.Allocator, output: *std.ArrayList(u8), action: protocol.OperatorAction, seq: usize) !void {
    var event: std.ArrayList(u8) = .empty;
    defer event.deinit(allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(allocator, &event);
    try journal.writeDuplicateRefusal(&writer.writer, seq, action);
    event = writer.toArrayList();
    try appendEvent(allocator, output, event.items);
}

pub fn appendDuplicateTarget(allocator: std.mem.Allocator, output: *std.ArrayList(u8), action: protocol.OperatorAction, seq: usize) !void {
    var event: std.ArrayList(u8) = .empty;
    defer event.deinit(allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(allocator, &event);
    try journal.writeDuplicateTargetRefusal(&writer.writer, seq, action);
    event = writer.toArrayList();
    try appendEvent(allocator, output, event.items);
}

pub fn appendTargetRefusal(allocator: std.mem.Allocator, output: *std.ArrayList(u8), action: protocol.OperatorAction, seq: usize, reason: []const u8) !void {
    var event: std.ArrayList(u8) = .empty;
    defer event.deinit(allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(allocator, &event);
    try journal.writeTargetRefusal(&writer.writer, seq, action, reason);
    event = writer.toArrayList();
    try appendEvent(allocator, output, event.items);
}

pub fn appendInvalidActionId(allocator: std.mem.Allocator, output: *std.ArrayList(u8), action: protocol.OperatorAction, seq: usize) !void {
    var event: std.ArrayList(u8) = .empty;
    defer event.deinit(allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(allocator, &event);
    try journal.writeInvalidActionIdRefusal(&writer.writer, seq, action);
    event = writer.toArrayList();
    try appendEvent(allocator, output, event.items);
}

pub fn appendInvalidField(allocator: std.mem.Allocator, output: *std.ArrayList(u8), action: protocol.OperatorAction, seq: usize) !void {
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

pub fn appendMalformed(allocator: std.mem.Allocator, output: *std.ArrayList(u8), seq: usize) !void {
    var event: std.ArrayList(u8) = .empty;
    defer event.deinit(allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(allocator, &event);
    try daemon.writeActionResult(&writer.writer, allocator, "{not-json", seq);
    event = writer.toArrayList();
    try appendEvent(allocator, output, event.items);
}

pub fn appendEvent(allocator: std.mem.Allocator, output: *std.ArrayList(u8), event: []const u8) !void {
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
