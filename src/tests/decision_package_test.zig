const std = @import("std");

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .unlimited);
}

fn expectContainsAll(haystack: []const u8, needles: []const []const u8) !void {
    for (needles) |needle| try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

test "release decision decision reaffirms deferred production runtime" {
    const allocator = std.testing.allocator;
    const adr = try readFileAlloc(allocator, "docs/adr/0004-lts-simulator-lab-release.md");
    defer allocator.free(adr);

    try expectContainsAll(adr, &.{
        "Status: Approved",
        "does **not** re-charter production runtime work",
        "LTS simulator-lab release",
        "ADR 0003 still controls",
        "separate branch",
        "superseding ADR",
    });
}

test "release plan package lists release evidence and forbids runtime authorization" {
    const allocator = std.testing.allocator;
    const plan = try readFileAlloc(allocator, "docs/lts-simulator-lab-release-plan.md");
    defer allocator.free(plan);

    try expectContainsAll(plan, &.{
        "does not authorize daemon, service, agent, production runtime",
        "zig build quality",
        "zig build perf",
        "zig build dashboard",
        "zig build semantics",
        "zig build reports -- --check",
        "final ai-slop-cleaner pass",
        "APPROVE with architecture status CLEAR",
        "Future runtime branch prerequisites",
    });
}
