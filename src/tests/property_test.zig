const std = @import("std");
const sim = @import("../root.zig");

const ParsedPropertyReport = struct {
    schema: []const u8,
    version: u32,
    scenario: struct {
        name: []const u8,
        round_robin_quantum: u32,
    },
    policy: struct {
        kind: sim.PolicyKind,
    },
    core_count: u32,
    topology_domains: []const struct {
        id: []const u8,
        cores: []const sim.CoreId,
    },
    groups: []const struct {
        id: []const u8,
        weight: u32,
        quota_ticks: u32,
    },
    completion_order: []const []const u8,
    trace: []const struct {
        tick: u32,
        kind: sim.TraceEventKind,
        task_id: ?[]const u8,
        core_id: ?sim.CoreId,
    },
    tasks: []const struct {
        id: []const u8,
        arrival_tick: u32,
        burst_ticks: u32,
        waiting_time: u32,
        blocked_time: u32,
        turnaround_time: u32,
        response_time: u32,
        completion_time: u32,
        total_executed: u32,
    },
    aggregate: struct {
        throughput_numerator: u32,
        throughput_denominator: u32,
        max_waiting_time: u32,
        max_response_time: u32,
    },
    notes: []const []const u8,
};

const ShrinkContext = struct {
    allocator: std.mem.Allocator,
};

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return try std.fs.cwd().readFileAlloc(allocator, path, std.math.maxInt(usize));
}

fn seedToPolicy(seed: usize) sim.PolicyKind {
    return switch (seed % 4) {
        0 => .fcfs,
        1 => .round_robin,
        2 => .cfs_like,
        else => .deadline,
    };
}

fn expectAccountingInvariants(result: *const sim.SimulationResult) !void {
    try std.testing.expectEqual(result.tasks.len, result.completion_order.len);
    try std.testing.expectEqual(@as(u32, @intCast(result.tasks.len)), result.aggregate.throughput_numerator);

    var total_burst: u32 = 0;
    for (result.tasks) |task| {
        total_burst += task.burst_ticks;
        try std.testing.expectEqual(task.burst_ticks, task.total_executed);
        try std.testing.expectEqual(task.turnaround_time, task.waiting_time + task.blocked_time + task.burst_ticks);
        try std.testing.expect(task.response_time <= task.waiting_time);
        try std.testing.expect(task.completion_time >= task.arrival_tick + task.burst_ticks);
    }

    var total_tick_events: u32 = 0;
    for (result.trace) |entry| {
        if (entry.core_id) |core_id| try std.testing.expect(core_id < result.core_count);
        if (entry.kind == .tick) total_tick_events += 1;
    }
    try std.testing.expectEqual(total_burst, total_tick_events);
}

fn shrinkPredicate(context: ShrinkContext, generated: *const sim.property.GeneratedScenario) !bool {
    var scenario = try generated.materialize(context.allocator);
    defer scenario.deinit();

    var fcfs = try sim.simulate(context.allocator, &scenario, .fcfs);
    defer fcfs.deinit();
    var rr = try sim.simulate(context.allocator, &scenario, .round_robin);
    defer rr.deinit();

    return !std.mem.eql(u8, fcfs.completionTaskId(0), rr.completionTaskId(0));
}

test "M13 generated scenarios satisfy validity constraints across policies" {
    const allocator = std.testing.allocator;

    for (0..16) |seed| {
        var generated = try sim.property.generateScenario(allocator, .{ .seed = seed + 1 });
        defer generated.deinit();

        var scenario = try generated.materialize(allocator);
        defer scenario.deinit();
        try scenario.validate();

        const policies = [_]sim.PolicyKind{ .fcfs, .round_robin, .cfs_like, .deadline };
        for (policies) |policy| {
            var result = try sim.simulate(allocator, &scenario, policy);
            defer result.deinit();
            try expectAccountingInvariants(&result);
        }
    }
}

test "M13 property suite covers export guarantees on generated scenarios" {
    const allocator = std.testing.allocator;

    for (0..12) |seed| {
        const policy = seedToPolicy(seed);
        var generated = try sim.property.generateScenario(allocator, .{ .seed = 100 + seed });
        defer generated.deinit();

        const rendered = try generated.renderJsonAlloc(allocator, policy);
        defer allocator.free(rendered);

        var parsed = try std.json.parseFromSlice(ParsedPropertyReport, allocator, rendered, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        try std.testing.expectEqualStrings(sim.cli.schema_name, parsed.value.schema);
        try std.testing.expectEqual(sim.cli.schema_version, parsed.value.version);
        try std.testing.expectEqualStrings(generated.name, parsed.value.scenario.name);
        try std.testing.expectEqual(generated.round_robin_quantum, parsed.value.scenario.round_robin_quantum);
        try std.testing.expectEqual(policy, parsed.value.policy.kind);
        try std.testing.expectEqual(generated.core_count, parsed.value.core_count);
        try std.testing.expectEqual(parsed.value.tasks.len, parsed.value.completion_order.len);
        try std.testing.expectEqual(@as(u32, @intCast(parsed.value.tasks.len)), parsed.value.aggregate.throughput_numerator);
        try std.testing.expect(parsed.value.notes.len != 0);
        try std.testing.expectEqual(generated.groups.len, parsed.value.groups.len);
        try std.testing.expectEqual(if (generated.core_count > 1 and generated.use_topology_domains) @as(usize, 2) else @as(usize, 0), parsed.value.topology_domains.len);

        var computed_max_waiting: u32 = 0;
        var computed_max_response: u32 = 0;
        for (parsed.value.tasks, 0..) |task, index| {
            _ = index;
            try std.testing.expectEqual(task.burst_ticks, task.total_executed);
            try std.testing.expectEqual(task.turnaround_time, task.waiting_time + task.blocked_time + task.burst_ticks);
            if (task.waiting_time > computed_max_waiting) computed_max_waiting = task.waiting_time;
            if (task.response_time > computed_max_response) computed_max_response = task.response_time;
        }
        try std.testing.expectEqual(computed_max_waiting, parsed.value.aggregate.max_waiting_time);
        try std.testing.expectEqual(computed_max_response, parsed.value.aggregate.max_response_time);

        for (parsed.value.trace) |entry| {
            if (entry.core_id) |core_id| try std.testing.expect(core_id < parsed.value.core_count);
        }
    }
}

test "M13 shrinker reduces and saves regression fixtures" {
    const allocator = std.testing.allocator;
    var generated = try sim.property.generateScenario(allocator, .{
        .seed = 9,
        .max_tasks = 5,
        .allow_groups = false,
        .allow_topology = false,
    });
    defer generated.deinit();

    generated.round_robin_quantum = 1;
    generated.core_count = 1;
    generated.use_topology_domains = false;
    generated.allocator.free(generated.groups);
    generated.groups = try generated.allocator.alloc(sim.property.GeneratedGroup, 0);
    generated.allocator.free(generated.tasks);
    generated.tasks = try generated.allocator.dupe(sim.property.GeneratedTask, &.{
        .{ .arrival_tick = 0, .burst_ticks = 6 },
        .{ .arrival_tick = 1, .burst_ticks = 2 },
        .{ .arrival_tick = 2, .burst_ticks = 1 },
        .{ .arrival_tick = 3, .burst_ticks = 1 },
    });

    const context: ShrinkContext = .{ .allocator = allocator };
    try std.testing.expect(try shrinkPredicate(context, &generated));

    var shrunk = try sim.property.shrinkScenario(allocator, &generated, context, shrinkPredicate);
    defer shrunk.deinit();

    try std.testing.expect(try shrinkPredicate(context, &shrunk));
    try std.testing.expect(shrunk.sizeScore() < generated.sizeScore());

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try shrunk.writeZonFile(allocator, tmp.dir, "m13-shrunk-regression.zon");

    const saved = try tmp.dir.readFileAlloc(allocator, "m13-shrunk-regression.zon", std.math.maxInt(usize));
    defer allocator.free(saved);
    try std.testing.expect(std.mem.indexOf(u8, saved, ".tasks = .{") != null);

    var reparsed = try sim.parseScenarioText(allocator, saved, shrunk.name);
    defer reparsed.deinit();
    var fcfs = try sim.simulate(allocator, &reparsed, .fcfs);
    defer fcfs.deinit();
    var rr = try sim.simulate(allocator, &reparsed, .round_robin);
    defer rr.deinit();
    try std.testing.expect(!std.mem.eql(u8, fcfs.completionTaskId(0), rr.completionTaskId(0)));
}

test "M13 docs explain generator, shrinking, and regression fixture workflow" {
    const allocator = std.testing.allocator;
    const readme = try readFileAlloc(allocator, "README.md");
    defer allocator.free(readme);
    const doc = try readFileAlloc(allocator, "docs/m13-property-testing.md");
    defer allocator.free(doc);

    try std.testing.expect(std.mem.indexOf(u8, readme, "Scenario generator and property harness") != null);
    try std.testing.expect(std.mem.indexOf(u8, readme, "src/testing/property.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "generator") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "shrink") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "regression fixture") != null);
}
