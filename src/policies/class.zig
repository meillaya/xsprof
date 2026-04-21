const std = @import("std");
const cfs_like = @import("cfs_like.zig");
const deadline = @import("deadline.zig");
const fcfs = @import("fcfs.zig");
const round_robin = @import("round_robin.zig");
const types = @import("../sim/types.zig");

pub fn SchedulerClass(comptime RuntimeTask: type) type {
    return struct {
        policy: types.PolicyKind,

        pub fn resolve(policy: types.PolicyKind) @This() {
            return .{ .policy = policy };
        }

        pub fn useSingleCoreReadyQueue(self: @This()) bool {
            return switch (self.policy) {
                .fcfs, .round_robin => true,
                .cfs_like, .deadline => false,
            };
        }

        pub fn selectNextSingle(self: @This(), ready_queue: *std.ArrayList(usize), runtimes: []const RuntimeTask) ?usize {
            return switch (self.policy) {
                .fcfs => fcfs.selectNext(ready_queue),
                .round_robin => round_robin.selectNext(ready_queue),
                .cfs_like => cfs_like.chooseRunnable(RuntimeTask, runtimes),
                .deadline => deadline.chooseRunnable(RuntimeTask, runtimes),
            };
        }

        pub fn selectNextCore(self: @This(), ready_queue: *std.ArrayList(usize), runtimes: []const RuntimeTask) ?usize {
            return switch (self.policy) {
                .fcfs => fcfs.selectNext(ready_queue),
                .round_robin => round_robin.selectNext(ready_queue),
                .cfs_like => if (chooseBestReadyTaskByVruntime(RuntimeTask, runtimes, ready_queue.items)) |choice|
                    ready_queue.orderedRemove(choice.queue_index)
                else
                    null,
                .deadline => if (chooseBestReadyTaskByDeadline(RuntimeTask, runtimes, ready_queue.items)) |choice|
                    ready_queue.orderedRemove(choice.queue_index)
                else
                    null,
            };
        }

        pub fn shouldPreemptSingle(
            self: @This(),
            current: ?usize,
            current_quantum: u32,
            quantum: u32,
            ready_len: usize,
            runtimes: []const RuntimeTask,
        ) bool {
            const current_index = current orelse return false;
            return switch (self.policy) {
                .fcfs => false,
                .round_robin => round_robin.shouldPreempt(current_quantum, quantum, ready_len),
                .cfs_like => blk: {
                    const best_index = cfs_like.chooseRunnable(RuntimeTask, runtimes) orelse break :blk false;
                    break :blk best_index != current_index;
                },
                .deadline => blk: {
                    const best_index = deadline.chooseRunnable(RuntimeTask, runtimes) orelse break :blk false;
                    break :blk best_index != current_index;
                },
            };
        }

        pub fn shouldPreemptCore(
            self: @This(),
            current: ?usize,
            current_quantum: u32,
            quantum: u32,
            ready_queue: []const usize,
            runtimes: []const RuntimeTask,
        ) bool {
            const current_index = current orelse return false;
            return switch (self.policy) {
                .fcfs => false,
                .round_robin => round_robin.shouldPreempt(current_quantum, quantum, ready_queue.len),
                .cfs_like => blk: {
                    const choice = chooseBestReadyTaskByVruntime(RuntimeTask, runtimes, ready_queue) orelse break :blk false;
                    const current_task = runtimes[current_index];
                    const contender = runtimes[choice.task_index];
                    break :blk cfs_like.betterCandidate(contender.vruntime, contender.input_order, current_task.vruntime, current_task.input_order);
                },
                .deadline => blk: {
                    const choice = chooseBestReadyTaskByDeadline(RuntimeTask, runtimes, ready_queue) orelse break :blk false;
                    const current_task = runtimes[current_index];
                    const contender = runtimes[choice.task_index];
                    break :blk deadline.betterCandidate(contender.deadline_tick, contender.input_order, current_task.deadline_tick, current_task.input_order);
                },
            };
        }

        pub fn keepsRunningSelection(self: @This(), task: RuntimeTask) bool {
            return (self.policy == .cfs_like or self.policy == .deadline) and task.state == .running;
        }

        pub fn onTaskTick(self: @This(), task: *RuntimeTask) void {
            if (self.policy == .cfs_like) {
                task.vruntime += cfs_like.vruntimeDelta(task.weight);
            }
        }
    };
}

const ReadyChoice = struct {
    queue_index: usize,
    task_index: usize,
};

fn chooseBestReadyTaskByVruntime(comptime RuntimeTask: type, runtimes: []const RuntimeTask, ready_queue: []const usize) ?ReadyChoice {
    var best: ?ReadyChoice = null;
    for (ready_queue, 0..) |task_index, queue_index| {
        if (best == null) {
            best = .{ .queue_index = queue_index, .task_index = task_index };
            continue;
        }

        const current_best = runtimes[best.?.task_index];
        const contender = runtimes[task_index];
        if (cfs_like.betterCandidate(contender.vruntime, contender.input_order, current_best.vruntime, current_best.input_order)) {
            best = .{ .queue_index = queue_index, .task_index = task_index };
        }
    }
    return best;
}

fn chooseBestReadyTaskByDeadline(comptime RuntimeTask: type, runtimes: []const RuntimeTask, ready_queue: []const usize) ?ReadyChoice {
    var best: ?ReadyChoice = null;
    for (ready_queue, 0..) |task_index, queue_index| {
        if (best == null) {
            best = .{ .queue_index = queue_index, .task_index = task_index };
            continue;
        }

        const current_best = runtimes[best.?.task_index];
        const contender = runtimes[task_index];
        if (deadline.betterCandidate(contender.deadline_tick, contender.input_order, current_best.deadline_tick, current_best.input_order)) {
            best = .{ .queue_index = queue_index, .task_index = task_index };
        }
    }
    return best;
}
