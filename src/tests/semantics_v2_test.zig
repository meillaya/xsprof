const std = @import("std");
const sim = @import("../root.zig");

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .unlimited);
}

fn expectContainsAll(haystack: []const u8, needles: []const []const u8) !void {
    for (needles) |needle| try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

test "scheduler semantics docs and build graph expose v2 contract" {
    const allocator = std.testing.allocator;
    const doc = try readFileAlloc(allocator, "docs/scheduler-semantics-v2.md");
    defer allocator.free(doc);
    const build_file = try readFileAlloc(allocator, "build.zig");
    defer allocator.free(build_file);

    try expectContainsAll(doc, &.{
        "semantics contract",
        "priority mapping",
        "fairness model",
        "deadline admission",
        "runqueue model",
        "affinity model",
        "topology model",
        "group budget model",
        "decision log",
        "replay diff",
        "zig build semantics",
        "ADR 0003",
        "no daemon, service, agent",
    });
    try expectContainsAll(build_file, &.{
        "zig_scheduler_semantics",
        "src/semantics/root.zig",
        "src/semantics/main.zig",
        "Render the scheduling semantics v2 contract",
    });
}

test "scheduler semantics API remains deterministic and bounded" {
    try std.testing.expectEqualStrings("zig-scheduler/scheduling-semantics-v2", sim.semantics.contract_name);
    try std.testing.expectEqual(@as(u32, 2), sim.semantics.contract_version);
    try std.testing.expectEqual(@as(usize, 10), sim.semantics.features.len);
    try std.testing.expect(sim.semantics.niceToWeight(-1) > sim.semantics.niceToWeight(1));
    try std.testing.expect(sim.semantics.priorityFromNice(-20) < sim.semantics.priorityFromNice(19));
    try std.testing.expect(sim.semantics.fairnessScore(.{ .vruntime = 100, .nice = -5 }) < sim.semantics.fairnessScore(.{ .vruntime = 100, .nice = 5 }));
    try std.testing.expect(sim.semantics.admitDeadline(.{ .arrival_tick = 0, .runtime_ticks = 2, .deadline_tick = 3 }));
    try std.testing.expect(!sim.semantics.admitDeadline(.{ .arrival_tick = 0, .runtime_ticks = 4, .deadline_tick = 3 }));
}
