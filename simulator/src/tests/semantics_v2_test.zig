const std = @import("std");
const sim = @import("../root.zig");

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .unlimited);
}

fn expectContainsAll(haystack: []const u8, needles: []const []const u8) !void {
    for (needles) |needle| try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
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
