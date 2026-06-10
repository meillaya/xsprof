const std = @import("std");
const cfs_like = @import("cfs_like.zig");
const deadline = @import("deadline.zig");
const extension = @import("extension.zig");
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
                .fcfs => extension.usesSingleCoreReadyQueue(fcfs),
                .round_robin => extension.usesSingleCoreReadyQueue(round_robin),
                .cfs_like => extension.usesSingleCoreReadyQueue(cfs_like),
                .deadline => extension.usesSingleCoreReadyQueue(deadline),
            };
        }

        pub fn selectNextSingle(self: @This(), ready_queue: *std.ArrayList(usize), runtimes: []const RuntimeTask) ?usize {
            return switch (self.policy) {
                .fcfs => extension.selectNextSingle(RuntimeTask, fcfs, ready_queue, runtimes),
                .round_robin => extension.selectNextSingle(RuntimeTask, round_robin, ready_queue, runtimes),
                .cfs_like => extension.selectNextSingle(RuntimeTask, cfs_like, ready_queue, runtimes),
                .deadline => extension.selectNextSingle(RuntimeTask, deadline, ready_queue, runtimes),
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
            return switch (self.policy) {
                .fcfs => extension.shouldPreemptSingle(RuntimeTask, fcfs, current, current_quantum, quantum, ready_len, runtimes),
                .round_robin => extension.shouldPreemptSingle(RuntimeTask, round_robin, current, current_quantum, quantum, ready_len, runtimes),
                .cfs_like => extension.shouldPreemptSingle(RuntimeTask, cfs_like, current, current_quantum, quantum, ready_len, runtimes),
                .deadline => extension.shouldPreemptSingle(RuntimeTask, deadline, current, current_quantum, quantum, ready_len, runtimes),
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
            return switch (self.policy) {
                .fcfs => extension.keepsRunningSelection(fcfs) and task.state == .running,
                .round_robin => extension.keepsRunningSelection(round_robin) and task.state == .running,
                .cfs_like => extension.keepsRunningSelection(cfs_like) and task.state == .running,
                .deadline => extension.keepsRunningSelection(deadline) and task.state == .running,
            };
        }

        pub fn onTaskTick(self: @This(), task: *RuntimeTask) void {
            switch (self.policy) {
                .fcfs => extension.onTaskTick(fcfs, task),
                .round_robin => extension.onTaskTick(round_robin, task),
                .cfs_like => extension.onTaskTick(cfs_like, task),
                .deadline => extension.onTaskTick(deadline, task),
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
