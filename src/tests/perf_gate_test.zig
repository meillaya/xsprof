const std = @import("std");
const sim = @import("../root.zig");

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .unlimited);
}

fn expectContainsAll(haystack: []const u8, needles: []const []const u8) !void {
    for (needles) |needle| try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

test "M47-M56 performance docs and build graph expose reproducible perf gate" {
    const allocator = std.testing.allocator;
    const doc = try readFileAlloc(allocator, "docs/performance-gates.md");
    defer allocator.free(doc);
    const build_file = try readFileAlloc(allocator, "build.zig");
    defer allocator.free(build_file);

    try expectContainsAll(doc, &.{
        "M47 benchmark baseline",
        "M48 reviewed budgets",
        "M49 engine allocation reduction",
        "M50 trace storage scaling",
        "M51 policy hot path optimization",
        "M52 scenario parser optimization",
        "M53 report export streaming",
        "M54 dashboard render performance",
        "M55 analysis pipeline performance",
        "M56 reproducible perf gate",
        "zig build perf",
        "ADR 0003",
    });
    try expectContainsAll(build_file, &.{
        "zig_scheduler_perf",
        "src/perf/root.zig",
        "src/perf/main.zig",
        "Check reproducible simulator-local performance budgets",
    });
}

test "M49-M50 trace capacity estimator covers curated scenarios" {
    const allocator = std.testing.allocator;
    const cases = [_][]const u8{
        "short-vs-long",
        "multi-phase-io",
        "multicore-contention",
        "topology-domains",
    };

    for (cases) |name| {
        var scenario = try sim.loadScenarioByName(allocator, name);
        defer scenario.deinit();
        const estimate = sim.estimateTraceCapacity(&scenario);
        try std.testing.expect(estimate >= scenario.tasks.len);

        var result = try sim.simulate(allocator, &scenario, .round_robin);
        defer result.deinit();
        try std.testing.expect(result.trace.len <= estimate or result.trace.len <= estimate + scenario.tasks.len * @as(usize, scenario.core_count));
    }
}
