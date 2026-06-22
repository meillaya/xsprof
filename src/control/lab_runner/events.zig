const std = @import("std");
const journal = @import("../journal.zig");
const protocol = @import("../protocol.zig");

pub fn appendEvent(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    seq: *usize,
    event: []const u8,
    action: []const u8,
    status: []const u8,
    state: []const u8,
    reason: []const u8,
    artifact: []const u8,
) !void {
    var event_bytes: std.ArrayList(u8) = .empty;
    defer event_bytes.deinit(allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(allocator, &event_bytes);
    try writer.writer.print(
        "{{\"schema\":\"{s}\",\"seq\":{d},\"event\":\"{s}\",\"action\":\"{s}\",\"state\":\"{s}\",\"status\":\"{s}\",\"reason\":",
        .{ protocol.event_schema, seq.*, event, action, state, status },
    );
    try writeJsonString(&writer.writer, reason);
    try writer.writer.writeAll(",\"artifact\":");
    try writeJsonString(&writer.writer, artifact);
    try writer.writer.writeAll(",\"host_mutation\":false}\n");
    event_bytes = writer.toArrayList();
    try output.appendSlice(allocator, event_bytes.items);
    seq.* += 1;
}

pub fn appendActionEvent(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    seq: *usize,
    action: protocol.OperatorAction,
    event: []const u8,
    status: []const u8,
    state: []const u8,
    reason: []const u8,
    artifact: []const u8,
    ops: []const u8,
    live_bundle_path: []const u8,
) !void {
    var event_bytes: std.ArrayList(u8) = .empty;
    defer event_bytes.deinit(allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(allocator, &event_bytes);
    try writer.writer.print(
        "{{\"schema\":\"{s}\",\"seq\":{d},\"event\":\"{s}\",\"action\":\"{s}\",\"action_id\":",
        .{ protocol.event_schema, seq.*, event, @tagName(action.kind) },
    );
    try writeJsonString(&writer.writer, action.action_id);
    try writer.writer.writeAll(",\"run_id\":");
    try writeJsonString(&writer.writer, action.run_id);
    try writer.writer.writeAll(",\"target_id\":");
    try writeJsonString(&writer.writer, action.target_id);
    try writer.writer.writeAll(",\"audit_id\":");
    try writeJsonString(&writer.writer, action.audit_id);
    try writer.writer.writeAll(",\"rollback_id\":");
    try writeJsonString(&writer.writer, action.rollback_id);
    try writer.writer.writeAll(",\"state\":");
    try writeJsonString(&writer.writer, state);
    try writer.writer.writeAll(",\"status\":");
    try writeJsonString(&writer.writer, status);
    try writer.writer.writeAll(",\"reason\":");
    try writeJsonString(&writer.writer, reason);
    try writer.writer.writeAll(",\"artifact\":");
    try writeJsonString(&writer.writer, artifact);
    if (ops.len != 0) {
        try writer.writer.writeAll(",\"ops\":");
        try writeJsonString(&writer.writer, ops);
    }
    if (live_bundle_path.len != 0) {
        try writer.writer.writeAll(",\"live_bundle_path\":");
        try writeJsonString(&writer.writer, live_bundle_path);
    }
    try writer.writer.writeAll(",\"lifecycle_source\":\"runner_stream\",\"host_mutation\":false}\n");
    event_bytes = writer.toArrayList();
    try output.appendSlice(allocator, event_bytes.items);
    seq.* += 1;
}

pub fn appendLabActiveEvent(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    seq: *usize,
    action: protocol.OperatorAction,
    artifact: []const u8,
) !void {
    var event_bytes: std.ArrayList(u8) = .empty;
    defer event_bytes.deinit(allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(allocator, &event_bytes);
    try journal.writeLabActive(&writer.writer, seq.*, action, artifact);
    event_bytes = writer.toArrayList();
    try output.appendSlice(allocator, event_bytes.items);
    seq.* += 1;
}

pub fn writeJsonString(writer: anytype, value: []const u8) !void {
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
