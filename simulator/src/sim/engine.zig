const std = @import("std");
const metrics = @import("metrics.zig");
const policy_class_mod = @import("../policies/class.zig");
const types = @import("types.zig");

const RuntimeTask = struct {
    id: []const u8,
    arrival_tick: u32,
    burst_ticks: u32,
    weight: u32,
    effective_weight: u32,
    group_id: ?[]const u8,
    group_index: ?usize,
    group_weight: u32,
    group_quota_ticks: u32,
    sleep_after_ticks: ?u32,
    sleep_duration: u32,
    phases: ?[]const types.TaskPhase,
    deadline_tick: ?u32,
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
    phase_index: usize = 0,
    phase_remaining_ticks: u32,
    state: types.TaskState = .pending,

    fn phaseCount(self: RuntimeTask) u32 {
        if (self.phases) |phases| return @intCast(phases.len);
        return 1;
    }
};

const CoreState = struct {
    ready_queue: std.ArrayList(usize) = .empty,
    current: ?usize = null,
    current_quantum: u32 = 0,
    current_group_index: ?usize = null,
    current_group_run_ticks: u32 = 0,

    fn deinit(self: *CoreState, allocator: std.mem.Allocator) void {
        self.ready_queue.deinit(allocator);
    }
};

const single_core_id: types.CoreId = 0;

pub fn simulate(allocator: std.mem.Allocator, scenario: *const types.ScenarioOwned, policy: types.PolicyKind) !types.SimulationResult {
    if (scenario.tasks.len == 0) return error.EmptyScenario;
    if (scenario.core_count <= 1) return simulateSingleCore(allocator, scenario, policy);
    return simulateMulticore(allocator, scenario, policy);
}

pub fn estimateTraceCapacity(scenario: *const types.ScenarioOwned) usize {
    var cpu_ticks: usize = 0;
    var phase_edges: usize = 0;
    for (scenario.tasks) |task| {
        cpu_ticks += task.burst_ticks;
        phase_edges += if (task.phases) |phases| phases.len else 1;
    }
    const lifecycle_events = scenario.tasks.len * 3;
    const blocking_events = phase_edges * 2;
    const multicore_idle_floor: usize = @intCast(@max(scenario.core_count, 1));
    return @max(cpu_ticks + lifecycle_events + blocking_events + multicore_idle_floor, scenario.tasks.len);
}

fn simulateSingleCore(allocator: std.mem.Allocator, scenario: *const types.ScenarioOwned, policy: types.PolicyKind) !types.SimulationResult {
    var runtimes = try initRuntimes(allocator, scenario);
    defer allocator.free(runtimes);

    var ready_queue: std.ArrayList(usize) = .empty;
    defer ready_queue.deinit(allocator);
    try ready_queue.ensureTotalCapacity(allocator, scenario.tasks.len);

    var trace_entries: std.ArrayList(types.TraceEntry) = .empty;
    defer trace_entries.deinit(allocator);
    try trace_entries.ensureTotalCapacity(allocator, estimateTraceCapacity(scenario));

    var completion_order: std.ArrayList(usize) = .empty;
    defer completion_order.deinit(allocator);
    try completion_order.ensureTotalCapacity(allocator, scenario.tasks.len);

    const policy_class = policy_class_mod.SchedulerClass(RuntimeTask).resolve(policy);

    var current: ?usize = null;
    var current_quantum: u32 = 0;
    var current_group_index: ?usize = null;
    var current_group_run_ticks: u32 = 0;
    var completed: usize = 0;
    var tick: u32 = 0;

    while (completed < runtimes.len) : (tick += 1) {
        var excluded_group_index: ?usize = null;
        try processBlockedSingleCore(allocator, scenario, &runtimes, &ready_queue, &trace_entries, tick, policy_class);
        try enqueueArrivalsSingleCore(allocator, scenario, &runtimes, &ready_queue, &trace_entries, tick, policy_class);

        if (policy_class.shouldPreemptSingle(current, current_quantum, scenario.round_robin_quantum, ready_queue.items.len, runtimes) or shouldPreemptForGroupQuota(policy, current, current_group_run_ticks, runtimes)) {
            const current_index = current.?;
            runtimes[current_index].state = .ready;
            if (policy_class.useSingleCoreReadyQueue()) try ready_queue.append(allocator, current_index);
            if (policy == .cfs_like and shouldPreemptForGroupQuota(policy, current, current_group_run_ticks, runtimes)) {
                excluded_group_index = runtimes[current_index].group_index;
            }
            current = null;
            current_quantum = 0;
            current_group_index = null;
            current_group_run_ticks = 0;
            try trace_entries.append(allocator, .{ .tick = tick, .kind = .preempt, .task_id = runtimes[current_index].id, .group_id = runtimes[current_index].group_id, .domain_id = domainIdForCore(scenario, single_core_id), .core_id = single_core_id });
        }

        if (current == null) {
            const next = if (excluded_group_index != null)
                policy_class.selectNextSingleExcludingGroup(&ready_queue, runtimes, excluded_group_index.?)
            else
                policy_class.selectNextSingle(&ready_queue, runtimes);

            if (next) |next_index| {
                if (policy_class.keepsRunningSelection(runtimes[next_index])) {
                    current = next_index;
                } else {
                    runtimes[next_index].state = .running;
                    runtimes[next_index].assigned_core = single_core_id;
                    if (runtimes[next_index].first_dispatch_tick == null) {
                        runtimes[next_index].first_dispatch_tick = tick;
                    }
                    current = next_index;
                    current_quantum = 0;
                    if (current_group_index != runtimes[next_index].group_index) current_group_run_ticks = 0;
                    current_group_index = runtimes[next_index].group_index;
                    try trace_entries.append(allocator, .{ .tick = tick, .kind = .dispatch, .task_id = runtimes[next_index].id, .group_id = runtimes[next_index].group_id, .domain_id = domainIdForCore(scenario, single_core_id), .core_id = single_core_id });
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

            try trace_entries.append(allocator, .{ .tick = tick, .kind = .tick, .task_id = runtimes[current_index].id, .group_id = runtimes[current_index].group_id, .domain_id = domainIdForCore(scenario, single_core_id), .core_id = single_core_id });
            runtimes[current_index].remaining_ticks -= 1;
            runtimes[current_index].total_executed += 1;
            runtimes[current_index].phase_remaining_ticks -= 1;
            runtimes[current_index].last_execution_tick = tick;
            current_quantum += 1;
            current_group_run_ticks += 1;
            policy_class.onTaskTick(&runtimes[current_index]);

            if (runtimes[current_index].remaining_ticks == 0) {
                runtimes[current_index].completion_time = tick + 1;
                runtimes[current_index].state = .complete;
                completed += 1;
                try completion_order.append(allocator, current_index);
                try trace_entries.append(allocator, .{ .tick = tick + 1, .kind = .complete, .task_id = runtimes[current_index].id, .group_id = runtimes[current_index].group_id, .domain_id = domainIdForCore(scenario, single_core_id), .core_id = single_core_id });
                current = null;
                current_quantum = 0;
                current_group_index = null;
                current_group_run_ticks = 0;
            } else if (try shouldBlockAfterExecution(&runtimes[current_index])) {
                runtimes[current_index].state = .blocked;
                runtimes[current_index].wake_tick = tick + 1 + runtimes[current_index].phase_remaining_ticks;
                current = null;
                current_quantum = 0;
                current_group_index = null;
                current_group_run_ticks = 0;
                try trace_entries.append(allocator, .{ .tick = tick + 1, .kind = .block, .task_id = runtimes[current_index].id, .group_id = runtimes[current_index].group_id, .domain_id = domainIdForCore(scenario, single_core_id), .core_id = single_core_id });
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

    const policy_class = policy_class_mod.SchedulerClass(RuntimeTask).resolve(policy);

    const core_count: usize = @intCast(scenario.core_count);
    const cores = try allocator.alloc(CoreState, core_count);
    defer {
        for (cores) |*core| core.deinit(allocator);
        allocator.free(cores);
    }
    for (cores) |*core| {
        core.* = .{};
        try core.ready_queue.ensureTotalCapacity(allocator, @max(@as(usize, 1), scenario.tasks.len / core_count));
    }

    var trace_entries: std.ArrayList(types.TraceEntry) = .empty;
    defer trace_entries.deinit(allocator);
    try trace_entries.ensureTotalCapacity(allocator, estimateTraceCapacity(scenario));

    var completion_order: std.ArrayList(usize) = .empty;
    defer completion_order.deinit(allocator);
    try completion_order.ensureTotalCapacity(allocator, scenario.tasks.len);

    var completed_this_tick: std.ArrayList(usize) = .empty;
    defer completed_this_tick.deinit(allocator);
    try completed_this_tick.ensureTotalCapacity(allocator, core_count);

    var completed: usize = 0;
    var tick: u32 = 0;

    while (completed < runtimes.len) : (tick += 1) {
        try processBlockedMulticore(allocator, scenario, &runtimes, cores, &trace_entries, tick);
        try enqueueArrivalsMulticore(allocator, scenario, &runtimes, cores, &trace_entries, tick);
        try preemptMulticore(allocator, scenario, policy_class, &runtimes, cores, &trace_entries, tick);
        try rebalanceReadyQueues(allocator, scenario, &runtimes, cores);
        try dispatchMulticore(allocator, scenario, policy_class, &runtimes, cores, &trace_entries, tick);
        try executeMulticore(allocator, scenario, policy_class, &runtimes, cores, &trace_entries, &completion_order, &completed_this_tick, tick, &completed);
    }

    return finalizeResult(allocator, scenario, policy, &trace_entries, &completion_order, runtimes, tick);
}

fn initRuntimes(allocator: std.mem.Allocator, scenario: *const types.ScenarioOwned) ![]RuntimeTask {
    var runtimes = try allocator.alloc(RuntimeTask, scenario.tasks.len);
    for (scenario.tasks, 0..) |task, index| {
        const group_info = if (task.group_id) |group_id|
            findGroupInfo(scenario, group_id)
        else
            null;
        runtimes[index] = .{
            .id = task.id,
            .arrival_tick = task.arrival_tick,
            .burst_ticks = task.burst_ticks,
            .weight = task.weight,
            .effective_weight = combineWeight(task.weight, if (group_info) |info| info.group.weight else types.default_group_weight),
            .group_id = task.group_id,
            .group_index = if (group_info) |info| info.index else null,
            .group_weight = if (group_info) |info| info.group.weight else types.default_group_weight,
            .group_quota_ticks = if (group_info) |info| info.group.quota_ticks else 0,
            .sleep_after_ticks = task.sleep_after_ticks,
            .sleep_duration = task.sleep_duration,
            .phases = task.phases,
            .deadline_tick = task.deadline_tick,
            .input_order = task.input_order,
            .remaining_ticks = task.burst_ticks,
            .phase_remaining_ticks = initialPhaseTicks(task),
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
            .group_id = if (task.group_id) |group_id| try allocator.dupe(u8, group_id) else null,
            .sleep_after_ticks = task.sleep_after_ticks,
            .sleep_duration = task.sleep_duration,
            .phase_count = task.phaseCount(),
            .deadline_tick = task.deadline_tick,
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

    const domains = try dupDomains(allocator, scenario.domains);
    errdefer freeDomains(allocator, domains);
    const groups = try dupGroups(allocator, scenario.groups);
    errdefer freeGroups(allocator, groups);

    return .{
        .allocator = allocator,
        .scenario_name = try allocator.dupe(u8, scenario.name),
        .policy = policy,
        .quantum = scenario.round_robin_quantum,
        .core_count = scenario.core_count,
        .domains = domains,
        .groups = groups,
        .trace = try trace_entries.toOwnedSlice(allocator),
        .tasks = task_metrics,
        .completion_order = try completion_order.toOwnedSlice(allocator),
        .aggregate = metrics.computeAggregate(task_metrics),
        .final_tick = final_tick,
    };
}

fn processBlockedSingleCore(
    allocator: std.mem.Allocator,
    scenario: *const types.ScenarioOwned,
    runtimes: *[]RuntimeTask,
    ready_queue: *std.ArrayList(usize),
    trace_entries: *std.ArrayList(types.TraceEntry),
    tick: u32,
    policy_class: policy_class_mod.SchedulerClass(RuntimeTask),
) !void {
    for (runtimes.*, 0..) |*task, index| {
        if (task.state != .blocked) continue;
        if (task.wake_tick == tick) {
            try advancePhaseAfterWake(task);
            task.state = .ready;
            task.assigned_core = single_core_id;
            task.wake_tick = null;
            if (policy_class.useSingleCoreReadyQueue()) try ready_queue.append(allocator, index);
            try trace_entries.append(allocator, .{ .tick = tick, .kind = .wakeup, .task_id = task.id, .group_id = task.group_id, .domain_id = domainIdForCore(scenario, single_core_id), .core_id = single_core_id });
        } else {
            task.blocked_time += 1;
        }
    }
}

fn enqueueArrivalsSingleCore(
    allocator: std.mem.Allocator,
    scenario: *const types.ScenarioOwned,
    runtimes: *[]RuntimeTask,
    ready_queue: *std.ArrayList(usize),
    trace_entries: *std.ArrayList(types.TraceEntry),
    tick: u32,
    policy_class: policy_class_mod.SchedulerClass(RuntimeTask),
) !void {
    for (runtimes.*, 0..) |*task, index| {
        if (task.state == .pending and task.arrival_tick == tick) {
            task.assigned_core = single_core_id;
            task.state = .ready;
            if (policy_class.useSingleCoreReadyQueue()) try ready_queue.append(allocator, index);
            try trace_entries.append(allocator, .{ .tick = tick, .kind = .arrival, .task_id = task.id, .group_id = task.group_id, .domain_id = domainIdForCore(scenario, single_core_id), .core_id = single_core_id });
        }
    }
}

fn processBlockedMulticore(
    allocator: std.mem.Allocator,
    scenario: *const types.ScenarioOwned,
    runtimes: *[]RuntimeTask,
    cores: []CoreState,
    trace_entries: *std.ArrayList(types.TraceEntry),
    tick: u32,
) !void {
    for (runtimes.*, 0..) |*task, index| {
        if (task.state != .blocked) continue;
        if (task.wake_tick == tick) {
            try advancePhaseAfterWake(task);
            const core_index: usize = if (task.assigned_core < cores.len) @intCast(task.assigned_core) else 0;
            task.state = .ready;
            task.wake_tick = null;
            try cores[core_index].ready_queue.append(allocator, index);
            try trace_entries.append(allocator, .{ .tick = tick, .kind = .wakeup, .task_id = task.id, .group_id = task.group_id, .domain_id = domainIdForCore(scenario, @intCast(core_index)), .core_id = @intCast(core_index) });
        } else {
            task.blocked_time += 1;
        }
    }
}

fn enqueueArrivalsMulticore(
    allocator: std.mem.Allocator,
    scenario: *const types.ScenarioOwned,
    runtimes: *[]RuntimeTask,
    cores: []CoreState,
    trace_entries: *std.ArrayList(types.TraceEntry),
    tick: u32,
) !void {
    for (runtimes.*, 0..) |*task, index| {
        if (task.state == .pending and task.arrival_tick == tick) {
            const core_index = chooseArrivalCore(scenario, cores);
            task.assigned_core = @intCast(core_index);
            task.state = .ready;
            try cores[core_index].ready_queue.append(allocator, index);
            try trace_entries.append(allocator, .{ .tick = tick, .kind = .arrival, .task_id = task.id, .group_id = task.group_id, .domain_id = domainIdForCore(scenario, @intCast(core_index)), .core_id = @intCast(core_index) });
        }
    }
}

fn preemptMulticore(
    allocator: std.mem.Allocator,
    scenario: *const types.ScenarioOwned,
    policy_class: policy_class_mod.SchedulerClass(RuntimeTask),
    runtimes: *[]RuntimeTask,
    cores: []CoreState,
    trace_entries: *std.ArrayList(types.TraceEntry),
    tick: u32,
) !void {
    for (cores, 0..) |*core, core_index| {
        if (policy_class.shouldPreemptCore(core.current, core.current_quantum, scenario.round_robin_quantum, core.ready_queue.items, runtimes.*)) {
            const current_index = core.current.?;
            runtimes.*[current_index].state = .ready;
            try core.ready_queue.append(allocator, current_index);
            core.current = null;
            core.current_quantum = 0;
            try trace_entries.append(allocator, .{ .tick = tick, .kind = .preempt, .task_id = runtimes.*[current_index].id, .group_id = runtimes.*[current_index].group_id, .domain_id = domainIdForCore(scenario, @intCast(core_index)), .core_id = @intCast(core_index) });
        }
    }
}

fn rebalanceReadyQueues(
    allocator: std.mem.Allocator,
    scenario: *const types.ScenarioOwned,
    runtimes: *[]RuntimeTask,
    cores: []CoreState,
) !void {
    while (firstIdleCore(cores)) |recipient_index| {
        const donor_index = chooseDonorCore(scenario, cores, recipient_index) orelse break;
        const donor = &cores[donor_index];
        if (donor.ready_queue.items.len == 0 or coreLoad(donor.*) <= 1) break;

        const migrated_index = donor.ready_queue.orderedRemove(0);
        runtimes.*[migrated_index].assigned_core = @intCast(recipient_index);
        try cores[recipient_index].ready_queue.append(allocator, migrated_index);
    }
}

fn dispatchMulticore(
    allocator: std.mem.Allocator,
    scenario: *const types.ScenarioOwned,
    policy_class: policy_class_mod.SchedulerClass(RuntimeTask),
    runtimes: *[]RuntimeTask,
    cores: []CoreState,
    trace_entries: *std.ArrayList(types.TraceEntry),
    tick: u32,
) !void {
    for (cores, 0..) |*core, core_index| {
        if (core.current != null) continue;

        const next_index = policy_class.selectNextCore(&core.ready_queue, runtimes.*);

        if (next_index) |task_index| {
            runtimes.*[task_index].state = .running;
            runtimes.*[task_index].assigned_core = @intCast(core_index);
            if (runtimes.*[task_index].first_dispatch_tick == null) {
                runtimes.*[task_index].first_dispatch_tick = tick;
            }
            if (core.current_group_index != runtimes.*[task_index].group_index) core.current_group_run_ticks = 0;
            core.current_group_index = runtimes.*[task_index].group_index;
            core.current = task_index;
            core.current_quantum = 0;
            try trace_entries.append(allocator, .{ .tick = tick, .kind = .dispatch, .task_id = runtimes.*[task_index].id, .group_id = runtimes.*[task_index].group_id, .domain_id = domainIdForCore(scenario, @intCast(core_index)), .core_id = @intCast(core_index) });
        }
    }
}

fn executeMulticore(
    allocator: std.mem.Allocator,
    scenario: *const types.ScenarioOwned,
    policy_class: policy_class_mod.SchedulerClass(RuntimeTask),
    runtimes: *[]RuntimeTask,
    cores: []CoreState,
    trace_entries: *std.ArrayList(types.TraceEntry),
    completion_order: *std.ArrayList(usize),
    completed_this_tick: *std.ArrayList(usize),
    tick: u32,
    completed: *usize,
) !void {
    completed_this_tick.items.len = 0;

    for (cores, 0..) |*core, core_index| {
        if (core.current) |current_index| {
            if (runtimes.*[current_index].last_execution_tick == tick) {
                return error.TaskExecutedTwiceInSameTick;
            }

            try trace_entries.append(allocator, .{ .tick = tick, .kind = .tick, .task_id = runtimes.*[current_index].id, .group_id = runtimes.*[current_index].group_id, .domain_id = domainIdForCore(scenario, @intCast(core_index)), .core_id = @intCast(core_index) });
            runtimes.*[current_index].remaining_ticks -= 1;
            runtimes.*[current_index].total_executed += 1;
            runtimes.*[current_index].phase_remaining_ticks -= 1;
            runtimes.*[current_index].last_execution_tick = tick;
            core.current_quantum += 1;
            core.current_group_run_ticks += 1;
            policy_class.onTaskTick(&runtimes.*[current_index]);

            if (runtimes.*[current_index].remaining_ticks == 0) {
                runtimes.*[current_index].completion_time = tick + 1;
                runtimes.*[current_index].state = .complete;
                completed.* += 1;
                try completed_this_tick.append(allocator, current_index);
                core.current = null;
                core.current_quantum = 0;
                core.current_group_index = null;
                core.current_group_run_ticks = 0;
            } else if (try shouldBlockAfterExecution(&runtimes.*[current_index])) {
                runtimes.*[current_index].state = .blocked;
                runtimes.*[current_index].wake_tick = tick + 1 + runtimes.*[current_index].phase_remaining_ticks;
                core.current = null;
                core.current_quantum = 0;
                core.current_group_index = null;
                core.current_group_run_ticks = 0;
                try trace_entries.append(allocator, .{ .tick = tick + 1, .kind = .block, .task_id = runtimes.*[current_index].id, .group_id = runtimes.*[current_index].group_id, .domain_id = domainIdForCore(scenario, @intCast(core_index)), .core_id = @intCast(core_index) });
            }
        } else {
            try trace_entries.append(allocator, .{ .tick = tick, .kind = .idle, .task_id = null, .core_id = @intCast(core_index) });
        }
    }

    for (completed_this_tick.items) |task_index| {
        try completion_order.append(allocator, task_index);
        try trace_entries.append(allocator, .{ .tick = tick + 1, .kind = .complete, .task_id = runtimes.*[task_index].id, .group_id = runtimes.*[task_index].group_id, .domain_id = domainIdForCore(scenario, runtimes.*[task_index].assigned_core), .core_id = runtimes.*[task_index].assigned_core });
    }
}

fn combineWeight(task_weight: u32, group_weight: u32) u32 {
    const combined = (@as(u64, task_weight) * @as(u64, group_weight)) / types.default_group_weight;
    const bounded = @max(@as(u64, 1), @min(combined, types.max_task_weight));
    return @intCast(bounded);
}

const GroupInfo = struct {
    index: usize,
    group: *const types.GroupSpec,
};

fn findGroupInfo(scenario: *const types.ScenarioOwned, id: []const u8) ?GroupInfo {
    for (scenario.groups, 0..) |*group, index| {
        if (std.mem.eql(u8, group.id, id)) return .{ .index = index, .group = group };
    }
    return null;
}

fn dupGroups(allocator: std.mem.Allocator, groups: []const types.GroupSpec) ![]types.GroupSpec {
    const duped = try allocator.alloc(types.GroupSpec, groups.len);
    errdefer allocator.free(duped);
    for (groups, 0..) |group, index| {
        duped[index] = .{ .id = try allocator.dupe(u8, group.id), .weight = group.weight, .quota_ticks = group.quota_ticks };
    }
    return duped;
}

fn freeGroups(allocator: std.mem.Allocator, groups: []types.GroupSpec) void {
    for (groups) |group| allocator.free(group.id);
    allocator.free(groups);
}

fn hasReadyTaskInOtherGroup(runtimes: []const RuntimeTask, current_group_index: ?usize) bool {
    for (runtimes) |task| {
        if (task.state != .ready) continue;
        if (task.group_index != current_group_index) return true;
    }
    return false;
}

fn shouldPreemptForGroupQuota(policy: types.PolicyKind, current: ?usize, current_group_run_ticks: u32, runtimes: []const RuntimeTask) bool {
    const current_index = current orelse return false;
    if (policy != .cfs_like) return false;
    const quota = runtimes[current_index].group_quota_ticks;
    if (quota == 0 or current_group_run_ticks < quota) return false;
    return hasReadyTaskInOtherGroup(runtimes, runtimes[current_index].group_index);
}

fn initialPhaseTicks(task: types.TaskSpec) u32 {
    if (task.phases) |phases| return phases[0].ticks;
    return task.burst_ticks;
}

fn advancePhaseAfterWake(task: *RuntimeTask) !void {
    const phases = task.phases orelse {
        task.phase_remaining_ticks = task.remaining_ticks;
        return;
    };
    if (task.phase_index + 1 >= phases.len) return error.InvalidTaskPhaseTransition;
    task.phase_index += 1;
    if (phases[task.phase_index].kind != .cpu) return error.InvalidTaskPhaseTransition;
    task.phase_remaining_ticks = phases[task.phase_index].ticks;
}

fn dupDomains(allocator: std.mem.Allocator, domains: []const types.DomainSpec) ![]types.DomainSpec {
    const duped = try allocator.alloc(types.DomainSpec, domains.len);
    errdefer allocator.free(duped);
    for (domains, 0..) |domain, index| {
        const cores = try allocator.dupe(types.CoreId, domain.cores);
        errdefer allocator.free(cores);
        duped[index] = .{ .id = try allocator.dupe(u8, domain.id), .cores = cores };
    }
    return duped;
}

fn freeDomains(allocator: std.mem.Allocator, domains: []types.DomainSpec) void {
    for (domains) |*domain| domain.deinit(allocator);
    allocator.free(domains);
}

fn domainIdForCore(scenario: *const types.ScenarioOwned, core_id: types.CoreId) ?[]const u8 {
    const domain = scenario.domainByCore(core_id) orelse return null;
    return domain.id;
}

fn domainLoad(scenario: *const types.ScenarioOwned, cores: []const CoreState, domain: types.DomainSpec) usize {
    var load: usize = 0;
    for (domain.cores) |core_id| load += coreLoad(cores[core_id]);
    _ = scenario;
    return load;
}

fn chooseDonorCore(scenario: *const types.ScenarioOwned, cores: []const CoreState, recipient_index: usize) ?usize {
    if (scenario.domainByCore(@intCast(recipient_index))) |recipient_domain| {
        if (busiestReadyCoreInDomain(cores, recipient_domain, recipient_index)) |same_domain| return same_domain;
    }
    return busiestReadyCore(cores, recipient_index);
}

fn busiestReadyCoreInDomain(cores: []const CoreState, domain: *const types.DomainSpec, exclude: usize) ?usize {
    var best_index: ?usize = null;
    var best_ready_len: usize = 0;
    for (domain.cores) |core_id| {
        const index: usize = @intCast(core_id);
        if (index == exclude) continue;
        if (cores[index].ready_queue.items.len == 0) continue;
        if (best_index == null or cores[index].ready_queue.items.len > best_ready_len) {
            best_index = index;
            best_ready_len = cores[index].ready_queue.items.len;
        }
    }
    return best_index;
}

fn chooseArrivalCore(scenario: *const types.ScenarioOwned, cores: []const CoreState) usize {
    if (scenario.domains.len == 0) {
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

    var best_domain_index: usize = 0;
    var best_domain_load: usize = domainLoad(scenario, cores, scenario.domains[0]);
    for (scenario.domains[1..], 1..) |domain, index| {
        const load = domainLoad(scenario, cores, domain);
        if (load < best_domain_load) {
            best_domain_load = load;
            best_domain_index = index;
        }
    }

    const domain = scenario.domains[best_domain_index];
    var best_core: usize = @intCast(domain.cores[0]);
    var best_core_load: usize = coreLoad(cores[best_core]);
    for (domain.cores[1..]) |core_id| {
        const index: usize = @intCast(core_id);
        const load = coreLoad(cores[index]);
        if (load < best_core_load) {
            best_core = index;
            best_core_load = load;
        }
    }
    return best_core;
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

fn shouldBlockAfterExecution(task: *RuntimeTask) !bool {
    const phases = task.phases orelse return false;
    if (task.phase_remaining_ticks != 0) return false;
    if (task.phase_index + 1 >= phases.len) return false;
    task.phase_index += 1;
    if (phases[task.phase_index].kind != .wait) return error.InvalidTaskPhaseTransition;
    task.phase_remaining_ticks = phases[task.phase_index].ticks;
    return true;
}
