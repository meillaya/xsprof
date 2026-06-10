const std = @import("std");
const sim = @import("../root.zig");

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .unlimited);
}

fn expectContainsAll(haystack: []const u8, needles: []const []const u8) !void {
    for (needles) |needle| try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

test "trace capacity estimator covers curated scenarios" {
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
