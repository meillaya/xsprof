const std = @import("std");

pub fn betterCandidate(deadline_a: ?u32, order_a: u32, deadline_b: ?u32, order_b: u32) bool {
    const lhs = deadline_a orelse std.math.maxInt(u32);
    const rhs = deadline_b orelse std.math.maxInt(u32);
    return lhs < rhs or (lhs == rhs and order_a < order_b);
}

pub fn chooseRunnable(comptime RuntimeTask: type, tasks: []const RuntimeTask) ?usize {
    var best_index: ?usize = null;
    var best_deadline: ?u32 = null;
    var best_order: u32 = 0;

    for (tasks, 0..) |task, index| {
        if (task.state != .ready and task.state != .running) continue;
        if (best_index == null or betterCandidate(task.deadline_tick, task.input_order, best_deadline, best_order)) {
            best_index = index;
            best_deadline = task.deadline_tick;
            best_order = task.input_order;
        }
    }

    return best_index;
}

test "deadline ordering falls back to input order" {
    try std.testing.expect(betterCandidate(5, 0, 5, 1));
    try std.testing.expect(!betterCandidate(7, 1, 5, 0));
    try std.testing.expect(!betterCandidate(null, 0, 9, 1));
}
