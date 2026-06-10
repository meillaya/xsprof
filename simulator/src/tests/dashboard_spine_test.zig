const std = @import("std");

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .unlimited);
}

fn expectContainsAll(haystack: []const u8, needles: []const []const u8) !void {
    for (needles) |needle| try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

test "dashboard home smart dashboard source forbids ad hoc modes and names required screens" {
    const allocator = std.testing.allocator;
    const source = try readFileAlloc(allocator, "src/dashboard/root.zig");
    defer allocator.free(source);

    try expectContainsAll(source, &.{
        "ad_hoc_tui_modes_forbidden = true",
        ".home",
        ".scenario",
        ".timeline",
        ".tasks_cores",
        ".policy_compare",
        ".observability",
        ".performance",
        ".reports",
        ".help",
        "navigation",
    });
}
