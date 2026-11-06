//! Compact raw segment codec v1 (xsprof/raw-segment/v1). A segment is a
//! 64-byte header, CRC-32C framed blocks, and one footer block that proves a
//! clean close. Event strings go through the same privacy transform as
//! event.writeJson, so decoding then serializing reproduces canonical NDJSON
//! byte for byte while the state directory never holds secrets.

const std = @import("std");
const event = @import("../core/event.zig");
const privacy = @import("../core/privacy.zig");

pub const magic = "XSPRAWS1";
pub const version: u16 = 1;
pub const header_bytes: usize = 64;
pub const block_header_bytes: usize = 8;
pub const max_block_payload: usize = 32 * 1024;
pub const footer_payload_bytes: usize = 24;
pub const max_record_bytes: usize = 1152;
pub const max_strings: usize = 1024;
pub const max_comm_bytes: usize = 15;
pub const max_detail_bytes: usize = 1024;

pub const block_type_events: u8 = 1;
pub const block_type_footer: u8 = 2;

pub const Error = error{
    InvalidSegment,
    TruncatedSegment,
    UnsupportedVersion,
};

pub const crc32c = std.hash.crc.@"CRC-32/ISCSI";

pub fn crc(bytes: []const u8) u32 {
    return crc32c.hash(bytes);
}

pub const Header = struct {
    seq: u32 = 0,
    block_payload_max: u32 = @intCast(max_block_payload),
    start_wall_ns: u64 = 0,
    start_mono_ns: u64 = 0,

    pub fn write(self: Header, buf: *[header_bytes]u8) void {
        @memset(buf, 0);
        @memcpy(buf[0..8], magic);
        std.mem.writeInt(u16, buf[8..][0..2], version, .little);
        std.mem.writeInt(u16, buf[10..][0..2], @intCast(header_bytes), .little);
        std.mem.writeInt(u32, buf[16..][0..4], self.seq, .little);
        std.mem.writeInt(u32, buf[20..][0..4], self.block_payload_max, .little);
        std.mem.writeInt(u64, buf[24..][0..8], self.start_wall_ns, .little);
        std.mem.writeInt(u64, buf[32..][0..8], self.start_mono_ns, .little);
        std.mem.writeInt(u32, buf[56..][0..4], crc(buf[0..56]), .little);
    }

    pub fn parse(buf: *const [header_bytes]u8) Error!Header {
        if (!std.mem.eql(u8, buf[0..8], magic)) return error.InvalidSegment;
        if (std.mem.readInt(u16, buf[8..][0..2], .little) != version) return error.UnsupportedVersion;
        if (std.mem.readInt(u16, buf[10..][0..2], .little) != header_bytes) return error.InvalidSegment;
        if (std.mem.readInt(u32, buf[12..][0..4], .little) != 0) return error.InvalidSegment;
        if (std.mem.readInt(u64, buf[40..][0..8], .little) != 0) return error.InvalidSegment;
        if (std.mem.readInt(u64, buf[48..][0..8], .little) != 0) return error.InvalidSegment;
        if (std.mem.readInt(u32, buf[60..][0..4], .little) != 0) return error.InvalidSegment;
        if (std.mem.readInt(u32, buf[56..][0..4], .little) != crc(buf[0..56])) return error.InvalidSegment;
        const block_max = std.mem.readInt(u32, buf[20..][0..4], .little);
        if (block_max == 0 or block_max > max_block_payload) return error.InvalidSegment;
        return .{
            .seq = std.mem.readInt(u32, buf[16..][0..4], .little),
            .block_payload_max = block_max,
            .start_wall_ns = std.mem.readInt(u64, buf[24..][0..8], .little),
            .start_mono_ns = std.mem.readInt(u64, buf[32..][0..8], .little),
        };
    }
};

pub const Footer = struct {
    event_count: u64 = 0,
    block_count: u64 = 0,
    encoded_bytes: u64 = 0,

    pub fn encode(self: Footer, buf: *[footer_payload_bytes]u8) void {
        std.mem.writeInt(u64, buf[0..][0..8], self.event_count, .little);
        std.mem.writeInt(u64, buf[8..][0..8], self.block_count, .little);
        std.mem.writeInt(u64, buf[16..][0..8], self.encoded_bytes, .little);
    }

    pub fn parse(buf: *const [footer_payload_bytes]u8) Footer {
        return .{
            .event_count = std.mem.readInt(u64, buf[0..][0..8], .little),
            .block_count = std.mem.readInt(u64, buf[8..][0..8], .little),
            .encoded_bytes = std.mem.readInt(u64, buf[16..][0..8], .little),
        };
    }
};

pub fn writeBlockHeader(buf: *[block_header_bytes]u8, kind: u8, payload: []const u8) void {
    buf[0] = kind;
    buf[1] = 0;
    std.mem.writeInt(u16, buf[2..][0..2], @intCast(payload.len), .little);
    std.mem.writeInt(u32, buf[4..][0..4], crc(payload), .little);
}

pub const BlockHeader = struct { kind: u8, payload_len: u16 };

pub fn parseBlockHeader(buf: *const [block_header_bytes]u8) Error!BlockHeader {
    const kind = buf[0];
    if (buf[1] != 0) return error.InvalidSegment;
    if (kind != block_type_events and kind != block_type_footer) return error.InvalidSegment;
    const payload_len = std.mem.readInt(u16, buf[2..][0..2], .little);
    if (kind == block_type_events) {
        if (payload_len == 0 or payload_len > max_block_payload) return error.InvalidSegment;
    } else if (payload_len != footer_payload_bytes) {
        return error.InvalidSegment;
    }
    return .{ .kind = kind, .payload_len = payload_len };
}

fn writeUvarint(w: *std.Io.Writer, value: u64) !void {
    var remaining = value;
    while (remaining >= 0x80) {
        try w.writeByte(@as(u8, @intCast(remaining & 0x7f)) | 0x80);
        remaining >>= 7;
    }
    try w.writeByte(@intCast(remaining));
}

fn readUvarint(data: []const u8, pos: *usize) Error!u64 {
    var result: u64 = 0;
    var shift: u6 = 0;
    var index: usize = 0;
    while (index < 10) : (index += 1) {
        if (pos.* >= data.len) return error.TruncatedSegment;
        const byte = data[pos.*];
        pos.* += 1;
        const value: u64 = byte & 0x7f;
        if (index == 9 and value > 1) return error.InvalidSegment;
        result |= value << shift;
        if (byte & 0x80 == 0) return result;
        if (index != 9) shift += 7;
    }
    return error.InvalidSegment;
}

fn writeZigzag(w: *std.Io.Writer, value: i64) !void {
    const bits: u64 = @bitCast(value);
    const zig: u64 = (bits << 1) ^ @as(u64, @bitCast(value >> 63));
    try writeUvarint(w, zig);
}

fn readZigzag(data: []const u8, pos: *usize) Error!i64 {
    const raw = try readUvarint(data, pos);
    if (raw & 1 == 1) return -1 - @as(i64, @intCast(raw >> 1));
    return @intCast(raw >> 1);
}

fn readI32(data: []const u8, pos: *usize) Error!i32 {
    const value = try readZigzag(data, pos);
    if (value < std.math.minInt(i32) or value > std.math.maxInt(i32)) return error.InvalidSegment;
    return @intCast(value);
}

fn kindFromInt(value: u8) ?event.Kind {
    inline for (@typeInfo(event.Kind).@"enum".field_names) |name| {
        if (@backingInt(@field(event.Kind, name)) == value) return @field(event.Kind, name);
    }
    return null;
}

fn validWireText(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (byte < 0x20 or byte >= 0x7f) return false;
    }
    return true;
}

/// Per-block encoder state. The comm table restarts on every events block, so
/// a block never depends on earlier blocks.
pub const Encoder = struct {
    allocator: std.mem.Allocator,
    first: bool = true,
    prev_ts: u64 = 0,
    table_len: u16 = 0,
    table_bytes: [][max_comm_bytes]u8 = &.{},
    table_map: std.StringHashMap(u16),

    pub fn init(allocator: std.mem.Allocator) !Encoder {
        const table = try allocator.alloc([max_comm_bytes]u8, max_strings);
        errdefer allocator.free(table);
        var map = std.StringHashMap(u16).init(allocator);
        errdefer map.deinit();
        try map.ensureTotalCapacity(max_strings);
        return .{ .allocator = allocator, .table_bytes = table, .table_map = map };
    }

    pub fn deinit(self: *Encoder) void {
        self.table_map.deinit();
        self.allocator.free(self.table_bytes);
    }

    pub fn resetBlock(self: *Encoder) void {
        self.first = true;
        self.prev_ts = 0;
        self.table_len = 0;
        self.table_map.clearRetainingCapacity();
    }

    /// Encode one record into dst. Returns the byte length; the caller owns
    /// block framing. error.DeltaOverflow means the caller must start a block.
    pub fn encode(self: *Encoder, dst: []u8, entry: event.RawEvent) !usize {
        var comm_buf: [max_comm_bytes]u8 = undefined;
        var detail_buf: [max_detail_bytes]u8 = undefined;
        const comm = if (entry.comm.len == 0)
            ""
        else
            privacy.boundComm(entry.comm, &comm_buf);
        const detail = if (entry.detail.len == 0)
            ""
        else
            privacy.redactDetail(entry.detail, &detail_buf);

        var flags: u8 = 0;
        if (entry.pid == entry.tid) flags |= 1;
        if (comm.len != 0) flags |= 2;
        if (detail.len != 0) flags |= 4;
        if (self.first) flags |= 8;

        var new_slot: ?u16 = null;
        var comm_ref: u16 = 0;
        if (comm.len != 0) {
            if (self.table_map.get(comm)) |slot| {
                comm_ref = slot + 1;
            } else {
                // Start a new block instead of emitting a dangling table
                // reference when the block-local table is full.
                if (self.table_len >= max_strings) return error.TableFull;
                flags |= 16;
                new_slot = self.table_len;
            }
        }

        var w = std.Io.Writer.fixed(dst);
        try w.writeByte(@intCast(@backingInt(entry.kind)));
        try w.writeByte(flags);
        if (self.first) {
            try writeUvarint(&w, entry.ts_ns);
        } else {
            const delta: i128 = @as(i128, entry.ts_ns) - @as(i128, self.prev_ts);
            if (delta < std.math.minInt(i64) or delta > std.math.maxInt(i64)) return error.DeltaOverflow;
            try writeZigzag(&w, @intCast(delta));
        }
        try writeZigzag(&w, entry.cpu);
        try writeZigzag(&w, entry.pid);
        if (entry.pid != entry.tid) try writeZigzag(&w, entry.tid);
        try writeUvarint(&w, entry.a);
        try writeUvarint(&w, entry.b);
        try writeUvarint(&w, entry.c);
        if (comm.len != 0) {
            if (new_slot != null) {
                try writeUvarint(&w, comm.len);
                try w.writeAll(comm);
            } else {
                try writeUvarint(&w, comm_ref);
            }
        }
        if (detail.len != 0) {
            try writeUvarint(&w, detail.len);
            try w.writeAll(detail);
        }
        const written = dst[0..w.end].len;

        if (new_slot) |slot| {
            const index: usize = slot;
            @memcpy(self.table_bytes[index][0..comm.len], comm);
            self.table_map.putAssumeCapacity(self.table_bytes[index][0..comm.len], slot);
            self.table_len += 1;
        }
        self.first = false;
        self.prev_ts = entry.ts_ns;
        return written;
    }
};

/// Streaming decoder for one events block payload. Returned strings point into
/// payload; callers that retain them must copy before loading the next block.
pub const Decoder = struct {
    payload: []const u8,
    pos: usize = 0,
    first: bool = true,
    prev_ts: u64 = 0,
    table: [max_strings][]const u8 = undefined,
    table_len: u16 = 0,

    pub fn init(payload: []const u8) Decoder {
        return .{ .payload = payload };
    }

    pub fn next(self: *Decoder) Error!?event.RawEvent {
        if (self.pos >= self.payload.len) return null;
        const data = self.payload;
        if (self.pos + 2 > data.len) return error.TruncatedSegment;
        const kind_byte = data[self.pos];
        if (kind_byte > 17) return error.InvalidSegment;
        const kind = kindFromInt(kind_byte) orelse return error.InvalidSegment;
        const flags = data[self.pos + 1];
        if (flags & 0xe0 != 0) return error.InvalidSegment;
        self.pos += 2;

        var ts: u64 = 0;
        if (flags & 8 != 0) {
            ts = try readUvarint(data, &self.pos);
        } else {
            if (self.first) return error.InvalidSegment;
            const delta = try readZigzag(data, &self.pos);
            const base: i128 = @as(i128, self.prev_ts) + @as(i128, delta);
            if (base < 0 or base > std.math.maxInt(u64)) return error.InvalidSegment;
            ts = @intCast(base);
        }
        const cpu = try readI32(data, &self.pos);
        const pid = try readI32(data, &self.pos);
        const tid = if (flags & 1 != 0) pid else try readI32(data, &self.pos);
        const a = try readUvarint(data, &self.pos);
        const b = try readUvarint(data, &self.pos);
        const c = try readUvarint(data, &self.pos);

        var comm: []const u8 = "";
        if (flags & 2 != 0) {
            if (flags & 16 != 0) {
                const len = try readUvarint(data, &self.pos);
                if (len == 0 or len > max_comm_bytes) return error.InvalidSegment;
                if (self.pos + len > data.len) return error.TruncatedSegment;
                comm = data[self.pos .. self.pos + @as(usize, @intCast(len))];
                self.pos += @intCast(len);
                if (!validWireText(comm)) return error.InvalidSegment;
                if (self.table_len < max_strings) {
                    self.table[self.table_len] = comm;
                    self.table_len += 1;
                }
            } else {
                const ref = try readUvarint(data, &self.pos);
                if (ref == 0 or ref > self.table_len) return error.InvalidSegment;
                comm = self.table[@intCast(ref - 1)];
            }
        }
        var detail: []const u8 = "";
        if (flags & 4 != 0) {
            const len = try readUvarint(data, &self.pos);
            if (len == 0 or len > max_detail_bytes) return error.InvalidSegment;
            if (self.pos + len > data.len) return error.TruncatedSegment;
            detail = data[self.pos .. self.pos + @as(usize, @intCast(len))];
            self.pos += @intCast(len);
            if (!validWireText(detail)) return error.InvalidSegment;
        }
        self.first = false;
        self.prev_ts = ts;
        return event.RawEvent{
            .kind = kind,
            .ts_ns = ts,
            .cpu = cpu,
            .pid = pid,
            .tid = tid,
            .a = a,
            .b = b,
            .c = c,
            .comm = comm,
            .detail = detail,
        };
    }
};

test "header and footer round-trip and reject corruption" {
    const header = Header{ .seq = 7, .start_wall_ns = 100, .start_mono_ns = 200 };
    var hbuf: [header_bytes]u8 = undefined;
    header.write(&hbuf);
    try std.testing.expectEqualStrings("XSPRAWS1", hbuf[0..8]);
    const parsed = try Header.parse(&hbuf);
    try std.testing.expectEqual(@as(u32, 7), parsed.seq);
    try std.testing.expectEqual(@as(u64, 100), parsed.start_wall_ns);
    try std.testing.expectEqual(@as(u64, 200), parsed.start_mono_ns);
    var broken = hbuf;
    broken[57] ^= 1;
    try std.testing.expectError(error.InvalidSegment, Header.parse(&broken));

    const footer = Footer{ .event_count = 9, .block_count = 2, .encoded_bytes = 500 };
    var fbuf: [footer_payload_bytes]u8 = undefined;
    footer.encode(&fbuf);
    const parsed_footer = Footer.parse(&fbuf);
    try std.testing.expectEqual(@as(u64, 9), parsed_footer.event_count);
    try std.testing.expectEqual(@as(u64, 2), parsed_footer.block_count);
    try std.testing.expectEqual(@as(u64, 500), parsed_footer.encoded_bytes);
}

test "all 18 kinds round-trip byte-identically through canonical JSON" {
    var encoder = try Encoder.init(std.testing.allocator);
    defer encoder.deinit();
    var block: [max_block_payload]u8 = undefined;
    var used: usize = 0;
    var expected: [18]event.RawEvent = undefined;
    var count: usize = 0;
    inline for (@typeInfo(event.Kind).@"enum".field_names) |field_name| {
        expected[count] = .{
            .kind = @field(event.Kind, field_name),
            .ts_ns = 1000 + count * 3,
            .cpu = 2,
            .pid = 100 + @as(i32, @intCast(count)),
            .tid = 100 + @as(i32, @intCast(count)),
            .a = count,
            .b = 0,
            .c = 0,
            .comm = "worker",
            .detail = if (@field(event.Kind, field_name) == .marker) "sample_loss dropped=3" else "",
        };
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 18), count);
    for (expected) |entry| used += try encoder.encode(block[used..], entry);
    var decoder = Decoder.init(block[0..used]);
    var seen: usize = 0;
    while (try decoder.next()) |decoded| : (seen += 1) {
        try std.testing.expectEqual(expected[seen].kind, decoded.kind);
        var mine_buf: [2048]u8 = undefined;
        var theirs_buf: [2048]u8 = undefined;
        var mine = std.Io.Writer.fixed(&mine_buf);
        var theirs = std.Io.Writer.fixed(&theirs_buf);
        try event.writeJson(&mine, decoded);
        try event.writeJson(&theirs, expected[seen]);
        try std.testing.expectEqualStrings(theirs.buffered(), mine.buffered());
    }
    try std.testing.expectEqual(@as(usize, 18), seen);
}

test "boundary integers and negative deltas round-trip" {
    var encoder = try Encoder.init(std.testing.allocator);
    defer encoder.deinit();
    var block: [max_block_payload]u8 = undefined;
    var used: usize = 0;
    const events = [_]event.RawEvent{
        .{ .kind = .sched_switch, .ts_ns = 5000, .cpu = -1, .pid = std.math.minInt(i32), .tid = 7, .a = 0, .b = std.math.maxInt(u64), .c = 1, .comm = "same" },
        .{ .kind = .page_fault, .ts_ns = 4000, .cpu = std.math.maxInt(i32), .pid = std.math.maxInt(i32), .tid = std.math.maxInt(i32), .a = std.math.maxInt(u64), .b = 0, .c = std.math.maxInt(u64), .comm = "same" },
        .{ .kind = .marker, .ts_ns = 5000, .cpu = 0, .pid = -1, .tid = -1, .comm = "", .detail = "x=1" },
    };
    for (events) |entry| used += try encoder.encode(block[used..], entry);
    var decoder = Decoder.init(block[0..used]);
    for (events) |wanted| {
        const got = (try decoder.next()).?;
        try std.testing.expectEqual(wanted.kind, got.kind);
        try std.testing.expectEqual(wanted.ts_ns, got.ts_ns);
        try std.testing.expectEqual(wanted.cpu, got.cpu);
        try std.testing.expectEqual(wanted.pid, got.pid);
        try std.testing.expectEqual(wanted.tid, got.tid);
        try std.testing.expectEqual(wanted.a, got.a);
        try std.testing.expectEqual(wanted.b, got.b);
        try std.testing.expectEqual(wanted.c, got.c);
        try std.testing.expectEqualStrings(wanted.comm, got.comm);
        try std.testing.expectEqualStrings(wanted.detail, got.detail);
    }
    try std.testing.expect((try decoder.next()) == null);
}

test "privacy transforms are applied before encoding" {
    var encoder = try Encoder.init(std.testing.allocator);
    defer encoder.deinit();
    var block: [max_block_payload]u8 = undefined;
    const used = try encoder.encode(&block, .{
        .kind = .marker,
        .detail = "token=supersecret-value api_key=abc",
        .comm = "abcdefghijklmnopqrstuvwxyz",
    });
    try std.testing.expect(std.mem.indexOf(u8, block[0..used], "supersecret-value") == null);
    try std.testing.expect(std.mem.indexOf(u8, block[0..used], "[REDACTED]") != null);
    var decoder = Decoder.init(block[0..used]);
    const decoded = (try decoder.next()).?;
    try std.testing.expectEqualStrings("abcdefghijklmno", decoded.comm);
    try std.testing.expect(std.mem.indexOf(u8, decoded.detail, "supersecret-value") == null);
}

test "malformed records are rejected" {
    const invalid_kind = [_]u8{ 18, 8, 1 };
    var decoder_a = Decoder.init(&invalid_kind);
    try std.testing.expectError(error.InvalidSegment, decoder_a.next());

    const reserved_flags = [_]u8{ 0, 8 | 0x20, 1 };
    var decoder_b = Decoder.init(&reserved_flags);
    try std.testing.expectError(error.InvalidSegment, decoder_b.next());

    const missing_table = [_]u8{ 0, 8 | 2, 1, 0, 0, 0, 0, 0, 0, 1 };
    var decoder_c = Decoder.init(&missing_table);
    try std.testing.expectError(error.InvalidSegment, decoder_c.next());

    const long_comm = [_]u8{ 0, 8 | 2 | 16, 1, 0, 0, 0, 0, 0, 0, 16, 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p' };
    var decoder_d = Decoder.init(&long_comm);
    try std.testing.expectError(error.InvalidSegment, decoder_d.next());

    const truncated = [_]u8{ 0, 8, 0x80 };
    var decoder_e = Decoder.init(&truncated);
    try std.testing.expectError(error.TruncatedSegment, decoder_e.next());

    const overlong = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    var decoder_f = Decoder.init(&overlong);
    try std.testing.expectError(error.InvalidSegment, decoder_f.next());
}

test "block headers reject bad sizes and types" {
    var header: [block_header_bytes]u8 = undefined;
    writeBlockHeader(&header, block_type_events, "abc");
    const parsed = try parseBlockHeader(&header);
    try std.testing.expectEqual(block_type_events, parsed.kind);
    try std.testing.expectEqual(@as(u16, 3), parsed.payload_len);

    header[0] = 9;
    try std.testing.expectError(error.InvalidSegment, parseBlockHeader(&header));

    writeBlockHeader(&header, block_type_events, "");
    try std.testing.expectError(error.InvalidSegment, parseBlockHeader(&header));

    var footer: [footer_payload_bytes]u8 = undefined;
    @memset(&footer, 0);
    writeBlockHeader(&header, block_type_footer, &footer);
    try std.testing.expectEqual(block_type_footer, (try parseBlockHeader(&header)).kind);
}

// Checks a full comm table asks for a new block instead of emitting a bad ref.
test "full string table requests a new block" {
    var encoder = try Encoder.init(std.testing.allocator);
    defer encoder.deinit();
    var block: [max_block_payload]u8 = undefined;
    var comm_buffer: [16]u8 = undefined;
    var index: usize = 0;
    while (index < max_strings) : (index += 1) {
        const comm = std.fmt.bufPrint(&comm_buffer, "t{d}", .{index}) catch unreachable;
        _ = try encoder.encode(&block, .{ .kind = .marker, .comm = comm });
    }
    try std.testing.expectError(error.TableFull, encoder.encode(&block, .{ .kind = .marker, .comm = "overflow" }));
    encoder.resetBlock();
    _ = try encoder.encode(&block, .{ .kind = .marker, .comm = "overflow" });
}

// Checks encoder failures on huge timestamp deltas so the writer starts a block.
test "delta overflow requests a new block" {
    var encoder = try Encoder.init(std.testing.allocator);
    defer encoder.deinit();
    var block: [max_block_payload]u8 = undefined;
    var used: usize = try encoder.encode(&block, .{ .kind = .marker, .ts_ns = std.math.maxInt(u64) });
    try std.testing.expectError(error.DeltaOverflow, encoder.encode(block[used..], .{ .kind = .marker, .ts_ns = 0 }));
    encoder.resetBlock();
    used += try encoder.encode(block[used..], .{ .kind = .marker, .ts_ns = 0 });
    var decoder = Decoder.init(block[0..used]);
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), (try decoder.next()).?.ts_ns);
    try std.testing.expectEqual(@as(u64, 0), (try decoder.next()).?.ts_ns);
}
