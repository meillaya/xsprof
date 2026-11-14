//! Folded-stack writer (`comm;fn;fn count`) for flamegraph-style tools.
//!
//! Frames are supplied root-first as plain tokens: resolved symbols, `[k]`
//! kernel prefixes, and `0x...` unresolved addresses. The writer only
//! aggregates and formats; it never invents a symbol. Folded keys are sorted
//! bytewise on output so the same stacks always produce the same bytes
//! (deterministic goldens), independent of sample arrival order.
//!
//! Delimiters and control characters inside a token are replaced with `:` /
//! `_` so one token can never split a folded line.

const std = @import("std");

const Writer = std.Io.Writer;

pub const max_stacks = 131_072;
pub const max_key_bytes = 16 * 1024;
pub const max_token_bytes = 256;
pub const max_comm_bytes = 64;

pub const Error = error{
    StackTableFull,
    KeyTooLong,
    OutOfMemory,
};

pub const Stats = struct {
    samples: u64 = 0,
    stacks: usize = 0,
    frames: u64 = 0,
    bytes: u64 = 0,
};

/// One folded token, bounded and delimiter-free. Empty input becomes `?` so a
/// frame slot is always visible (never a silently empty frame).
pub fn sanitizeToken(buffer: []u8, token: []const u8) []const u8 {
    const bounded = token[0..@min(token.len, @min(buffer.len, max_token_bytes))];
    if (bounded.len == 0) {
        if (buffer.len != 0) {
            buffer[0] = '?';
            return buffer[0..1];
        }
        return "";
    }
    for (bounded, 0..) |byte, index| {
        buffer[index] = switch (byte) {
            ';' => ':',
            '\n', '\r', '\t' => ' ',
            else => if (byte < 0x20 or byte == 0x7f) '_' else byte,
        };
    }
    return buffer[0..bounded.len];
}

/// Write one folded line prefix (no count): `comm;root;...;leaf`.
pub fn writeKey(w: *Writer, comm: []const u8, frames: []const []const u8) Writer.Error!void {
    var comm_buffer: [max_comm_bytes]u8 = undefined;
    try w.writeAll(sanitizeToken(&comm_buffer, comm));
    for (frames) |frame| {
        var frame_buffer: [max_token_bytes]u8 = undefined;
        try w.writeByte(';');
        try w.writeAll(sanitizeToken(&frame_buffer, frame));
    }
}

pub const Table = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    counts: std.StringHashMap(u64),
    samples: u64 = 0,
    frames: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) Table {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .counts = std.StringHashMap(u64).init(allocator),
        };
    }

    pub fn deinit(self: *Table) void {
        self.counts.deinit();
        self.arena.deinit();
    }

    /// Count one folded stack. The key must already contain the `comm;...`
    /// prefix; it is copied into the table arena on first use.
    pub fn add(self: *Table, key: []const u8, count: u64, frame_count: u64) Error!void {
        if (key.len > max_key_bytes) return error.KeyTooLong;
        if (self.counts.getPtr(key)) |existing| {
            existing.* +|= count;
        } else {
            if (self.counts.count() >= max_stacks) return error.StackTableFull;
            const owned = try self.arena.allocator().dupe(u8, key);
            try self.counts.put(owned, count);
        }
        self.samples +|= count;
        self.frames +|= frame_count *| count;
    }

    fn collectKeys(self: *Table, keys: *std.ArrayList([]const u8)) !void {
        var iterator = self.counts.keyIterator();
        while (iterator.next()) |key| {
            try keys.append(self.allocator, key.*);
        }
    }

    /// Write every stack sorted bytewise: `key count\n`. Returns the totals of
    /// everything written.
    pub fn write(self: *Table, w: *Writer) Writer.Error!Stats {
        var keys: std.ArrayList([]const u8) = .empty;
        defer keys.deinit(self.allocator);
        self.collectKeys(&keys) catch |err| switch (err) {
            error.OutOfMemory => return error.WriteFailed,
        };
        std.mem.sortUnstable([]const u8, keys.items, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.less);
        var bytes: u64 = 0;
        for (keys.items) |key| {
            const count = self.counts.get(key) orelse 0;
            try w.writeAll(key);
            try w.writeByte(' ');
            try w.print("{d}", .{count});
            try w.writeByte('\n');
            bytes +|= key.len + 24;
        }
        return .{
            .samples = self.samples,
            .stacks = keys.items.len,
            .frames = self.frames,
            .bytes = bytes,
        };
    }
};

test "folded writer sorts keys and keeps counts stable" {
    var table = Table.init(std.testing.allocator);
    defer table.deinit();
    try table.add("worker;start;run", 2, 2);
    try table.add("main;idle", 1, 1);
    try table.add("worker;start;run", 3, 2);
    var buffer: [256]u8 = undefined;
    var writer = Writer.fixed(&buffer);
    const stats = try table.write(&writer);
    try std.testing.expectEqualStrings(
        "main;idle 1\nworker;start;run 5\n",
        writer.buffered(),
    );
    try std.testing.expectEqual(@as(u64, 6), stats.samples);
    try std.testing.expectEqual(@as(usize, 2), stats.stacks);
    try std.testing.expectEqual(@as(u64, 11), stats.frames);
}

test "folded key sanitizes delimiters and bounds tokens" {
    var table = Table.init(std.testing.allocator);
    defer table.deinit();
    var key_buffer: [256]u8 = undefined;
    var key_writer = Writer.fixed(&key_buffer);
    const frames = [_][]const u8{ "[k]do_sys;call", "0x401000", "" };
    try writeKey(&key_writer, "wo;rker", &frames);
    try table.add(key_writer.buffered(), 1, frames.len);
    var out_buffer: [256]u8 = undefined;
    var out_writer = Writer.fixed(&out_buffer);
    _ = try table.write(&out_writer);
    try std.testing.expectEqualStrings(
        "wo:rker;[k]do_sys:call;0x401000;? 1\n",
        out_writer.buffered(),
    );
}

test "folded table refuses unbounded growth" {
    var table = Table.init(std.testing.allocator);
    defer table.deinit();
    var key_buffer: [64]u8 = undefined;
    var index: usize = 0;
    while (index < max_stacks) : (index += 1) {
        var writer = Writer.fixed(&key_buffer);
        var frame_buffer: [32]u8 = undefined;
        const frame = std.fmt.bufPrint(&frame_buffer, "f{d}", .{index}) catch "f";
        try writeKey(&writer, "c", &.{frame});
        try table.add(writer.buffered(), 1, 1);
    }
    try std.testing.expectError(error.StackTableFull, table.add("c;overflow", 1, 1));
}
