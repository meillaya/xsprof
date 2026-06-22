const std = @import("std");

pub const EventRecord = struct {
    line: []u8,
    event: []u8,
    action_id: []u8,
    status: []u8,
    reason: []u8,
    host_mutation: bool = false,

    pub fn deinit(self: EventRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.line);
        allocator.free(self.event);
        allocator.free(self.action_id);
        allocator.free(self.status);
        allocator.free(self.reason);
    }
};

pub const RawDaemonEvent = struct {
    schema: []const u8,
    seq: ?u64 = null,
    event: []const u8,
    action: ?[]const u8 = null,
    action_id: ?[]const u8 = null,
    target_action_id: ?[]const u8 = null,
    rollback_id: ?[]const u8 = null,
    status: ?[]const u8 = null,
    reason: ?[]const u8 = null,
    host_mutation: bool,
};

pub fn writeJsonString(writer: *std.Io.Writer, value: []const u8) !void {
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
