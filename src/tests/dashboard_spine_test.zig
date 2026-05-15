const std = @import("std");

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .unlimited);
}

fn expectContainsAll(haystack: []const u8, needles: []const []const u8) !void {
    for (needles) |needle| try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

test "dashboard docs and build graph expose one smart spine" {
    const allocator = std.testing.allocator;
    const doc = try readFileAlloc(allocator, "docs/smart-dashboard-spine.md");
    defer allocator.free(doc);
    const build_file = try readFileAlloc(allocator, "build.zig");
    defer allocator.free(build_file);

    try expectContainsAll(doc, &.{
        "dashboard home",
        "dashboard scenario",
        "dashboard timeline",
        "dashboard tasks",
        "policy compare",
        "observability screen",
        "performance screen",
        "reports/help",
        "Home",
        "Scenario",
        "Timeline",
        "Tasks/Cores",
        "Policy Compare",
        "Observability",
        "Performance",
        "Reports",
        "Help",
        "no new ad hoc TUI modes",
        "zig build dashboard",
        "ADR 0003",
    });
    try expectContainsAll(build_file, &.{
        "zig_scheduler_dashboard",
        "src/dashboard/root.zig",
        "src/dashboard/main.zig",
        "Render the smart dashboard spine contract",
    });
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
