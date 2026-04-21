const std = @import("std");
const sim = @import("../root.zig");

const ParsedReport = struct {
    schema: []const u8,
    version: u32,
    source: struct {
        kind: sim.cli.SourceKind,
        value: []const u8,
    },
    scenario: struct {
        name: []const u8,
        round_robin_quantum: u32,
    },
    policy: struct {
        kind: sim.PolicyKind,
        display_name: []const u8,
        quantum: ?u32,
    },
    completion_order: []const []const u8,
    trace: []const struct {
        tick: u32,
        kind: sim.TraceEventKind,
        task_id: ?[]const u8,
    },
    tasks: []const struct {
        id: []const u8,
        arrival_tick: u32,
        burst_ticks: u32,
        weight: u32,
        input_order: u32,
        first_dispatch_tick: u32,
        completion_time: u32,
        turnaround_time: u32,
        waiting_time: u32,
        response_time: u32,
        total_executed: u32,
    },
    aggregate: struct {
        average_waiting_time: f64,
        average_response_time: f64,
        throughput: f64,
        throughput_numerator: u32,
        throughput_denominator: u32,
        waiting_time_spread: u32,
    },
    notes: []const []const u8,
};

fn renderJson(
    allocator: std.mem.Allocator,
    source: sim.cli.SourceInfo,
    scenario: *const sim.ScenarioOwned,
    result: *const sim.SimulationResult,
) ![]u8 {
    const report = sim.cli.SimulationReport.init(source, scenario, result);
    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(allocator);
    var writer = buffer.writer(allocator);
    try sim.cli.writeJsonReport(&writer, report);
    return try buffer.toOwnedSlice(allocator);
}

fn parseJsonReport(allocator: std.mem.Allocator, rendered: []const u8) !std.json.Parsed(ParsedReport) {
    return try std.json.parseFromSlice(ParsedReport, allocator, rendered, .{});
}

test "CLI report includes required sections" {
    const allocator = std.testing.allocator;
    var scenario = try sim.loadScenarioByName(allocator, "short-vs-long");
    defer scenario.deinit();

    var result = try sim.simulate(allocator, &scenario, .round_robin);
    defer result.deinit();

    const report = sim.cli.SimulationReport.init(.{ .kind = .builtin, .value = "short-vs-long" }, &scenario, &result);
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);
    var writer = buffer.writer(allocator);
    try sim.cli.writeHumanReport(&writer, report);

    const rendered = buffer.items;
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Scenario:") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Policy:") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Completion Order:") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Trace:") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Per-Task Metrics:") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Aggregate Metrics:") != null);
}

test "JSON export includes schema and version" {
    const allocator = std.testing.allocator;
    var scenario = try sim.loadScenarioByName(allocator, "short-vs-long");
    defer scenario.deinit();

    var result = try sim.simulate(allocator, &scenario, .round_robin);
    defer result.deinit();

    const rendered = try renderJson(allocator, .{ .kind = .builtin, .value = "short-vs-long" }, &scenario, &result);
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"schema\":\"zig-scheduler/report\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"version\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"source\":{\"kind\":\"builtin\",\"value\":\"short-vs-long\"}") != null);
}


test "JSON export includes file source metadata" {
    const allocator = std.testing.allocator;
    var scenario = try sim.loadScenarioFile(allocator, "scenarios/basic/arrivals.zon");
    defer scenario.deinit();

    var result = try sim.simulate(allocator, &scenario, .fcfs);
    defer result.deinit();

    const rendered = try renderJson(allocator, .{ .kind = .file, .value = "scenarios/basic/arrivals.zon" }, &scenario, &result);
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"source\":{\"kind\":\"file\",\"value\":\"scenarios/basic/arrivals.zon\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"scenario\":{\"name\":\"arrivals\",\"round_robin_quantum\":2}") != null);
}

test "JSON export is deterministic across repeated runs" {
    const allocator = std.testing.allocator;
    var scenario = try sim.loadScenarioByName(allocator, "short-vs-long");
    defer scenario.deinit();

    var first = try sim.simulate(allocator, &scenario, .round_robin);
    defer first.deinit();
    var second = try sim.simulate(allocator, &scenario, .round_robin);
    defer second.deinit();

    const first_json = try renderJson(allocator, .{ .kind = .builtin, .value = "short-vs-long" }, &scenario, &first);
    defer allocator.free(first_json);
    const second_json = try renderJson(allocator, .{ .kind = .builtin, .value = "short-vs-long" }, &scenario, &second);
    defer allocator.free(second_json);

    try std.testing.expectEqualStrings(first_json, second_json);
}

test "JSON export includes the documented public task and trace fields" {
    const allocator = std.testing.allocator;
    var scenario = try sim.loadScenarioFile(allocator, "scenarios/basic/weighted-fairness.zon");
    defer scenario.deinit();

    var result = try sim.simulate(allocator, &scenario, .cfs_like);
    defer result.deinit();

    const rendered = try renderJson(allocator, .{ .kind = .file, .value = "scenarios/basic/weighted-fairness.zon" }, &scenario, &result);
    defer allocator.free(rendered);

    var parsed = try parseJsonReport(allocator, rendered);
    defer parsed.deinit();

    try std.testing.expectEqualStrings(sim.cli.schema_name, parsed.value.schema);
    try std.testing.expectEqual(sim.cli.schema_version, parsed.value.version);
    try std.testing.expectEqual(sim.cli.SourceKind.file, parsed.value.source.kind);
    try std.testing.expectEqualStrings("scenarios/basic/weighted-fairness.zon", parsed.value.source.value);
    try std.testing.expectEqualStrings("weighted-fairness", parsed.value.scenario.name);
    try std.testing.expectEqual(@as(u32, 2), parsed.value.scenario.round_robin_quantum);
    try std.testing.expectEqual(sim.PolicyKind.cfs_like, parsed.value.policy.kind);
    try std.testing.expectEqualStrings("CFS-inspired", parsed.value.policy.display_name);
    try std.testing.expect(parsed.value.policy.quantum == null);

    try std.testing.expectEqual(@as(usize, 3), parsed.value.completion_order.len);
    try std.testing.expectEqualStrings("default", parsed.value.completion_order[0]);
    try std.testing.expectEqualStrings("heavy", parsed.value.completion_order[1]);
    try std.testing.expectEqualStrings("light", parsed.value.completion_order[2]);

    try std.testing.expect(parsed.value.trace.len != 0);
    try std.testing.expectEqual(@as(u32, 0), parsed.value.trace[0].tick);
    try std.testing.expectEqual(sim.TraceEventKind.arrival, parsed.value.trace[0].kind);
    try std.testing.expectEqualStrings("light", parsed.value.trace[0].task_id.?);

    try std.testing.expectEqual(@as(usize, 3), parsed.value.tasks.len);
    try std.testing.expectEqualStrings("light", parsed.value.tasks[0].id);
    try std.testing.expectEqual(@as(u32, 512), parsed.value.tasks[0].weight);
    try std.testing.expectEqual(@as(u32, 4), parsed.value.tasks[1].burst_ticks);
    try std.testing.expectEqual(@as(u32, 2), parsed.value.tasks[2].total_executed);

    try std.testing.expectEqual(@as(u32, 3), parsed.value.aggregate.throughput_numerator);
    try std.testing.expectEqual(@as(u32, 10), parsed.value.aggregate.throughput_denominator);
    try std.testing.expectEqual(@as(u32, 3), parsed.value.aggregate.waiting_time_spread);
    try std.testing.expect(parsed.value.notes.len >= 2);
}

test "report contract validation rejects missing or unsupported schema and version" {
    try sim.cli.assertSupportedContract(sim.cli.schema_name, sim.cli.schema_version);
    try std.testing.expectError(error.MissingSchema, sim.cli.assertSupportedContract(null, sim.cli.schema_version));
    try std.testing.expectError(error.UnsupportedSchema, sim.cli.assertSupportedContract("zig-scheduler/other", sim.cli.schema_version));
    try std.testing.expectError(error.MissingVersion, sim.cli.assertSupportedContract(sim.cli.schema_name, null));
    try std.testing.expectError(error.UnsupportedVersion, sim.cli.assertSupportedContract(sim.cli.schema_name, sim.cli.schema_version + 1));
}

test "public trace taxonomy stays frozen" {
    const expected = [_]sim.TraceEventKind{
        .arrival,
        .dispatch,
        .tick,
        .preempt,
        .complete,
        .idle,
    };

    try std.testing.expectEqual(expected.len, sim.cli.publicTraceEventKinds().len);
    for (expected, sim.cli.publicTraceEventKinds()) |lhs, rhs| {
        try std.testing.expectEqual(lhs, rhs);
    }
}
