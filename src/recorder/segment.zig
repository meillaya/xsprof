//! Append-only compact raw segment writer (.xsraw). Events are grouped into
//! CRC-32C framed blocks and a footer marks a clean close. The writer never
//! re-reads data and never serializes canonical JSON in the hot path.

const std = @import("std");
const event = @import("../core/event.zig");
const compact = @import("compact.zig");

pub const Stats = struct {
    bytes: u64 = 0,
    events: u64 = 0,
};

pub const Writer = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    file: std.Io.File,
    path: []const u8,
    block: [compact.max_block_payload]u8 = undefined,
    block_len: usize = 0,
    block_count: u64 = 0,
    payload_bytes: u64 = 0,
    stats: Stats = .{},
    encoder: compact.Encoder,
    closed: bool = false,

    pub fn create(
        io: std.Io,
        allocator: std.mem.Allocator,
        directory: []const u8,
        sequence: u32,
        start_wall_ns: u64,
        start_mono_ns: u64,
    ) !Writer {
        const name = try std.fmt.allocPrint(
            allocator,
            "segments/{d}-{d}.xsraw",
            .{ start_wall_ns, sequence },
        );
        errdefer allocator.free(name);
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ directory, name });
        defer allocator.free(full_path);
        const file = try std.Io.Dir.createFileAbsolute(io, full_path, .{});
        errdefer file.close(io);
        var encoder = try compact.Encoder.init(allocator);
        errdefer encoder.deinit();

        var header_buf: [compact.header_bytes]u8 = undefined;
        var header = compact.Header{
            .seq = sequence,
            .start_wall_ns = start_wall_ns,
            .start_mono_ns = start_mono_ns,
        };
        header.write(&header_buf);
        try file.writeStreamingAll(io, &header_buf);
        return .{
            .io = io,
            .allocator = allocator,
            .file = file,
            .path = name,
            .encoder = encoder,
            .stats = .{ .bytes = compact.header_bytes },
        };
    }

    pub fn writeEvent(self: *Writer, entry: event.RawEvent) !void {
        var scratch: [compact.max_record_bytes]u8 = undefined;
        while (true) {
            const used = self.encoder.encode(&scratch, entry) catch |err| switch (err) {
                error.DeltaOverflow, error.TableFull => {
                    try self.flushBlock();
                    continue;
                },
                else => return err,
            };
            if (self.block_len + used > compact.max_block_payload) {
                try self.flushBlock();
                continue;
            }
            @memcpy(self.block[self.block_len..][0..used], scratch[0..used]);
            self.block_len += used;
            self.payload_bytes += used;
            self.stats.events += 1;
            return;
        }
    }

    fn flushBlock(self: *Writer) !void {
        if (self.block_len == 0) return;
        var header: [compact.block_header_bytes]u8 = undefined;
        compact.writeBlockHeader(&header, compact.block_type_events, self.block[0..self.block_len]);
        try self.file.writeStreamingAll(self.io, &header);
        try self.file.writeStreamingAll(self.io, self.block[0..self.block_len]);
        self.stats.bytes += header.len + self.block_len;
        self.block_count += 1;
        self.block_len = 0;
        self.encoder.resetBlock();
    }

    /// Bytes on disk plus the pending block, used by the daemon rotation check.
    pub fn sizeBytes(self: *const Writer) u64 {
        var total = self.stats.bytes + self.block_len;
        if (self.block_len != 0) total += compact.block_header_bytes;
        return total;
    }

    pub fn eventCount(self: *const Writer) u64 {
        return self.stats.events;
    }

    pub fn flush(self: *Writer) !void {
        try self.flushBlock();
    }

    pub fn close(self: *Writer) !void {
        if (self.closed) return;
        try self.flushBlock();
        var footer_payload: [compact.footer_payload_bytes]u8 = undefined;
        var footer = compact.Footer{
            .event_count = self.stats.events,
            .block_count = self.block_count,
            .encoded_bytes = self.payload_bytes,
        };
        footer.encode(&footer_payload);
        var header: [compact.block_header_bytes]u8 = undefined;
        compact.writeBlockHeader(&header, compact.block_type_footer, &footer_payload);
        try self.file.writeStreamingAll(self.io, &header);
        try self.file.writeStreamingAll(self.io, &footer_payload);
        self.stats.bytes += header.len + footer_payload.len;
        try self.file.sync(self.io);
        self.file.close(self.io);
        self.closed = true;
    }

    pub fn deinit(self: *Writer) void {
        if (!self.closed) self.file.close(self.io);
        self.encoder.deinit();
        self.allocator.free(self.path);
    }
};

fn testRoot(allocator: std.mem.Allocator, tag: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "/tmp/xsprof-compact-{s}-{d}", .{ tag, std.testing.random_seed });
}

// Checks a segment writes header, blocks, and a clean footer with counts.
test "segment writes a clean compact file" {
    const allocator = std.testing.allocator;
    const root = try testRoot(allocator, "segment");
    defer allocator.free(root);
    std.Io.Dir.createDirAbsolute(std.testing.io, root, .default_dir) catch {};
    const segments = try std.fmt.allocPrint(allocator, "{s}/segments", .{root});
    defer allocator.free(segments);
    std.Io.Dir.createDirAbsolute(std.testing.io, segments, .default_dir) catch {};

    var writer = try Writer.create(std.testing.io, allocator, root, 3, 111, 222);
    defer writer.deinit();
    var index: u64 = 0;
    while (index < 5000) : (index += 1) {
        try writer.writeEvent(.{
            .kind = .sched_switch,
            .ts_ns = 1_000_000 + index * 250,
            .cpu = @intCast(index % 4),
            .pid = 100,
            .tid = 100,
            .a = index,
            .b = index + 1,
            .comm = if (index % 2 == 0) "worker" else "yes",
        });
    }
    try writer.close();
    try std.testing.expectEqual(@as(u64, 5000), writer.stats.events);
    try std.testing.expect(writer.block_count >= 2);

    const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, writer.path });
    defer allocator.free(full);
    try std.testing.expect(std.mem.endsWith(u8, writer.path, ".xsraw"));
    const file = try std.Io.Dir.openFileAbsolute(std.testing.io, full, .{});
    defer file.close(std.testing.io);
    const size = (try file.stat(std.testing.io)).size;
    try std.testing.expectEqual(writer.stats.bytes, size);
    var trailer: [32]u8 = undefined;
    const read = try file.readPositionalAll(std.testing.io, &trailer, size - trailer.len);
    try std.testing.expectEqual(@as(usize, trailer.len), read);
    try std.testing.expectEqual(compact.block_type_footer, trailer[0]);
    var footer_payload: [compact.footer_payload_bytes]u8 = undefined;
    @memcpy(&footer_payload, trailer[compact.block_header_bytes..]);
    const footer = compact.Footer.parse(&footer_payload);
    try std.testing.expectEqual(@as(u64, 5000), footer.event_count);
    try std.testing.expectEqual(writer.block_count, footer.block_count);

    // More than max_strings distinct comms must span blocks, not corrupt refs.
    var unique_writer = try Writer.create(std.testing.io, allocator, root, 4, 112, 223);
    defer unique_writer.deinit();
    var unique_index: u64 = 0;
    while (unique_index < compact.max_strings + 32) : (unique_index += 1) {
        var comm_buf: [16]u8 = undefined;
        const comm = std.fmt.bufPrint(&comm_buf, "u{d}", .{unique_index}) catch unreachable;
        try unique_writer.writeEvent(.{ .kind = .marker, .ts_ns = unique_index, .comm = comm });
    }
    try unique_writer.close();
    const unique_full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, unique_writer.path });
    defer allocator.free(unique_full);
    var unique_reader = try @import("segment_reader.zig").Reader.open(std.testing.io, unique_full);
    defer unique_reader.deinit();
    var decoded_unique: u64 = 0;
    while (try unique_reader.next()) |_| decoded_unique += 1;
    try std.testing.expectEqual(@as(u64, compact.max_strings + 32), decoded_unique);
    try std.testing.expectEqual(@import("segment_reader.zig").Status.clean, unique_reader.status);

    std.Io.Dir.deleteFileAbsolute(std.testing.io, full) catch {};
    std.Io.Dir.deleteDirAbsolute(std.testing.io, segments) catch {};
    std.Io.Dir.deleteDirAbsolute(std.testing.io, root) catch {};
}
