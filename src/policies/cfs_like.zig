const std = @import("std");
const types = @import("../sim/types.zig");

pub fn betterCandidate(vruntime_a: u64, order_a: u32, vruntime_b: u64, order_b: u32) bool {
    return vruntime_a < vruntime_b or (vruntime_a == vruntime_b and order_a < order_b);
}

pub fn chooseRunnable(comptime RuntimeTask: type, tasks: []const RuntimeTask) ?usize {
    var best_index: ?usize = null;
    var best_vruntime: u64 = 0;
    var best_order: u32 = 0;

    for (tasks, 0..) |task, index| {
        if (task.state != .ready and task.state != .running) continue;
        if (best_index == null or betterCandidate(task.vruntime, task.input_order, best_vruntime, best_order)) {
            best_index = index;
            best_vruntime = task.vruntime;
            best_order = task.input_order;
        }
    }

    return best_index;
}

test "cfs tie breaker falls back to input order" {
    try std.testing.expect(betterCandidate(1, 0, 1, 1));
    try std.testing.expect(!betterCandidate(2, 0, 1, 1));
    _ = types.TaskState.ready;
}
