const std = @import("std");
const bench = @import("root.zig");

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .unlimited);
}

test "benchmark harness is repeatable over fixed fixtures" {
    const allocator = std.testing.allocator;
    const first = try bench.render(allocator, .json);
    defer allocator.free(first);
    const second = try bench.render(allocator, .json);
    defer allocator.free(second);
    try std.testing.expectEqualStrings(first, second);
}
