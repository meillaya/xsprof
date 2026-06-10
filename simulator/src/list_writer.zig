const std = @import("std");

pub const Writer = struct {
    list: *std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn writeAll(self: *Writer, bytes: []const u8) !void {
        try self.list.appendSlice(self.allocator, bytes);
    }

    pub fn writeByte(self: *Writer, byte: u8) !void {
        try self.list.append(self.allocator, byte);
    }

    pub fn print(self: *Writer, comptime fmt: []const u8, args: anytype) !void {
        try self.list.print(self.allocator, fmt, args);
    }

    pub fn writeJsonValue(self: *Writer, value: anytype) !void {
        var allocating = std.Io.Writer.Allocating.fromArrayList(self.allocator, self.list);
        defer self.list.* = allocating.toArrayList();
        try std.json.Stringify.value(value, .{}, &allocating.writer);
    }
};

pub fn writer(list: *std.ArrayList(u8), allocator: std.mem.Allocator) Writer {
    return .{ .list = list, .allocator = allocator };
}
