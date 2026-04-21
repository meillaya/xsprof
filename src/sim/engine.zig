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
    input_order: u32,
    remaining_ticks: u32,
    total_executed: u32 = 0,
    first_dispatch_tick: ?u32 = null,
    completion_time: ?u32 = null,
    last_execution_tick: ?u32 = null,
    vruntime: u64 = 0,
    state: types.TaskState = .pending,
};

const single_core_id: types.CoreId = 0;

pub fn simulate(allocator: std.mem.Allocator, scenario: *const types.ScenarioOwned, policy: types.PolicyKind) !types.SimulationResult {
    if (scenario.tasks.len == 0) return error.EmptyScenario;

    var runtimes = try allocator.alloc(RuntimeTask, scenario.tasks.len);
    defer allocator.free(runtimes);
    for (scenario.tasks, 0..) |task, index| {
        runtimes[index] = .{
            .id = task.id,
            .arrival_tick = task.arrival_tick,
            .burst_ticks = task.burst_ticks,
            .weight = task.weight,
            .input_order = task.input_order,
            .remaining_ticks = task.burst_ticks,
        };
    }

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
        for (runtimes, 0..) |*task, index| {
            if (task.state == .pending and task.arrival_tick == tick) {
                task.state = .ready;
                if (policy != .cfs_like) try ready_queue.append(allocator, index);
                try trace_entries.append(allocator, .{ .tick = tick, .kind = .arrival, .task_id = task.id });
            }
        }

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
            if (policy == .cfs_like) runtimes[current_index].vruntime += cfs_like.vruntimeDelta(runtimes[current_index].weight);

            if (runtimes[current_index].remaining_ticks == 0) {
                runtimes[current_index].completion_time = tick + 1;
                runtimes[current_index].state = .complete;
                completed += 1;
                try completion_order.append(allocator, current_index);
                try trace_entries.append(allocator, .{ .tick = tick + 1, .kind = .complete, .task_id = runtimes[current_index].id, .core_id = single_core_id });
                current = null;
                current_quantum = 0;
            }
        } else {
            try trace_entries.append(allocator, .{ .tick = tick, .kind = .idle, .task_id = null, .core_id = single_core_id });
        }
    }

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
            .input_order = task.input_order,
            .first_dispatch_tick = first_dispatch_tick,
            .completion_time = completion_time,
            .turnaround_time = turnaround,
            .waiting_time = turnaround - task.burst_ticks,
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
        .core_count = 1,
        .trace = try trace_entries.toOwnedSlice(allocator),
        .tasks = task_metrics,
        .completion_order = try completion_order.toOwnedSlice(allocator),
        .aggregate = metrics.computeAggregate(task_metrics),
        .final_tick = tick,
    };
}
