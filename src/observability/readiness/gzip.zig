const std = @import("std");

pub fn decompressBytes(allocator: std.mem.Allocator, bytes: []const u8) !?[]u8 {
    if (!isGzip(bytes)) return null;
    var input: std.Io.Reader = .fixed(bytes);
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    var decompressor: std.compress.flate.Decompress = .init(&input, .gzip, &.{});
    _ = decompressor.reader.streamRemaining(&output.writer) catch return null;
    return try output.toOwnedSlice();
}

pub fn isGzip(bytes: []const u8) bool {
    return bytes.len >= 2 and bytes[0] == 0x1f and bytes[1] == 0x8b;
}

test "gzip decompressor handles real gzip fixture bytes" {
    const gz = [_]u8{ 0x1f, 0x8b, 0x08, 0x00, 0xf1, 0x25, 0x2a, 0x6a, 0x02, 0xff, 0xcb, 0xcf, 0xe6, 0x02, 0x00, 0x0f, 0xd2, 0x8e, 0xca, 0x03, 0x00, 0x00, 0x00 };
    const plain = try decompressBytes(std.testing.allocator, &gz) orelse return error.TestExpectedEqual;
    defer std.testing.allocator.free(plain);
    try std.testing.expectEqualStrings("ok\n", plain);
}

test "gzip magic recognizer is exact" {
    try std.testing.expect(isGzip(&.{ 0x1f, 0x8b, 0x08 }));
    try std.testing.expect(!isGzip("CONFIG_BPF=y\n"));
}
