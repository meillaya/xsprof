const std = @import("std");
const types = @import("../../sim/types.zig");

pub const unstable = true;
pub const experimental_key = "lottery";
pub const experimental_display_name = "Experimental lottery-style";
pub const experimental_summary = "Deterministic weight-biased chooser for sandbox experiments only.";

fn ticketScore(weight: u32, vruntime: u64, input_order: u32) i128 {
    return @as(i128, @intCast(weight)) * 4096 - @as(i128, @intCast(vruntime)) - @as(i128, @intCast(input_order));
}

pub fn chooseRunnable(comptime RuntimeTask: type, tasks: []const RuntimeTask) ?usize {
    var best_index: ?usize = null;
    var best_score: i128 = std.math.minInt(i128);

    for (tasks, 0..) |task, index| {
        if (task.state != .ready and task.state != .running) continue;
        const effective_weight = if (@hasField(RuntimeTask, "effective_weight")) task.effective_weight else task.weight;
        const score = ticketScore(effective_weight, task.vruntime, task.input_order);
        if (best_index == null or score > best_score) {
            best_index = index;
            best_score = score;
        }
    }

    return best_index;
}

pub fn onTaskTick(task: anytype) void {
    task.vruntime += 11;
}

test "lottery chooser favors higher effective weight when runtime is equal" {
    const RuntimeTask = struct {
        state: types.TaskState,
        vruntime: u64,
        input_order: u32,
        weight: u32,
        effective_weight: u32,
    };

    const runtimes = [_]RuntimeTask{
        .{ .state = .ready, .vruntime = 0, .input_order = 0, .weight = 1024, .effective_weight = 1024 },
        .{ .state = .ready, .vruntime = 0, .input_order = 1, .weight = 1024, .effective_weight = 4096 },
    };

    try std.testing.expectEqual(@as(?usize, 1), chooseRunnable(RuntimeTask, runtimes[0..]));
}

test "lottery policy remains explicitly unstable" {
    try std.testing.expect(unstable);
}
