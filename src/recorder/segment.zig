//! Append-only NDJSON segment writer. Events are buffered, flushed at a fixed
//! threshold, and synced when the segment closes.

const std = @import("std");
const event = @import("../core/event.zig");

const flush_threshold = 64 * 1024;
const event_buffer_size = 2048;

pub const Stats = struct {
    bytes: u64 = 0,
    events: u64 = 0,
};

pub const Writer = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    file: std.Io.File,
    path: []const u8,
    buffer: std.ArrayList(u8) = .empty,
    stats: Stats = .{},
    closed: bool = false,

    pub fn create(
        io: std.Io,
        allocator: std.mem.Allocator,
        directory: []const u8,
        sequence: u32,
        start_wall_ns: u64,
        start_mono_ns: u64,
    ) !Writer {
        _ = start_mono_ns;
        const name = try std.fmt.allocPrint(
            allocator,
            "segments/{d}-{d}.ndjson",
            .{ start_wall_ns, sequence },
        );
        errdefer allocator.free(name);
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ directory, name });
        defer allocator.free(full_path);
        const file = try std.Io.Dir.createFileAbsolute(io, full_path, .{});
        errdefer file.close(io);
        return .{
            .io = io,
            .allocator = allocator,
            .file = file,
            .path = name,
        };
    }

    pub fn writeEvent(self: *Writer, entry: event.RawEvent) !void {
        var line_buffer: [event_buffer_size]u8 = undefined;
        var line = std.Io.Writer.fixed(&line_buffer);
        try event.writeJson(&line, entry);
        try line.writeByte('\n');
        try self.buffer.appendSlice(self.allocator, line.buffered());
        self.stats.events += 1;
        if (self.buffer.items.len >= flush_threshold) try self.flush();
    }

    pub fn sizeBytes(self: *const Writer) u64 {
        return self.stats.bytes + self.buffer.items.len;
    }

    pub fn flush(self: *Writer) !void {
        if (self.buffer.items.len == 0) return;
        try self.file.writeStreamingAll(self.io, self.buffer.items);
        self.stats.bytes += self.buffer.items.len;
        self.buffer.clearRetainingCapacity();
    }

    pub fn close(self: *Writer) !void {
        if (self.closed) return;
        try self.flush();
        try self.file.sync(self.io);
        self.file.close(self.io);
        self.closed = true;
    }

    pub fn deinit(self: *Writer) void {
        if (!self.closed) self.file.close(self.io);
        self.buffer.deinit(self.allocator);
        self.allocator.free(self.path);
    }
};

// Checks that a segment writes canonical lines and reports byte/event counts.
test "segment writes and counts events" {
    const allocator = std.testing.allocator;
    const root = try std.fmt.allocPrint(
        allocator,
        "/tmp/xsprof-segment-{d}",
        .{std.testing.random_seed},
    );
    defer allocator.free(root);
    std.Io.Dir.createDirAbsolute(std.testing.io, root, .default_dir) catch {};
    const segments = try std.fmt.allocPrint(allocator, "{s}/segments", .{root});
    defer allocator.free(segments);
    std.Io.Dir.createDirAbsolute(std.testing.io, segments, .default_dir) catch {};

    var writer = try Writer.create(std.testing.io, allocator, root, 0, 123, 456);
    defer writer.deinit();
    try writer.writeEvent(.{
        .kind = .marker,
        .ts_ns = 7,
        .detail = "segment-test",
    });
    try writer.close();
    try std.testing.expect(writer.stats.events == 1);
    try std.testing.expect(writer.stats.bytes > 0);

    const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, writer.path });
    defer allocator.free(full);
    const file = try std.Io.Dir.openFileAbsolute(std.testing.io, full, .{});
    defer file.close(std.testing.io);
    var buffer: [1024]u8 = undefined;
    var reader = file.readerStreaming(std.testing.io, &buffer);
    const data = try reader.interface.allocRemaining(allocator, .limited(4096));
    defer allocator.free(data);
    try std.testing.expect(std.mem.indexOf(u8, data, "\"event\":\"marker\"") != null);
    try std.testing.expect(std.mem.endsWith(u8, data, "\n"));

    std.Io.Dir.deleteFileAbsolute(std.testing.io, full) catch {};
    std.Io.Dir.deleteDirAbsolute(std.testing.io, segments) catch {};
    std.Io.Dir.deleteDirAbsolute(std.testing.io, root) catch {};
}
