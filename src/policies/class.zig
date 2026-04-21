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

        pub fn selectNextSingleExcludingGroup(self: @This(), ready_queue: *std.ArrayList(usize), runtimes: []const RuntimeTask, excluded_group_index: usize) ?usize {
            return switch (self.policy) {
                .fcfs, .round_robin => self.selectNextSingle(ready_queue, runtimes),
                .cfs_like => chooseRunnableByVruntimeExcludingGroup(RuntimeTask, runtimes, excluded_group_index),
                .deadline => chooseRunnableByDeadlineExcludingGroup(RuntimeTask, runtimes, excluded_group_index),
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
                const effective_weight = if (@hasField(RuntimeTask, "effective_weight")) task.effective_weight else task.weight;
                task.vruntime += cfs_like.vruntimeDelta(effective_weight);
            }
        }
    };
}

fn chooseRunnableByVruntimeExcludingGroup(comptime RuntimeTask: type, runtimes: []const RuntimeTask, excluded_group_index: usize) ?usize {
    var best_index: ?usize = null;
    var best_vruntime: u64 = 0;
    var best_order: u32 = 0;
    for (runtimes, 0..) |task, index| {
        if (task.state != .ready and task.state != .running) continue;
        if (task.group_index == excluded_group_index) continue;
        if (best_index == null or cfs_like.betterCandidate(task.vruntime, task.input_order, best_vruntime, best_order)) {
            best_index = index;
            best_vruntime = task.vruntime;
            best_order = task.input_order;
        }
    }
    return best_index;
}

fn chooseRunnableByDeadlineExcludingGroup(comptime RuntimeTask: type, runtimes: []const RuntimeTask, excluded_group_index: usize) ?usize {
    var best_index: ?usize = null;
    var best_deadline: ?u32 = null;
    var best_order: u32 = 0;
    for (runtimes, 0..) |task, index| {
        if (task.state != .ready and task.state != .running) continue;
        if (task.group_index == excluded_group_index) continue;
        if (best_index == null or deadline.betterCandidate(task.deadline_tick, task.input_order, best_deadline, best_order)) {
            best_index = index;
            best_deadline = task.deadline_tick;
            best_order = task.input_order;
        }
    }
    return best_index;
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
