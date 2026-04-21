const std = @import("std");
const cfs_like = @import("../policies/cfs_like.zig");
const fcfs = @import("../policies/fcfs.zig");
const metrics = @import("metrics.zig");
const round_robin = @import("../policies/round_robin.zig");
const types = @import("types.zig");

const RuntimeTask = struct {
    id: []const u8,
    arrival_tick: u32,
    burst_ticks: u32,
    weight: u32,
    sleep_after_ticks: ?u32,
    sleep_duration: u32,
    input_order: u32,
    assigned_core: types.CoreId = 0,
    remaining_ticks: u32,
    total_executed: u32 = 0,
    blocked_time: u32 = 0,
    first_dispatch_tick: ?u32 = null,
    completion_time: ?u32 = null,
    wake_tick: ?u32 = null,
    last_execution_tick: ?u32 = null,
    vruntime: u64 = 0,
    did_sleep: bool = false,
    state: types.TaskState = .pending,
};

const CoreState = struct {
    ready_queue: std.ArrayList(usize) = .empty,
    current: ?usize = null,
    current_quantum: u32 = 0,

    fn deinit(self: *CoreState, allocator: std.mem.Allocator) void {
        self.ready_queue.deinit(allocator);
    }
};

const ReadyChoice = struct {
    queue_index: usize,
    task_index: usize,
};

const single_core_id: types.CoreId = 0;

pub fn simulate(allocator: std.mem.Allocator, scenario: *const types.ScenarioOwned, policy: types.PolicyKind) !types.SimulationResult {
    if (scenario.tasks.len == 0) return error.EmptyScenario;
    if (scenario.core_count <= 1) return simulateSingleCore(allocator, scenario, policy);
    return simulateMulticore(allocator, scenario, policy);
}

fn simulateSingleCore(allocator: std.mem.Allocator, scenario: *const types.ScenarioOwned, policy: types.PolicyKind) !types.SimulationResult {
    var runtimes = try initRuntimes(allocator, scenario);
    defer allocator.free(runtimes);

    var ready_queue: std.ArrayList(usize) = .empty;
    defer ready_queue.deinit(allocator);

    var trace_entries: std.ArrayList(types.TraceEntry) = .empty;
    defer trace_entries.deinit(allocator);

    var completion_order: std.ArrayList(usize) = .empty;
    defer completion_order.deinit(allocator);

    var current: ?usize = null;
    var current_quantum: u32 = 0;
    var completed: usize = 0;
    var tick: u32 = 0;

    while (completed < runtimes.len) : (tick += 1) {
        try processBlockedSingleCore(allocator, &runtimes, &ready_queue, &trace_entries, tick, policy);
        try enqueueArrivalsSingleCore(allocator, &runtimes, &ready_queue, &trace_entries, tick, policy);

        switch (policy) {
            .fcfs => {},
            .round_robin => {
                if (current) |current_index| {
                    if (round_robin.shouldPreempt(current_quantum, scenario.round_robin_quantum, ready_queue.items.len)) {
                        runtimes[current_index].state = .ready;
                        try ready_queue.append(allocator, current_index);
                        current = null;
                        current_quantum = 0;
                        try trace_entries.append(allocator, .{ .tick = tick, .kind = .preempt, .task_id = runtimes[current_index].id, .core_id = single_core_id });
                    }
                }
            },
            .cfs_like => {
                const best = cfs_like.chooseRunnable(RuntimeTask, runtimes);
                if (current) |current_index| {
                    if (best) |best_index| {
                        if (best_index != current_index) {
                            runtimes[current_index].state = .ready;
                            current = null;
                            current_quantum = 0;
                            try trace_entries.append(allocator, .{ .tick = tick, .kind = .preempt, .task_id = runtimes[current_index].id, .core_id = single_core_id });
                        }
                    }
                }
            },
        }

        if (current == null) {
            const next = switch (policy) {
                .fcfs => fcfs.selectNext(&ready_queue),
                .round_robin => round_robin.selectNext(&ready_queue),
                .cfs_like => cfs_like.chooseRunnable(RuntimeTask, runtimes),
            };

            if (next) |next_index| {
                if (policy == .cfs_like and runtimes[next_index].state == .running) {
                    current = next_index;
                } else {
                    runtimes[next_index].state = .running;
                    runtimes[next_index].assigned_core = single_core_id;
                    if (runtimes[next_index].first_dispatch_tick == null) {
                        runtimes[next_index].first_dispatch_tick = tick;
                    }
                    current = next_index;
                    current_quantum = 0;
                    try trace_entries.append(allocator, .{ .tick = tick, .kind = .dispatch, .task_id = runtimes[next_index].id, .core_id = single_core_id });
                }
            }
        }

        if (current) |current_index| {
            if (runtimes[current_index].first_dispatch_tick == null) {
                runtimes[current_index].first_dispatch_tick = tick;
            }
            if (runtimes[current_index].last_execution_tick == tick) {
                return error.TaskExecutedTwiceInSameTick;
            }

            try trace_entries.append(allocator, .{ .tick = tick, .kind = .tick, .task_id = runtimes[current_index].id, .core_id = single_core_id });
            runtimes[current_index].remaining_ticks -= 1;
            runtimes[current_index].total_executed += 1;
            runtimes[current_index].last_execution_tick = tick;
            current_quantum += 1;
            if (policy == .cfs_like) {
                runtimes[current_index].vruntime += cfs_like.vruntimeDelta(runtimes[current_index].weight);
            }

            if (runtimes[current_index].remaining_ticks == 0) {
                runtimes[current_index].completion_time = tick + 1;
                runtimes[current_index].state = .complete;
                completed += 1;
                try completion_order.append(allocator, current_index);
                try trace_entries.append(allocator, .{ .tick = tick + 1, .kind = .complete, .task_id = runtimes[current_index].id, .core_id = single_core_id });
                current = null;
                current_quantum = 0;
            } else if (shouldBlockAfterExecution(runtimes[current_index])) {
                runtimes[current_index].did_sleep = true;
                runtimes[current_index].state = .blocked;
                runtimes[current_index].wake_tick = tick + 1 + runtimes[current_index].sleep_duration;
                current = null;
                current_quantum = 0;
                try trace_entries.append(allocator, .{ .tick = tick + 1, .kind = .block, .task_id = runtimes[current_index].id, .core_id = single_core_id });
            }
        } else {
            try trace_entries.append(allocator, .{ .tick = tick, .kind = .idle, .task_id = null, .core_id = single_core_id });
        }
    }

    return finalizeResult(allocator, scenario, policy, &trace_entries, &completion_order, runtimes, tick);
}

fn simulateMulticore(allocator: std.mem.Allocator, scenario: *const types.ScenarioOwned, policy: types.PolicyKind) !types.SimulationResult {
    var runtimes = try initRuntimes(allocator, scenario);
    defer allocator.free(runtimes);

    const core_count: usize = @intCast(scenario.core_count);
    const cores = try allocator.alloc(CoreState, core_count);
    defer {
        for (cores) |*core| core.deinit(allocator);
        allocator.free(cores);
    }
    for (cores) |*core| core.* = .{};

    var trace_entries: std.ArrayList(types.TraceEntry) = .empty;
    defer trace_entries.deinit(allocator);

    var completion_order: std.ArrayList(usize) = .empty;
    defer completion_order.deinit(allocator);

    var completed: usize = 0;
    var tick: u32 = 0;

    while (completed < runtimes.len) : (tick += 1) {
        try processBlockedMulticore(allocator, &runtimes, cores, &trace_entries, tick);
        try enqueueArrivalsMulticore(allocator, &runtimes, cores, &trace_entries, tick);
        try preemptMulticore(allocator, scenario, policy, &runtimes, cores, &trace_entries, tick);
        try rebalanceReadyQueues(allocator, &runtimes, cores);
        try dispatchMulticore(allocator, policy, &runtimes, cores, &trace_entries, tick);
        try executeMulticore(allocator, policy, &runtimes, cores, &trace_entries, &completion_order, tick, &completed);
    }

    return finalizeResult(allocator, scenario, policy, &trace_entries, &completion_order, runtimes, tick);
}

fn initRuntimes(allocator: std.mem.Allocator, scenario: *const types.ScenarioOwned) ![]RuntimeTask {
    var runtimes = try allocator.alloc(RuntimeTask, scenario.tasks.len);
    for (scenario.tasks, 0..) |task, index| {
        runtimes[index] = .{
            .id = task.id,
            .arrival_tick = task.arrival_tick,
            .burst_ticks = task.burst_ticks,
            .weight = task.weight,
            .sleep_after_ticks = task.sleep_after_ticks,
            .sleep_duration = task.sleep_duration,
            .input_order = task.input_order,
            .remaining_ticks = task.burst_ticks,
        };
    }
    return runtimes;
}

fn finalizeResult(
    allocator: std.mem.Allocator,
    scenario: *const types.ScenarioOwned,
    policy: types.PolicyKind,
    trace_entries: *std.ArrayList(types.TraceEntry),
    completion_order: *std.ArrayList(usize),
    runtimes: []const RuntimeTask,
    final_tick: u32,
) !types.SimulationResult {
    var task_metrics = try allocator.alloc(types.TaskMetrics, runtimes.len);
    errdefer allocator.free(task_metrics);
    for (runtimes, 0..) |task, index| {
        const completion_time = task.completion_time orelse return error.IncompleteSimulation;
        const first_dispatch_tick = task.first_dispatch_tick orelse return error.NeverDispatchedTask;
        const turnaround = completion_time - task.arrival_tick;
        const response = first_dispatch_tick - task.arrival_tick;
        task_metrics[index] = .{
            .id = try allocator.dupe(u8, task.id),
            .arrival_tick = task.arrival_tick,
            .burst_ticks = task.burst_ticks,
            .weight = task.weight,
            .sleep_after_ticks = task.sleep_after_ticks,
            .sleep_duration = task.sleep_duration,
            .input_order = task.input_order,
            .first_dispatch_tick = first_dispatch_tick,
            .completion_time = completion_time,
            .turnaround_time = turnaround,
            .waiting_time = turnaround - task.burst_ticks - task.blocked_time,
            .blocked_time = task.blocked_time,
            .response_time = response,
            .total_executed = task.total_executed,
        };
    }
    errdefer {
        for (task_metrics) |task| allocator.free(task.id);
        allocator.free(task_metrics);
    }

    return .{
        .allocator = allocator,
        .scenario_name = try allocator.dupe(u8, scenario.name),
        .policy = policy,
        .quantum = scenario.round_robin_quantum,
        .core_count = scenario.core_count,
        .trace = try trace_entries.toOwnedSlice(allocator),
        .tasks = task_metrics,
        .completion_order = try completion_order.toOwnedSlice(allocator),
        .aggregate = metrics.computeAggregate(task_metrics),
        .final_tick = final_tick,
    };
}

fn processBlockedSingleCore(
    allocator: std.mem.Allocator,
    runtimes: *[]RuntimeTask,
    ready_queue: *std.ArrayList(usize),
    trace_entries: *std.ArrayList(types.TraceEntry),
    tick: u32,
    policy: types.PolicyKind,
) !void {
    for (runtimes.*, 0..) |*task, index| {
        if (task.state != .blocked) continue;
        if (task.wake_tick == tick) {
            task.state = .ready;
            task.assigned_core = single_core_id;
            task.wake_tick = null;
            if (policy != .cfs_like) try ready_queue.append(allocator, index);
            try trace_entries.append(allocator, .{ .tick = tick, .kind = .wakeup, .task_id = task.id, .core_id = single_core_id });
        } else {
            task.blocked_time += 1;
        }
    }
}

fn enqueueArrivalsSingleCore(
    allocator: std.mem.Allocator,
    runtimes: *[]RuntimeTask,
    ready_queue: *std.ArrayList(usize),
    trace_entries: *std.ArrayList(types.TraceEntry),
    tick: u32,
    policy: types.PolicyKind,
) !void {
    for (runtimes.*, 0..) |*task, index| {
        if (task.state == .pending and task.arrival_tick == tick) {
            task.assigned_core = single_core_id;
            task.state = .ready;
            if (policy != .cfs_like) try ready_queue.append(allocator, index);
            try trace_entries.append(allocator, .{ .tick = tick, .kind = .arrival, .task_id = task.id, .core_id = single_core_id });
        }
    }
}

fn processBlockedMulticore(
    allocator: std.mem.Allocator,
    runtimes: *[]RuntimeTask,
    cores: []CoreState,
    trace_entries: *std.ArrayList(types.TraceEntry),
    tick: u32,
) !void {
    for (runtimes.*, 0..) |*task, index| {
        if (task.state != .blocked) continue;
        if (task.wake_tick == tick) {
            const core_index: usize = if (task.assigned_core < cores.len) @intCast(task.assigned_core) else 0;
            task.state = .ready;
            task.wake_tick = null;
            try cores[core_index].ready_queue.append(allocator, index);
            try trace_entries.append(allocator, .{ .tick = tick, .kind = .wakeup, .task_id = task.id, .core_id = @intCast(core_index) });
        } else {
            task.blocked_time += 1;
        }
    }
}

fn enqueueArrivalsMulticore(
    allocator: std.mem.Allocator,
    runtimes: *[]RuntimeTask,
    cores: []CoreState,
    trace_entries: *std.ArrayList(types.TraceEntry),
    tick: u32,
) !void {
    for (runtimes.*, 0..) |*task, index| {
        if (task.state == .pending and task.arrival_tick == tick) {
            const core_index = chooseArrivalCore(cores);
            task.assigned_core = @intCast(core_index);
            task.state = .ready;
            try cores[core_index].ready_queue.append(allocator, index);
            try trace_entries.append(allocator, .{ .tick = tick, .kind = .arrival, .task_id = task.id, .core_id = @intCast(core_index) });
        }
    }
}

fn preemptMulticore(
    allocator: std.mem.Allocator,
    scenario: *const types.ScenarioOwned,
    policy: types.PolicyKind,
    runtimes: *[]RuntimeTask,
    cores: []CoreState,
    trace_entries: *std.ArrayList(types.TraceEntry),
    tick: u32,
) !void {
    for (cores, 0..) |*core, core_index| {
        switch (policy) {
            .fcfs => {},
            .round_robin => {
                if (core.current) |current_index| {
                    if (round_robin.shouldPreempt(core.current_quantum, scenario.round_robin_quantum, core.ready_queue.items.len)) {
                        runtimes.*[current_index].state = .ready;
                        try core.ready_queue.append(allocator, current_index);
                        core.current = null;
                        core.current_quantum = 0;
                        try trace_entries.append(allocator, .{ .tick = tick, .kind = .preempt, .task_id = runtimes.*[current_index].id, .core_id = @intCast(core_index) });
                    }
                }
            },
            .cfs_like => {
                if (core.current) |current_index| {
                    if (chooseBestReadyTask(runtimes.*, core.ready_queue.items)) |choice| {
                        const current_task = runtimes.*[current_index];
                        const contender = runtimes.*[choice.task_index];
                        if (cfs_like.betterCandidate(contender.vruntime, contender.input_order, current_task.vruntime, current_task.input_order)) {
                            runtimes.*[current_index].state = .ready;
                            try core.ready_queue.append(allocator, current_index);
                            core.current = null;
                            core.current_quantum = 0;
                            try trace_entries.append(allocator, .{ .tick = tick, .kind = .preempt, .task_id = current_task.id, .core_id = @intCast(core_index) });
                        }
                    }
                }
            },
        }
    }
}

fn rebalanceReadyQueues(
    allocator: std.mem.Allocator,
    runtimes: *[]RuntimeTask,
    cores: []CoreState,
) !void {
    while (firstIdleCore(cores)) |recipient_index| {
        const donor_index = busiestReadyCore(cores, recipient_index) orelse break;
        const donor = &cores[donor_index];
        if (donor.ready_queue.items.len == 0 or coreLoad(donor.*) <= 1) break;

        const migrated_index = donor.ready_queue.orderedRemove(0);
        runtimes.*[migrated_index].assigned_core = @intCast(recipient_index);
        try cores[recipient_index].ready_queue.append(allocator, migrated_index);
    }
}

fn dispatchMulticore(
    allocator: std.mem.Allocator,
    policy: types.PolicyKind,
    runtimes: *[]RuntimeTask,
    cores: []CoreState,
    trace_entries: *std.ArrayList(types.TraceEntry),
    tick: u32,
) !void {
    for (cores, 0..) |*core, core_index| {
        if (core.current != null) continue;

        const next_index = switch (policy) {
            .fcfs => fcfs.selectNext(&core.ready_queue),
            .round_robin => round_robin.selectNext(&core.ready_queue),
            .cfs_like => if (chooseBestReadyTask(runtimes.*, core.ready_queue.items)) |choice|
                core.ready_queue.orderedRemove(choice.queue_index)
            else
                null,
        };

        if (next_index) |task_index| {
            runtimes.*[task_index].state = .running;
            runtimes.*[task_index].assigned_core = @intCast(core_index);
            if (runtimes.*[task_index].first_dispatch_tick == null) {
                runtimes.*[task_index].first_dispatch_tick = tick;
            }
            core.current = task_index;
            core.current_quantum = 0;
            try trace_entries.append(allocator, .{ .tick = tick, .kind = .dispatch, .task_id = runtimes.*[task_index].id, .core_id = @intCast(core_index) });
        }
    }
}

fn executeMulticore(
    allocator: std.mem.Allocator,
    policy: types.PolicyKind,
    runtimes: *[]RuntimeTask,
    cores: []CoreState,
    trace_entries: *std.ArrayList(types.TraceEntry),
    completion_order: *std.ArrayList(usize),
    tick: u32,
    completed: *usize,
) !void {
    var completed_this_tick: std.ArrayList(usize) = .empty;
    defer completed_this_tick.deinit(allocator);

    for (cores, 0..) |*core, core_index| {
        if (core.current) |current_index| {
            if (runtimes.*[current_index].last_execution_tick == tick) {
                return error.TaskExecutedTwiceInSameTick;
            }

            try trace_entries.append(allocator, .{ .tick = tick, .kind = .tick, .task_id = runtimes.*[current_index].id, .core_id = @intCast(core_index) });
            runtimes.*[current_index].remaining_ticks -= 1;
            runtimes.*[current_index].total_executed += 1;
            runtimes.*[current_index].last_execution_tick = tick;
            core.current_quantum += 1;
            if (policy == .cfs_like) {
                runtimes.*[current_index].vruntime += cfs_like.vruntimeDelta(runtimes.*[current_index].weight);
            }

            if (runtimes.*[current_index].remaining_ticks == 0) {
                runtimes.*[current_index].completion_time = tick + 1;
                runtimes.*[current_index].state = .complete;
                completed.* += 1;
                try completed_this_tick.append(allocator, current_index);
                core.current = null;
                core.current_quantum = 0;
            } else if (shouldBlockAfterExecution(runtimes.*[current_index])) {
                runtimes.*[current_index].did_sleep = true;
                runtimes.*[current_index].state = .blocked;
                runtimes.*[current_index].wake_tick = tick + 1 + runtimes.*[current_index].sleep_duration;
                core.current = null;
                core.current_quantum = 0;
                try trace_entries.append(allocator, .{ .tick = tick + 1, .kind = .block, .task_id = runtimes.*[current_index].id, .core_id = @intCast(core_index) });
            }
        } else {
            try trace_entries.append(allocator, .{ .tick = tick, .kind = .idle, .task_id = null, .core_id = @intCast(core_index) });
        }
    }

    for (completed_this_tick.items) |task_index| {
        try completion_order.append(allocator, task_index);
        try trace_entries.append(allocator, .{ .tick = tick + 1, .kind = .complete, .task_id = runtimes.*[task_index].id, .core_id = runtimes.*[task_index].assigned_core });
    }
}

fn chooseArrivalCore(cores: []const CoreState) usize {
    var best_index: usize = 0;
    var best_load: usize = coreLoad(cores[0]);
    for (cores[1..], 1..) |core, index| {
        const load = coreLoad(core);
        if (load < best_load) {
            best_load = load;
            best_index = index;
        }
    }
    return best_index;
}

fn coreLoad(core: CoreState) usize {
    return core.ready_queue.items.len + @intFromBool(core.current != null);
}

fn firstIdleCore(cores: []const CoreState) ?usize {
    for (cores, 0..) |core, index| {
        if (core.current == null and core.ready_queue.items.len == 0) return index;
    }
    return null;
}

fn busiestReadyCore(cores: []const CoreState, exclude: usize) ?usize {
    var best_index: ?usize = null;
    var best_ready_len: usize = 0;
    for (cores, 0..) |core, index| {
        if (index == exclude) continue;
        if (core.ready_queue.items.len == 0) continue;
        if (best_index == null or core.ready_queue.items.len > best_ready_len) {
            best_index = index;
            best_ready_len = core.ready_queue.items.len;
        }
    }
    return best_index;
}

fn chooseBestReadyTask(runtimes: []const RuntimeTask, ready_queue: []const usize) ?ReadyChoice {
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

fn shouldBlockAfterExecution(task: RuntimeTask) bool {
    if (task.did_sleep) return false;
    const sleep_after_ticks = task.sleep_after_ticks orelse return false;
    return task.total_executed == sleep_after_ticks;
}
