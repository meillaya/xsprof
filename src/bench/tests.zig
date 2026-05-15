const std = @import("std");
const bench = @import("root.zig");

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .unlimited);
}

test "benchmark harness markdown stays reproducible" {
    const allocator = std.testing.allocator;
    const expected = try readFileAlloc(allocator, "docs/benchmarks/baselines.md");
    defer allocator.free(expected);
    const actual = try bench.render(allocator, .markdown);
    defer allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

test "benchmark harness json stays reproducible" {
    const allocator = std.testing.allocator;
    const expected = try readFileAlloc(allocator, "docs/benchmarks/baselines.json");
    defer allocator.free(expected);
    const actual = try bench.render(allocator, .json);
    defer allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

test "benchmark harness is repeatable over fixed fixtures" {
    const allocator = std.testing.allocator;
    const first = try bench.render(allocator, .json);
    defer allocator.free(first);
    const second = try bench.render(allocator, .json);
    defer allocator.free(second);
    try std.testing.expectEqualStrings(first, second);
}

test "benchmark docs stay simulator-local and reproducible" {
    const allocator = std.testing.allocator;
    const readme = try readFileAlloc(allocator, "README.md");
    defer allocator.free(readme);
    const workflow = try readFileAlloc(allocator, "docs/benchmark-workflow.md");
    defer allocator.free(workflow);

    try std.testing.expect(std.mem.indexOf(u8, readme, "zig build bench") != null);
    try std.testing.expect(std.mem.indexOf(u8, workflow, "Simulator-local benchmark baseline only") != null);
    try std.testing.expect(std.mem.indexOf(u8, workflow, "repeatability") != null);
}
