const std = @import("std");
const sim = @import("../root.zig");

fn loadShortVsLong(allocator: std.mem.Allocator) !sim.ScenarioOwned {
    return sim.loadScenarioByName(allocator, "short-vs-long");
}

fn loadWeightedFixture(allocator: std.mem.Allocator) !sim.ScenarioOwned {
    return sim.loadScenarioFile(allocator, "scenarios/basic/weighted-fairness.zon");
}

fn loadMulticoreFixture(allocator: std.mem.Allocator) !sim.ScenarioOwned {
    return sim.loadScenarioFile(allocator, "scenarios/basic/multicore-contention.zon");
}

fn loadBalancingFixture(allocator: std.mem.Allocator) !sim.ScenarioOwned {
    return sim.loadScenarioFile(allocator, "scenarios/basic/multicore-balancing.zon");
}

fn loadStaggeredMulticoreFixture(allocator: std.mem.Allocator) !sim.ScenarioOwned {
    return sim.loadScenarioFile(allocator, "scenarios/basic/multicore-staggered.zon");
}

fn loadWeightedMulticoreFixture(allocator: std.mem.Allocator) !sim.ScenarioOwned {
    return sim.loadScenarioFile(allocator, "scenarios/basic/multicore-weighted.zon");
}

fn loadSimultaneousFixture(allocator: std.mem.Allocator) !sim.ScenarioOwned {
    return sim.loadScenarioFile(allocator, "scenarios/basic/multicore-simultaneous-complete.zon");
}

fn loadMulticoreRrFixture(allocator: std.mem.Allocator) !sim.ScenarioOwned {
    return sim.loadScenarioFile(allocator, "scenarios/basic/multicore-rr-quantum.zon");
}

fn loadSleepWakeFixture(allocator: std.mem.Allocator) !sim.ScenarioOwned {
    return sim.loadScenarioFile(allocator, "scenarios/basic/sleep-wakeup.zon");
}

fn expectNoExecutionWhileBlocked(trace: []const sim.TraceEntry, task_id: []const u8) !void {
    var blocked = false;
    for (trace) |entry| {
        if (entry.task_id == null or !std.mem.eql(u8, entry.task_id.?, task_id)) continue;
        switch (entry.kind) {
            .block => blocked = true,
            .wakeup => blocked = false,
            .dispatch, .tick => try std.testing.expect(!blocked),
            else => {},
        }
    }
}

test "blocked-state scenario records deterministic block and wakeup transitions" {
    const allocator = std.testing.allocator;
    var scenario = try loadSleepWakeFixture(allocator);
    defer scenario.deinit();

    var result = try sim.simulate(allocator, &scenario, .fcfs);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.completion_order.len);
    try std.testing.expectEqualStrings("B", result.completionTaskId(0));
    try std.testing.expectEqualStrings("A", result.completionTaskId(1));

    var saw_block = false;
    var saw_wakeup = false;
    for (result.trace) |entry| {
        if (entry.task_id == null or !std.mem.eql(u8, entry.task_id.?, "A")) continue;
        if (entry.kind == .block) {
            try std.testing.expectEqual(@as(u32, 2), entry.tick);
            saw_block = true;
        }
        if (entry.kind == .wakeup) {
            try std.testing.expectEqual(@as(u32, 4), entry.tick);
            saw_wakeup = true;
        }
    }
    try std.testing.expect(saw_block);
    try std.testing.expect(saw_wakeup);
    try expectNoExecutionWhileBlocked(result.trace, "A");

    const task_a = result.taskById("A") orelse return error.MissingTaskA;
    const task_b = result.taskById("B") orelse return error.MissingTaskB;
    try std.testing.expectEqual(@as(u32, 2), task_a.blocked_time);
    try std.testing.expectEqual(@as(u32, 0), task_a.waiting_time);
    try std.testing.expectEqual(@as(u32, 0), task_b.blocked_time);
}

test "blocked-state semantics stay deterministic across repeated runs" {
    const allocator = std.testing.allocator;
    var scenario = try loadSleepWakeFixture(allocator);
    defer scenario.deinit();

    const policies = [_]sim.PolicyKind{ .fcfs, .round_robin, .cfs_like };
    for (policies) |policy| {
        var first = try sim.simulate(allocator, &scenario, policy);
        defer first.deinit();
        var second = try sim.simulate(allocator, &scenario, policy);
        defer second.deinit();

        try std.testing.expectEqual(first.trace.len, second.trace.len);
        for (first.trace, second.trace) |lhs, rhs| {
            try std.testing.expectEqual(lhs.tick, rhs.tick);
            try std.testing.expectEqual(lhs.kind, rhs.kind);
            try std.testing.expectEqual(lhs.core_id, rhs.core_id);
            try std.testing.expectEqualStrings(lhs.task_id orelse "", rhs.task_id orelse "");
        }
    }
}

fn taskIndexById(tasks: []const sim.TaskMetrics, id: []const u8) ?usize {
    for (tasks, 0..) |task, index| {
        if (std.mem.eql(u8, task.id, id)) return index;
    }
    return null;
}

fn expectNoDuplicateTaskTicksPerTick(trace: []const sim.TraceEntry) !void {
    for (trace, 0..) |entry, index| {
        if (entry.kind != .tick) continue;
        const task_id = entry.task_id orelse return error.MissingTaskId;
        for (trace[index + 1 ..]) |other| {
            if (other.tick != entry.tick) continue;
            if (other.kind != .tick) continue;
            try std.testing.expect(!std.mem.eql(u8, task_id, other.task_id orelse return error.MissingTaskId));
        }
    }
}

test "scenario parser loads deterministic task order" {
    const allocator = std.testing.allocator;
    var scenario = try sim.loadScenarioByName(allocator, "staggered-arrivals");
    defer scenario.deinit();

    try std.testing.expectEqualStrings("staggered-arrivals", scenario.name);
    try std.testing.expectEqual(@as(u32, 2), scenario.round_robin_quantum);
    try std.testing.expectEqual(@as(usize, 3), scenario.tasks.len);
    try std.testing.expectEqualStrings("A", scenario.tasks[0].id);
    try std.testing.expectEqual(@as(u32, 4), scenario.tasks[2].arrival_tick);
}

test "engine records idle ticks before first arrival" {
    const allocator = std.testing.allocator;
    var scenario = try sim.parseScenarioText(
        allocator,
        "name: delayed\nrr_quantum: 2\ntask: X 2 1\n",
        "delayed",
    );
    defer scenario.deinit();

    var result = try sim.simulate(allocator, &scenario, .fcfs);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 6), result.trace.len);
    try std.testing.expectEqual(sim.TraceEventKind.idle, result.trace[0].kind);
    try std.testing.expectEqual(@as(u32, 0), result.trace[0].tick);
    try std.testing.expectEqual(sim.TraceEventKind.idle, result.trace[1].kind);
    try std.testing.expectEqual(@as(u32, 1), result.trace[1].tick);
    try std.testing.expectEqual(sim.TraceEventKind.arrival, result.trace[2].kind);
}

test "simulation terminates with consistent per-task accounting" {
    const allocator = std.testing.allocator;
    var scenario = try loadShortVsLong(allocator);
    defer scenario.deinit();

    var result = try sim.simulate(allocator, &scenario, .fcfs);
    defer result.deinit();

    for (result.tasks) |task| {
        try std.testing.expectEqual(task.burst_ticks, task.total_executed);
        try std.testing.expect(task.completion_time >= task.arrival_tick);
        try std.testing.expect(task.waiting_time <= task.turnaround_time);
    }
}

test "simulation never records the same task executing twice in one tick" {
    const allocator = std.testing.allocator;
    var short_vs_long = try loadShortVsLong(allocator);
    defer short_vs_long.deinit();

    const weighted_source =
        \\.{
        \\    .name = "weighted-no-double-run",
        \\    .tasks = .{
        \\        .{ .id = "light", .arrival_tick = 0, .burst_ticks = 4, .weight = 512 },
        \\        .{ .id = "heavy", .arrival_tick = 0, .burst_ticks = 4, .weight = 2048 },
        \\        .{ .id = "default", .arrival_tick = 0, .burst_ticks = 2 },
        \\    },
        \\}
    ;
    var weighted = try sim.parseScenarioText(allocator, weighted_source, "weighted-no-double-run");
    defer weighted.deinit();

    const cases = [_]struct {
        policy: sim.PolicyKind,
        scenario: *const sim.ScenarioOwned,
    }{
        .{ .policy = .fcfs, .scenario = &short_vs_long },
        .{ .policy = .round_robin, .scenario = &short_vs_long },
        .{ .policy = .cfs_like, .scenario = &short_vs_long },
        .{ .policy = .cfs_like, .scenario = &weighted },
    };

    for (cases) |case| {
        var result = try sim.simulate(allocator, case.scenario, case.policy);
        defer result.deinit();

        try expectNoDuplicateTaskTicksPerTick(result.trace);
    }
}

test "per-core execution reconciliation matches task totals and total work" {
    const allocator = std.testing.allocator;
    const multicore_fixture_paths = [_][]const u8{
        "scenarios/basic/multicore-contention.zon",
        "scenarios/basic/multicore-balancing.zon",
        "scenarios/basic/multicore-staggered.zon",
        "scenarios/basic/multicore-weighted.zon",
        "scenarios/basic/multicore-simultaneous-complete.zon",
        "scenarios/basic/multicore-rr-quantum.zon",
    };

    var weighted = try loadWeightedFixture(allocator);
    defer weighted.deinit();

    const cases = [_]struct {
        scenario: *const sim.ScenarioOwned,
        policies: []const sim.PolicyKind,
    }{
        .{ .scenario = &weighted, .policies = &.{ .fcfs, .round_robin, .cfs_like } },
    };

    for (cases) |case| {
        for (case.policies) |policy| {
            var result = try sim.simulate(allocator, case.scenario, policy);
            defer result.deinit();
            try reconcileExecutionAccounting(allocator, result);
        }
    }

    for (multicore_fixture_paths) |path| {
        var scenario = try sim.loadScenarioFile(allocator, path);
        defer scenario.deinit();

        const policies = [_]sim.PolicyKind{ .fcfs, .round_robin, .cfs_like };
        for (policies) |policy| {
            var result = try sim.simulate(allocator, &scenario, policy);
            defer result.deinit();
            try reconcileExecutionAccounting(allocator, result);
        }
    }
}

fn reconcileExecutionAccounting(allocator: std.mem.Allocator, result: sim.SimulationResult) !void {
    try expectNoDuplicateTaskTicksPerTick(result.trace);

    const core_count: usize = @intCast(result.core_count);
    try std.testing.expect(core_count >= 1);

    const per_core = try allocator.alloc(u32, core_count);
    defer allocator.free(per_core);
    @memset(per_core, 0);

    const per_task = try allocator.alloc(u32, result.tasks.len);
    defer allocator.free(per_task);
    @memset(per_task, 0);

    var total_tick_events: u32 = 0;
    for (result.trace) |entry| {
        if (entry.kind != .tick) continue;

        const core_id = entry.core_id orelse return error.MissingCoreIdentity;
        try std.testing.expect(core_id < result.core_count);

        const core_index: usize = @intCast(core_id);
        per_core[core_index] += 1;
        total_tick_events += 1;

        const task_id = entry.task_id orelse return error.MissingTaskId;
        const task_index = taskIndexById(result.tasks, task_id) orelse return error.UnknownTaskId;
        per_task[task_index] += 1;
    }

    var summed_core_ticks: u32 = 0;
    for (per_core) |count| summed_core_ticks += count;
    try std.testing.expectEqual(total_tick_events, summed_core_ticks);

    var expected_total_work: u32 = 0;
    for (result.tasks, per_task) |task, counted_ticks| {
        expected_total_work += task.burst_ticks;
        try std.testing.expectEqual(task.total_executed, counted_ticks);
        try std.testing.expectEqual(task.burst_ticks, counted_ticks);
    }

    try std.testing.expectEqual(expected_total_work, total_tick_events);
}

test "multicore fixture uses more than one core across policies" {
    const allocator = std.testing.allocator;
    var scenario = try loadMulticoreFixture(allocator);
    defer scenario.deinit();

    const policies = [_]sim.PolicyKind{ .fcfs, .round_robin, .cfs_like };
    for (policies) |policy| {
        var result = try sim.simulate(allocator, &scenario, policy);
        defer result.deinit();

        try std.testing.expectEqual(@as(u32, 2), result.core_count);
        try expectNoDuplicateTaskTicksPerTick(result.trace);

        var saw_core_one = false;
        for (result.trace) |entry| {
            if (entry.core_id == 1) saw_core_one = true;
        }
        try std.testing.expect(saw_core_one);
    }
}

test "multicore balancing moves ready work onto an idle core deterministically" {
    const allocator = std.testing.allocator;
    var scenario = try loadBalancingFixture(allocator);
    defer scenario.deinit();

    var result = try sim.simulate(allocator, &scenario, .fcfs);
    defer result.deinit();

    var saw_balanced_dispatch = false;
    for (result.trace) |entry| {
        if (entry.kind == .dispatch and entry.task_id != null and std.mem.eql(u8, entry.task_id.?, "C")) {
            try std.testing.expectEqual(@as(sim.CoreId, 1), entry.core_id.?);
            saw_balanced_dispatch = true;
            break;
        }
    }
    try std.testing.expect(saw_balanced_dispatch);
}

test "multicore balancing keeps migration visible in the trace" {
    const allocator = std.testing.allocator;
    var scenario = try loadBalancingFixture(allocator);
    defer scenario.deinit();

    var result = try sim.simulate(allocator, &scenario, .fcfs);
    defer result.deinit();

    var arrival_core: ?sim.CoreId = null;
    var dispatch_core: ?sim.CoreId = null;
    for (result.trace) |entry| {
        if (entry.task_id == null or !std.mem.eql(u8, entry.task_id.?, "C")) continue;
        if (entry.kind == .arrival) arrival_core = entry.core_id;
        if (entry.kind == .dispatch and dispatch_core == null) dispatch_core = entry.core_id;
    }

    try std.testing.expectEqual(@as(?sim.CoreId, 0), arrival_core);
    try std.testing.expectEqual(@as(?sim.CoreId, 1), dispatch_core);
}

test "multicore arrivals expose assigned core identity" {
    const allocator = std.testing.allocator;
    var scenario = try loadMulticoreFixture(allocator);
    defer scenario.deinit();

    var result = try sim.simulate(allocator, &scenario, .fcfs);
    defer result.deinit();

    var saw_secondary_arrival = false;
    for (result.trace) |entry| {
        if (entry.kind != .arrival) continue;
        if (entry.core_id == 1) {
            saw_secondary_arrival = true;
            break;
        }
    }

    try std.testing.expect(saw_secondary_arrival);
}

test "multicore fixture corpus distinguishes single-core and multicore guarantees" {
    const allocator = std.testing.allocator;
    var single_core = try loadShortVsLong(allocator);
    defer single_core.deinit();
    var multicore = try loadMulticoreFixture(allocator);
    defer multicore.deinit();

    var single_result = try sim.simulate(allocator, &single_core, .fcfs);
    defer single_result.deinit();
    var multicore_result = try sim.simulate(allocator, &multicore, .fcfs);
    defer multicore_result.deinit();

    try std.testing.expectEqual(@as(u32, 1), single_result.core_count);
    try std.testing.expectEqual(@as(u32, 2), multicore_result.core_count);
}

test "same-tick multicore completions stay deterministic" {
    const allocator = std.testing.allocator;
    var scenario = try loadSimultaneousFixture(allocator);
    defer scenario.deinit();

    var result = try sim.simulate(allocator, &scenario, .fcfs);
    defer result.deinit();

    var completions: [2]?[]const u8 = .{ null, null };
    var count: usize = 0;
    for (result.trace) |entry| {
        if (entry.kind != .complete or entry.tick != 3) continue;
        if (count < completions.len) completions[count] = entry.task_id;
        count += 1;
    }

    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqualStrings("A", completions[0].?);
    try std.testing.expectEqualStrings("B", completions[1].?);
}

test "multicore RR fixture emits deterministic core-local preemption" {
    const allocator = std.testing.allocator;
    var scenario = try loadMulticoreRrFixture(allocator);
    defer scenario.deinit();

    var result = try sim.simulate(allocator, &scenario, .round_robin);
    defer result.deinit();

    var saw_preempt = false;
    for (result.trace) |entry| {
        if (entry.kind != .preempt) continue;
        try std.testing.expect(entry.core_id != null);
        saw_preempt = true;
    }
    try std.testing.expect(saw_preempt);
}
