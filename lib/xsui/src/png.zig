//! Minimal PNG writer (RGBA8, no filtering, zlib stored blocks). Enough for
//! deterministic headless snapshots without third-party code.

const std = @import("std");
const Writer = std.Io.Writer;

fn writeU32(w: *Writer, value: u32) Writer.Error!void {
    try w.writeAll(&.{
        @intCast(value >> 24),
        @intCast((value >> 16) & 0xff),
        @intCast((value >> 8) & 0xff),
        @intCast(value & 0xff),
    });
}

fn adler32(data: []const u8) u32 {
    var a: u32 = 1;
    var b: u32 = 0;
    for (data) |byte| {
        a = (a + byte) % 65521;
        b = (b + a) % 65521;
    }
    return (b << 16) | a;
}

fn writeChunk(w: *Writer, tag: *const [4]u8, payload: []const u8) Writer.Error!void {
    try writeU32(w, @intCast(payload.len));
    try w.writeAll(tag);
    try w.writeAll(payload);
    var crc: u32 = updateCrc(0xffffffff, tag);
    crc = updateCrc(crc, payload);
    try writeU32(w, ~crc);
}

fn updateCrc(start: u32, data: []const u8) u32 {
    var crc = start;
    for (data) |byte| {
        crc ^= byte;
        var bit: u8 = 0;
        while (bit < 8) : (bit += 1) {
            const mask: u32 = @as(u32, 0) -% (crc & 1);
            crc = (crc >> 1) ^ (0xedb88320 & mask);
        }
    }
    return crc;
}

pub fn write(
    w: *Writer,
    width: u32,
    height: u32,
    rgba: []const u8,
) !void {
    try w.writeAll(&.{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' });
    var ihdr: [13]u8 = undefined;
    ihdr[0] = @intCast(width >> 24);
    ihdr[1] = @intCast((width >> 16) & 0xff);
    ihdr[2] = @intCast((width >> 8) & 0xff);
    ihdr[3] = @intCast(width & 0xff);
    ihdr[4] = @intCast(height >> 24);
    ihdr[5] = @intCast((height >> 16) & 0xff);
    ihdr[6] = @intCast((height >> 8) & 0xff);
    ihdr[7] = @intCast(height & 0xff);
    ihdr[8] = 8;
    ihdr[9] = 6;
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try writeChunk(w, "IHDR", &ihdr);

    const ww: usize = width;
    const hh: usize = height;
    const stride = ww * 4 + 1;
    const raw_len = hh * stride;
    var raw = try std.heap.page_allocator.alloc(u8, raw_len);
    defer std.heap.page_allocator.free(raw);
    var y: usize = 0;
    while (y < hh) : (y += 1) {
        raw[y * stride] = 0;
        @memcpy(raw[y * stride + 1 ..][0 .. ww * 4], rgba[y * ww * 4 ..][0 .. ww * 4]);
    }

    var zlib = std.ArrayList(u8).empty;
    defer zlib.deinit(std.heap.page_allocator);
    try zlib.append(std.heap.page_allocator, 0x78);
    try zlib.append(std.heap.page_allocator, 0x01);
    var offset: usize = 0;
    while (offset < raw.len) {
        const block = @min(raw.len - offset, 65535);
        try zlib.append(std.heap.page_allocator, if (offset + block == raw.len) 1 else 0);
        try zlib.append(std.heap.page_allocator, @intCast(block & 0xff));
        try zlib.append(std.heap.page_allocator, @intCast((block >> 8) & 0xff));
        try zlib.append(std.heap.page_allocator, @intCast((~block) & 0xff));
        try zlib.append(std.heap.page_allocator, @intCast(((~block) >> 8) & 0xff));
        try zlib.appendSlice(std.heap.page_allocator, raw[offset .. offset + block]);
        offset += block;
    }
    const adler = adler32(raw);
    try zlib.append(std.heap.page_allocator, @intCast(adler >> 24));
    try zlib.append(std.heap.page_allocator, @intCast((adler >> 16) & 0xff));
    try zlib.append(std.heap.page_allocator, @intCast((adler >> 8) & 0xff));
    try zlib.append(std.heap.page_allocator, @intCast(adler & 0xff));
    try writeChunk(w, "IDAT", zlib.items);
    try writeChunk(w, "IEND", &.{});
}

test "png writer emits a valid signature and chunks" {
    var buf: [1024]u8 = undefined;
    var w = Writer.fixed(&buf);
    const rgba = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255 };
    try write(&w, 2, 2, &rgba);
    const out = w.buffered();
    try std.testing.expect(out.len > 8);
    try std.testing.expectEqualSlices(u8, &.{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' }, out[0..8]);
    try std.testing.expectEqualStrings("IHDR", out[12..16]);
    try std.testing.expect(std.mem.indexOf(u8, out, "IDAT") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "IEND") != null);
    try std.testing.expectEqual(@as(u32, 0xae426082), std.mem.readInt(u32, out[out.len - 4 ..][0..4], .big));
}
