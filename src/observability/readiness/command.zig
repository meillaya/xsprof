const std = @import("std");

pub fn runVersion(allocator: std.mem.Allocator, argv: []const []const u8) !?[]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const result = std.process.run(allocator, io, .{ .argv = argv, .stdout_limit = .limited(4096), .stderr_limit = .limited(4096), .expand_arg0 = .expand }) catch return null;
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        allocator.free(result.stdout);
        return null;
    }
    if (std.mem.trim(u8, result.stdout, " \t\r\n").len == 0) {
        allocator.free(result.stdout);
        return null;
    }
    return result.stdout;
}

test "command version parser extracts first integer" {
    try std.testing.expectEqual(@as(?u32, 22), firstVersionMajor("clang version 22.1.6"));
    try std.testing.expectEqual(@as(?u32, 7), firstVersionMajor("bpftool v7.7.0"));
    try std.testing.expectEqual(@as(?u32, null), firstVersionMajor("not a version"));
}

pub fn firstVersionMajor(text: []const u8) ?u32 {
    var i: usize = 0;
    while (i < text.len and !std.ascii.isDigit(text[i])) : (i += 1) {}
    const start = i;
    while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {}
    if (i == start) return null;
    return std.fmt.parseUnsigned(u32, text[start..i], 10) catch null;
}
