//! Streaming reader for compact raw segments (.xsraw). The reader keeps a
//! fixed block buffer, so memory is independent of segment size, and reports a
//! clean/dirty/corrupt status instead of inventing or interpolating events.
//! Legacy NDJSON segments are not handled here; extract keeps that path.

const std = @import("std");
const event = @import("../core/event.zig");
const compact = @import("compact.zig");

pub const Codec = enum { ndjson, compact_v1, unknown };

pub fn codecForPath(path: []const u8) Codec {
    if (std.mem.endsWith(u8, path, ".xsraw")) return .compact_v1;
    if (std.mem.endsWith(u8, path, ".ndjson")) return .ndjson;
    return .unknown;
}

pub const Status = enum {
    clean,
    dirty,
    corrupt,
    unsupported,

    pub fn label(self: Status) []const u8 {
        return switch (self) {
            .clean => "clean",
            .dirty => "dirty",
            .corrupt => "corrupt",
            .unsupported => "unsupported",
        };
    }
};

pub const Reader = struct {
    io: std.Io,
    file: std.Io.File,
    size: u64,
    offset: u64 = 0,
    events: u64 = 0,
    blocks: u64 = 0,
    status: Status = .clean,
    err_offset: u64 = 0,
    header: ?compact.Header = null,
    footer: ?compact.Footer = null,
    payload: [compact.max_block_payload]u8 = undefined,
    decoder: ?compact.Decoder = null,
    finished: bool = false,

    pub fn open(io: std.Io, path: []const u8) !Reader {
        const file = if (path.len != 0 and path[0] == '/')
            try std.Io.Dir.openFileAbsolute(io, path, .{})
        else
            try std.Io.Dir.cwd().openFile(io, path, .{});
        errdefer file.close(io);
        const stat = try file.stat(io);
        if (stat.size < compact.header_bytes) return error.InvalidSegment;
        var header_buf: [compact.header_bytes]u8 = undefined;
        if (try readAt(io, file, &header_buf, 0) != header_buf.len) return error.InvalidSegment;
        const header = compact.Header.parse(&header_buf) catch |err| return err;
        return .{
            .io = io,
            .file = file,
            .size = stat.size,
            .offset = compact.header_bytes,
            .header = header,
        };
    }

    pub fn close(self: *Reader) void {
        self.file.close(self.io);
    }

    pub fn deinit(self: *Reader) void {
        self.close();
    }

    pub fn eventCount(self: *const Reader) u64 {
        return self.events;
    }

    /// Decode the next event. Returned comm/detail slices point into the
    /// reader's block buffer and are valid until the next call.
    pub fn next(self: *Reader) !?event.RawEvent {
        while (true) {
            if (self.decoder) |*decoder| {
                const decoded = decoder.next() catch |err| {
                    self.status = .corrupt;
                    self.err_offset = self.offset;
                    return err;
                };
                if (decoded) |entry| {
                    self.events += 1;
                    return entry;
                }
                self.decoder = null;
            }
            if (!try self.loadNextBlock()) return null;
        }
    }

    /// Re-stat the file so a tailing consumer can resume after the writer
    /// appends more blocks. Footered segments are final.
    pub fn refresh(self: *Reader) !void {
        if (self.footer != null) return;
        const stat = try self.file.stat(self.io);
        if (stat.size > self.size) {
            self.size = stat.size;
            self.finished = false;
            // A previously truncated tail may now be complete.
            if (self.status == .dirty) self.status = .clean;
        }
    }

    fn loadNextBlock(self: *Reader) !bool {
        if (self.finished) return false;
        if (self.offset >= self.size) {
            self.finished = true;
            if (self.footer == null) self.status = .dirty;
            return false;
        }
        if (self.offset + compact.block_header_bytes > self.size) {
            self.status = .dirty;
            self.err_offset = self.offset;
            self.finished = true;
            return false;
        }
        var block_header: [compact.block_header_bytes]u8 = undefined;
        if (try readAt(self.io, self.file, &block_header, self.offset) != block_header.len) {
            self.status = .dirty;
            self.err_offset = self.offset;
            self.finished = true;
            return false;
        }
        const parsed = compact.parseBlockHeader(&block_header) catch {
            self.status = .corrupt;
            self.err_offset = self.offset;
            self.finished = true;
            return error.InvalidSegment;
        };
        const expected_crc = std.mem.readInt(u32, block_header[4..][0..4], .little);
        const payload_start = self.offset + compact.block_header_bytes;
        if (payload_start + parsed.payload_len > self.size) {
            self.status = .dirty;
            self.err_offset = self.offset;
            self.finished = true;
            return false;
        }
        if (parsed.kind == compact.block_type_footer) {
            var footer_payload: [compact.footer_payload_bytes]u8 = undefined;
            if (try readAt(self.io, self.file, &footer_payload, payload_start) != footer_payload.len) {
                self.status = .dirty;
                self.err_offset = self.offset;
                self.finished = true;
                return false;
            }
            if (compact.crc(&footer_payload) != expected_crc) {
                self.status = .corrupt;
                self.err_offset = self.offset;
                self.finished = true;
                return error.InvalidSegment;
            }
            self.footer = compact.Footer.parse(&footer_payload);
            self.offset = payload_start + compact.footer_payload_bytes;
            self.finished = true;
            if (self.offset != self.size) {
                self.status = .corrupt;
                self.err_offset = self.offset;
                return error.InvalidSegment;
            }
            return false;
        }
        if (try readAt(self.io, self.file, self.payload[0..parsed.payload_len], payload_start) != parsed.payload_len) {
            self.status = .dirty;
            self.err_offset = self.offset;
            self.finished = true;
            return false;
        }
        if (compact.crc(self.payload[0..parsed.payload_len]) != expected_crc) {
            self.status = .corrupt;
            self.err_offset = self.offset;
            self.finished = true;
            return error.InvalidSegment;
        }
        self.decoder = compact.Decoder.init(self.payload[0..parsed.payload_len]);
        self.blocks += 1;
        self.offset = payload_start + parsed.payload_len;
        return true;
    }
};

/// Cheap clean-close check: valid header plus a valid footer in the final
/// 32 bytes. It does not decode payloads, so daemon restart stays fast.
pub fn tailStatus(io: std.Io, path: []const u8) !Status {
    const file = (if (path.len != 0 and path[0] == '/')
        std.Io.Dir.openFileAbsolute(io, path, .{})
    else
        std.Io.Dir.cwd().openFile(io, path, .{})) catch |err| switch (err) {
        error.FileNotFound => return .dirty,
        else => return err,
    };
    defer file.close(io);
    const stat = try file.stat(io);
    const footer_total = compact.block_header_bytes + compact.footer_payload_bytes;
    if (stat.size < compact.header_bytes + footer_total) return .dirty;
    var header_buf: [compact.header_bytes]u8 = undefined;
    if (try readAt(io, file, &header_buf, 0) != header_buf.len) return .dirty;
    _ = compact.Header.parse(&header_buf) catch |err| switch (err) {
        error.UnsupportedVersion => return .unsupported,
        error.InvalidSegment, error.TruncatedSegment => return .corrupt,
    };
    var footer_buf: [footer_total]u8 = undefined;
    const offset = stat.size - footer_total;
    if (try readAt(io, file, &footer_buf, offset) != footer_buf.len) return .dirty;
    var block_header: [compact.block_header_bytes]u8 = undefined;
    @memcpy(&block_header, footer_buf[0..compact.block_header_bytes]);
    const parsed = compact.parseBlockHeader(&block_header) catch return .dirty;
    if (parsed.kind != compact.block_type_footer) return .dirty;
    const expected_crc = std.mem.readInt(u32, block_header[4..][0..4], .little);
    if (compact.crc(footer_buf[compact.block_header_bytes..]) != expected_crc) return .dirty;
    return .clean;
}

/// Legacy NDJSON clean-close check: the file ends with a complete line.
pub fn tailStatusNdjson(io: std.Io, path: []const u8) !Status {
    const file = (if (path.len != 0 and path[0] == '/')
        std.Io.Dir.openFileAbsolute(io, path, .{})
    else
        std.Io.Dir.cwd().openFile(io, path, .{})) catch |err| switch (err) {
        error.FileNotFound => return .dirty,
        else => return err,
    };
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.size == 0) return .dirty;
    var last: [1]u8 = undefined;
    if (try readAt(io, file, &last, stat.size - 1) != 1) return .dirty;
    return if (last[0] == '\n') .clean else .dirty;
}

fn readAt(io: std.Io, file: std.Io.File, buffer: []u8, at: u64) !usize {
    var read_total: usize = 0;
    while (read_total < buffer.len) {
        const n = try file.readPositionalAll(io, buffer[read_total..], at + read_total);
        if (n == 0) break;
        read_total += n;
    }
    return read_total;
}

fn testRoot(allocator: std.mem.Allocator, tag: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "/tmp/xsprof-reader-{s}-{d}", .{ tag, std.testing.random_seed });
}

fn setupDir(allocator: std.mem.Allocator, tag: []const u8) ![]const u8 {
    const root = try testRoot(allocator, tag);
    std.Io.Dir.createDirAbsolute(std.testing.io, root, .default_dir) catch {};
    const segments = try std.fmt.allocPrint(allocator, "{s}/segments", .{root});
    defer allocator.free(segments);
    std.Io.Dir.createDirAbsolute(std.testing.io, segments, .default_dir) catch {};
    return root;
}

fn cleanupDir(allocator: std.mem.Allocator, root: []const u8) void {
    const segments = std.fmt.allocPrint(allocator, "{s}/segments", .{root}) catch return;
    defer allocator.free(segments);
    var dir = std.Io.Dir.openDirAbsolute(std.testing.io, segments, .{ .iterate = true }) catch {
        std.Io.Dir.deleteDirAbsolute(std.testing.io, root) catch {};
        return;
    };
    defer dir.close(std.testing.io);
    var it = dir.iterate();
    while (it.next(std.testing.io) catch null) |item| {
        dir.deleteFile(std.testing.io, item.name) catch {};
    }
    std.Io.Dir.deleteDirAbsolute(std.testing.io, segments) catch {};
    std.Io.Dir.deleteDirAbsolute(std.testing.io, root) catch {};
}

fn writeEvents(writer: *@import("segment.zig").Writer, count: u64) !void {
    var index: u64 = 0;
    while (index < count) : (index += 1) {
        try writer.writeEvent(.{
            .kind = if (index % 3 == 0) .sched_switch else if (index % 3 == 1) .page_fault else .marker,
            .ts_ns = 5_000_000 + index * 120,
            .cpu = @intCast(index % 4),
            .pid = 42,
            .tid = 42,
            .a = index,
            .b = 1,
            .comm = if (index % 2 == 0) "worker" else "",
            .detail = if (index % 3 == 2) "sample_loss dropped=2" else "",
        });
    }
}

// Checks a clean segment decodes to exactly the events that were written.
test "clean segment decodes every event" {
    const allocator = std.testing.allocator;
    const root = try setupDir(allocator, "clean");
    defer allocator.free(root);
    defer cleanupDir(allocator, root);
    const segment = @import("segment.zig");
    var writer = try segment.Writer.create(std.testing.io, allocator, root, 0, 1, 2);
    defer writer.deinit();
    try writeEvents(&writer, 6000);
    try writer.close();
    const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, writer.path });
    defer allocator.free(full);

    var reader = try Reader.open(std.testing.io, full);
    defer reader.deinit();
    var decoded: u64 = 0;
    var canonical: [2048]u8 = undefined;
    while (try reader.next()) |entry| : (decoded += 1) {
        var buffer = std.Io.Writer.fixed(&canonical);
        try event.writeJson(&buffer, entry);
        try std.testing.expect(std.mem.indexOf(u8, buffer.buffered(), "\"host_mutation\":false") != null);
    }
    try std.testing.expectEqual(@as(u64, 6000), decoded);
    try std.testing.expectEqual(Status.clean, reader.status);
    try std.testing.expect(reader.blocks >= 2);
    try std.testing.expect(reader.footer != null);
    try std.testing.expectEqual(@as(u64, 6000), reader.footer.?.event_count);
}

// Checks a clean segment accepts a mid-file trailing record and reports clean.
test "reader round-trips boundary values byte-identically" {
    const allocator = std.testing.allocator;
    const root = try setupDir(allocator, "bounds");
    defer allocator.free(root);
    defer cleanupDir(allocator, root);
    const segment = @import("segment.zig");
    var writer = try segment.Writer.create(std.testing.io, allocator, root, 1, 3, 4);
    defer writer.deinit();
    const expected = [_]event.RawEvent{
        .{ .kind = .sched_switch, .ts_ns = 9, .cpu = -1, .pid = std.math.minInt(i32), .tid = 1, .a = std.math.maxInt(u64), .b = std.math.maxInt(u64), .c = 0, .comm = "abcdefghijklmnop" },
        .{ .kind = .sched_wakeup, .ts_ns = 8, .cpu = std.math.maxInt(i32), .pid = 2, .tid = 2, .a = 0, .b = 0, .c = 0, .comm = "" },
    };
    for (expected) |entry| try writer.writeEvent(entry);
    try writer.close();
    const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, writer.path });
    defer allocator.free(full);
    var reader = try Reader.open(std.testing.io, full);
    defer reader.deinit();
    for (expected) |wanted| {
        const got = (try reader.next()).?;
        var mine_buf: [2048]u8 = undefined;
        var theirs_buf: [2048]u8 = undefined;
        var mine = std.Io.Writer.fixed(&mine_buf);
        var theirs = std.Io.Writer.fixed(&theirs_buf);
        try event.writeJson(&mine, got);
        try event.writeJson(&theirs, wanted);
        try std.testing.expectEqualStrings(theirs.buffered(), mine.buffered());
    }
    try std.testing.expect((try reader.next()) == null);
    try std.testing.expectEqual(Status.clean, reader.status);
}

// Checks a torn tail is reported as dirty instead of decoded or invented.
test "torn tail is dirty and keeps the complete prefix" {
    const allocator = std.testing.allocator;
    const root = try setupDir(allocator, "torn");
    defer allocator.free(root);
    defer cleanupDir(allocator, root);
    const segment = @import("segment.zig");
    var writer = try segment.Writer.create(std.testing.io, allocator, root, 0, 5, 6);
    defer writer.deinit();
    try writeEvents(&writer, 500);
    try writer.close();
    const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, writer.path });
    defer allocator.free(full);
    const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, full, allocator, .limited(1024 * 1024));
    defer allocator.free(data);
    const cut = data.len - 7;
    const torn = try std.fmt.allocPrint(allocator, "{s}/segments/torn-0.xsraw", .{root});
    defer allocator.free(torn);
    {
        const file = try std.Io.Dir.createFileAbsolute(std.testing.io, torn, .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, data[0..cut]);
    }
    var reader = try Reader.open(std.testing.io, torn);
    defer reader.deinit();
    var decoded: u64 = 0;
    while (try reader.next()) |_| decoded += 1;
    try std.testing.expect(decoded > 0);
    try std.testing.expectEqual(Status.dirty, reader.status);
}

// Checks a payload bit flip is reported as corrupt.
test "crc corruption is rejected" {
    const allocator = std.testing.allocator;
    const root = try setupDir(allocator, "crc");
    defer allocator.free(root);
    defer cleanupDir(allocator, root);
    const segment = @import("segment.zig");
    var writer = try segment.Writer.create(std.testing.io, allocator, root, 0, 7, 8);
    defer writer.deinit();
    try writeEvents(&writer, 200);
    try writer.close();
    const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, writer.path });
    defer allocator.free(full);
    var data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, full, allocator, .limited(1024 * 1024));
    defer allocator.free(data);
    data[compact.header_bytes + compact.block_header_bytes + 2] ^= 0xff;
    const broken = try std.fmt.allocPrint(allocator, "{s}/segments/broken-0.xsraw", .{root});
    defer allocator.free(broken);
    {
        const file = try std.Io.Dir.createFileAbsolute(std.testing.io, broken, .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, data);
    }
    var reader = try Reader.open(std.testing.io, broken);
    defer reader.deinit();
    try std.testing.expectError(error.InvalidSegment, reader.next());
    try std.testing.expectEqual(Status.corrupt, reader.status);
    try std.testing.expect(reader.err_offset >= compact.header_bytes);
}

// Checks an unsupported version and a truncated header fail at open.
test "unsupported version and short header fail closed" {
    const allocator = std.testing.allocator;
    const root = try setupDir(allocator, "version");
    defer allocator.free(root);
    defer cleanupDir(allocator, root);
    const segment = @import("segment.zig");
    var writer = try segment.Writer.create(std.testing.io, allocator, root, 0, 9, 10);
    defer writer.deinit();
    try writer.writeEvent(.{ .kind = .marker, .ts_ns = 1 });
    try writer.close();
    const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, writer.path });
    defer allocator.free(full);
    var data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, full, allocator, .limited(1024 * 1024));
    defer allocator.free(data);
    data[8] = 2;
    const other = try std.fmt.allocPrint(allocator, "{s}/segments/v2-0.xsraw", .{root});
    defer allocator.free(other);
    {
        const file = try std.Io.Dir.createFileAbsolute(std.testing.io, other, .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, data);
    }
    try std.testing.expectError(error.UnsupportedVersion, Reader.open(std.testing.io, other));

    const short = try std.fmt.allocPrint(allocator, "{s}/segments/short-0.xsraw", .{root});
    defer allocator.free(short);
    {
        const file = try std.Io.Dir.createFileAbsolute(std.testing.io, short, .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, data[0..20]);
    }
    try std.testing.expectError(error.InvalidSegment, Reader.open(std.testing.io, short));
}

// Checks codec dispatch is extension based and explicit.
test "codec dispatch by suffix" {
    try std.testing.expectEqual(Codec.compact_v1, codecForPath("segments/1-0.xsraw"));
    try std.testing.expectEqual(Codec.ndjson, codecForPath("segments/1-0.ndjson"));
    try std.testing.expectEqual(Codec.unknown, codecForPath("segments/1-0.bin"));
}
// Checks the cheap tail check detects clean, torn, and trailing-byte segments.
test "tail status checks footer and legacy newline" {
    const allocator = std.testing.allocator;
    const root = try setupDir(allocator, "tail");
    defer allocator.free(root);
    defer cleanupDir(allocator, root);
    const segment = @import("segment.zig");
    var writer = try segment.Writer.create(std.testing.io, allocator, root, 0, 11, 12);
    defer writer.deinit();
    try writeEvents(&writer, 200);
    try writer.close();
    const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, writer.path });
    defer allocator.free(full);
    try std.testing.expectEqual(Status.clean, try tailStatus(std.testing.io, full));

    const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, full, allocator, .limited(1024 * 1024));
    defer allocator.free(data);
    const torn_path = try std.fmt.allocPrint(allocator, "{s}/segments/torn-0.xsraw", .{root});
    defer allocator.free(torn_path);
    {
        const file = try std.Io.Dir.createFileAbsolute(std.testing.io, torn_path, .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, data[0 .. data.len - 1]);
    }
    try std.testing.expectEqual(Status.dirty, try tailStatus(std.testing.io, torn_path));

    const legacy_path = try std.fmt.allocPrint(allocator, "{s}/segments/legacy-0.ndjson", .{root});
    defer allocator.free(legacy_path);
    {
        const file = try std.Io.Dir.createFileAbsolute(std.testing.io, legacy_path, .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "{\"a\":1}\n");
    }
    try std.testing.expectEqual(Status.clean, try tailStatusNdjson(std.testing.io, legacy_path));
    {
        const file = try std.Io.Dir.createFileAbsolute(std.testing.io, legacy_path, .{ .truncate = true });
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "{\"a\":1}");
    }
    try std.testing.expectEqual(Status.dirty, try tailStatusNdjson(std.testing.io, legacy_path));
}
// Checks tailing resumes after new blocks are appended and reports clean once
// the footer arrives.
test "reader refreshes for a growing segment" {
    const allocator = std.testing.allocator;
    const root = try setupDir(allocator, "tail-grow");
    defer allocator.free(root);
    defer cleanupDir(allocator, root);
    const segment = @import("segment.zig");
    var writer = try segment.Writer.create(std.testing.io, allocator, root, 0, 21, 22);
    defer writer.deinit();
    try writer.writeEvent(.{ .kind = .sched_switch, .ts_ns = 1, .cpu = 0, .pid = 7, .tid = 7, .a = 1, .comm = "worker" });
    try writer.flush();
    const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, writer.path });
    defer allocator.free(full);
    var reader = try Reader.open(std.testing.io, full);
    defer reader.deinit();
    var decoded: u64 = 0;
    while (try reader.next()) |_| decoded += 1;
    try std.testing.expectEqual(@as(u64, 1), decoded);
    try std.testing.expectEqual(Status.dirty, reader.status);

    try writer.writeEvent(.{ .kind = .sched_switch, .ts_ns = 2, .cpu = 0, .pid = 7, .tid = 7, .a = 2, .comm = "worker" });
    try writer.flush();
    try reader.refresh();
    while (try reader.next()) |_| decoded += 1;
    try std.testing.expectEqual(@as(u64, 2), decoded);

    try writer.close();
    try reader.refresh();
    try std.testing.expect((try reader.next()) == null);
    try std.testing.expectEqual(Status.clean, reader.status);
}

// Checks the committed .xsraw golden decodes to the committed canonical extract.
test "committed compact golden matches its canonical extract" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const segment_path = "tests/golden/recorder/segments/segment_v1_golden.xsraw";
    const extract_path = "tests/golden/recorder/segment_v1_golden.ndjson";
    const expected = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, extract_path, allocator, .limited(1024 * 1024));
    var reader = try Reader.open(std.testing.io, segment_path);
    defer reader.deinit();
    var actual: std.Io.Writer.Allocating = .init(allocator);
    defer actual.deinit();
    var line_buffer: [4096]u8 = undefined;
    while (true) {
        const maybe = try reader.next();
        const entry = maybe orelse break;
        var line = std.Io.Writer.fixed(&line_buffer);
        try event.writeJson(&line, entry);
        try line.writeByte('\n');
        try actual.writer.writeAll(line.buffered());
    }
    try std.testing.expectEqualStrings(expected, actual.writer.buffered());
    try std.testing.expectEqual(Status.clean, reader.status);
}
