const std = @import("std");
const types = @import("../sim/types.zig");

pub const vruntime_scale: u64 = 4096;
pub const keeps_running_selection = true;

pub fn vruntimeDelta(weight: u32) u64 {
    const divisor = @as(u64, weight);
    return @divFloor(vruntime_scale + divisor - 1, divisor);
}

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

pub fn onTaskTick(task: anytype) void {
    const Task = @TypeOf(task.*);
    const effective_weight = if (@hasField(Task, "effective_weight")) task.effective_weight else task.weight;
    task.vruntime += vruntimeDelta(effective_weight);
}

test "cfs tie breaker falls back to input order" {
    try std.testing.expect(betterCandidate(1, 0, 1, 1));
    try std.testing.expect(!betterCandidate(2, 0, 1, 1));
    _ = types.TaskState.ready;
}

test "higher weights accumulate vruntime more slowly" {
    try std.testing.expect(vruntimeDelta(types.default_task_weight * 2) < vruntimeDelta(types.default_task_weight));
    try std.testing.expect(vruntimeDelta(types.default_task_weight / 2) > vruntimeDelta(types.default_task_weight));
}

test "vruntime weights use bounded integer buckets" {
    try std.testing.expectEqual(vruntimeDelta(2048), vruntimeDelta(2049));
    try std.testing.expect(vruntimeDelta(2048) < vruntimeDelta(1024));
}
