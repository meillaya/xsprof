const std = @import("std");
const list_writer = @import("list_writer");
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
        group_id: ?[]const u8,
        domain_id: ?[]const u8,
        core_id: ?sim.CoreId,
    },
    tasks: []const struct {
        id: []const u8,
        arrival_tick: u32,
        burst_ticks: u32,
        weight: u32,
        group_id: ?[]const u8,
        sleep_after_ticks: ?u32,
        sleep_duration: u32,
        phase_count: u32,
        deadline_tick: ?u32,
        input_order: u32,
        first_dispatch_tick: u32,
        completion_time: u32,
        turnaround_time: u32,
        waiting_time: u32,
        blocked_time: u32,
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
        max_waiting_time: u32,
        max_response_time: u32,
        response_time_spread: u32,
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
    var writer = list_writer.writer(&buffer, allocator);
    try sim.cli.writeJsonReport(&writer, report);
    return try buffer.toOwnedSlice(allocator);
}

fn parseJsonReport(allocator: std.mem.Allocator, rendered: []const u8) !std.json.Parsed(ParsedReport) {
    return try std.json.parseFromSlice(ParsedReport, allocator, rendered, .{
        .ignore_unknown_fields = true,
    });
}

fn parseJsonValue(allocator: std.mem.Allocator, rendered: []const u8) !std.json.Parsed(std.json.Value) {
    return try std.json.parseFromSlice(std.json.Value, allocator, rendered, .{});
}

fn expectStringFieldSet(expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |lhs, rhs| {
        try std.testing.expectEqualStrings(lhs, rhs);
    }
}

fn expectJsonObjectFields(value: std.json.Value, expected: []const []const u8) !void {
    try std.testing.expect(value == .object);

    const object = value.object;
    try std.testing.expectEqual(expected.len, object.count());
    for (expected) |field| {
        try std.testing.expect(object.contains(field));
    }
}

fn policyCliName(policy: sim.PolicyKind) []const u8 {
    return switch (policy) {
        .fcfs => "fcfs",
        .round_robin => "round_robin",
        .cfs_like => "cfs-like",
        .deadline => "deadline",
    };
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
    var writer = list_writer.writer(&buffer, allocator);
    try sim.cli.writeHumanReport(&writer, report);

    const rendered = buffer.items;
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Scenario:") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Policy:") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Core Count:") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Completion Order:") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Trace:") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Per-Task Metrics:") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Aggregate Metrics:") != null);
}

test "CLI and JSON smoke expose core identity" {
    const allocator = std.testing.allocator;
    var scenario = try sim.loadScenarioByName(allocator, "short-vs-long");
    defer scenario.deinit();

    var result = try sim.simulate(allocator, &scenario, .round_robin);
    defer result.deinit();

    const report = sim.cli.SimulationReport.init(.{ .kind = .builtin, .value = "short-vs-long" }, &scenario, &result);

    var human_buffer: std.ArrayList(u8) = .empty;
    defer human_buffer.deinit(allocator);
    var human_writer = list_writer.writer(&human_buffer, allocator);
    try sim.cli.writeHumanReport(&human_writer, report);

    try std.testing.expect(std.mem.indexOf(u8, human_buffer.items, "Core Count: 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, human_buffer.items, "core=0") != null);

    const rendered_json = try renderJson(allocator, .{ .kind = .builtin, .value = "short-vs-long" }, &scenario, &result);
    defer allocator.free(rendered_json);

    try std.testing.expect(std.mem.indexOf(u8, rendered_json, "\"core_count\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered_json, "\"core_id\":0") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"core_count\":1") != null);
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

test "JSON export bytes stay consistent across writer paths" {
    const allocator = std.testing.allocator;
    var scenario = try sim.loadScenarioFile(allocator, "scenarios/basic/multicore-contention.zon");
    defer scenario.deinit();

    var result = try sim.simulate(allocator, &scenario, .fcfs);
    defer result.deinit();

    const report = sim.cli.SimulationReport.init(.{ .kind = .file, .value = "scenarios/basic/multicore-contention.zon" }, &scenario, &result);

    var array_buffer: std.ArrayList(u8) = .empty;
    defer array_buffer.deinit(allocator);
    var array_writer = list_writer.writer(&array_buffer, allocator);
    try sim.cli.writeJsonReport(&array_writer, report);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(std.Io.Threaded.global_single_threaded.io(), "report.json", .{ .truncate = true });
    defer file.close(std.Io.Threaded.global_single_threaded.io());
    var file_buffer: [1024]u8 = undefined;
    var file_writer = file.writer(std.Io.Threaded.global_single_threaded.io(), &file_buffer);
    try sim.cli.writeJsonReport(&file_writer.interface, report);
    try file_writer.interface.flush();

    const file_bytes = try tmp.dir.readFileAlloc(std.Io.Threaded.global_single_threaded.io(), "report.json", allocator, .unlimited);
    defer allocator.free(file_bytes);

    try std.testing.expectEqualStrings(array_buffer.items, file_bytes);
    try std.testing.expect(array_buffer.items.len != 0);
    try std.testing.expectEqual(@as(u8, '\n'), array_buffer.items[array_buffer.items.len - 1]);
}

test "public report field lists stay frozen for version 1" {
    const expected_top_level_fields = [_][]const u8{
        "schema",
        "version",
        "source",
        "scenario",
        "policy",
        "core_count",
        "topology_domains",
        "groups",
        "completion_order",
        "trace",
        "tasks",
        "aggregate",
        "notes",
    };
    const expected_source_fields = [_][]const u8{
        "kind",
        "value",
    };
    const expected_scenario_fields = [_][]const u8{
        "name",
        "round_robin_quantum",
    };
    const expected_domain_fields = [_][]const u8{
        "id",
        "cores",
    };
    const expected_group_fields = [_][]const u8{
        "id",
        "weight",
        "quota_ticks",
    };
    const expected_policy_fields = [_][]const u8{
        "kind",
        "display_name",
        "quantum",
    };
    const expected_trace_entry_fields = [_][]const u8{
        "tick",
        "kind",
        "task_id",
        "group_id",
        "domain_id",
        "core_id",
    };
    const expected_task_fields = [_][]const u8{
        "id",
        "arrival_tick",
        "burst_ticks",
        "weight",
        "group_id",
        "sleep_after_ticks",
        "sleep_duration",
        "phase_count",
        "deadline_tick",
        "input_order",
        "first_dispatch_tick",
        "completion_time",
        "turnaround_time",
        "waiting_time",
        "blocked_time",
        "response_time",
        "total_executed",
    };
    const expected_aggregate_fields = [_][]const u8{
        "average_waiting_time",
        "average_response_time",
        "throughput",
        "throughput_numerator",
        "throughput_denominator",
        "waiting_time_spread",
        "max_waiting_time",
        "max_response_time",
        "response_time_spread",
    };

    try expectStringFieldSet(expected_top_level_fields[0..], sim.cli.top_level_fields[0..]);
    try expectStringFieldSet(expected_source_fields[0..], sim.cli.source_fields[0..]);
    try expectStringFieldSet(expected_scenario_fields[0..], sim.cli.scenario_fields[0..]);
    try expectStringFieldSet(expected_domain_fields[0..], sim.cli.domain_fields[0..]);
    try expectStringFieldSet(expected_group_fields[0..], sim.cli.group_fields[0..]);
    try expectStringFieldSet(expected_policy_fields[0..], sim.cli.policy_fields[0..]);
    try expectStringFieldSet(expected_trace_entry_fields[0..], sim.cli.trace_entry_fields[0..]);
    try expectStringFieldSet(expected_task_fields[0..], sim.cli.task_fields[0..]);
    try expectStringFieldSet(expected_aggregate_fields[0..], sim.cli.aggregate_fields[0..]);
}

test "JSON export preserves the documented version 1 baseline fields" {
    const allocator = std.testing.allocator;
    var scenario = try sim.loadScenarioFile(allocator, "scenarios/basic/weighted-fairness.zon");
    defer scenario.deinit();

    var result = try sim.simulate(allocator, &scenario, .cfs_like);
    defer result.deinit();

    const rendered = try renderJson(allocator, .{ .kind = .file, .value = "scenarios/basic/weighted-fairness.zon" }, &scenario, &result);
    defer allocator.free(rendered);

    var parsed = try parseJsonReport(allocator, rendered);
    defer parsed.deinit();
    var parsed_value = try parseJsonValue(allocator, rendered);
    defer parsed_value.deinit();

    try expectJsonObjectFields(parsed_value.value, sim.cli.top_level_fields[0..]);
    try expectJsonObjectFields(parsed_value.value.object.get("source").?, sim.cli.source_fields[0..]);
    try expectJsonObjectFields(parsed_value.value.object.get("scenario").?, sim.cli.scenario_fields[0..]);
    try expectJsonObjectFields(parsed_value.value.object.get("policy").?, sim.cli.policy_fields[0..]);
    try std.testing.expectEqual(@as(usize, 0), parsed_value.value.object.get("topology_domains").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 0), parsed_value.value.object.get("groups").?.array.items.len);
    try std.testing.expect(parsed_value.value.object.get("trace").?.array.items.len != 0);
    try expectJsonObjectFields(parsed_value.value.object.get("trace").?.array.items[0], sim.cli.trace_entry_fields[0..]);
    try std.testing.expect(parsed_value.value.object.get("tasks").?.array.items.len != 0);
    try expectJsonObjectFields(parsed_value.value.object.get("tasks").?.array.items[0], sim.cli.task_fields[0..]);
    try expectJsonObjectFields(parsed_value.value.object.get("aggregate").?, sim.cli.aggregate_fields[0..]);

    try std.testing.expectEqualStrings(sim.cli.schema_name, parsed.value.schema);
    try std.testing.expectEqual(sim.cli.schema_version, parsed.value.version);
    try std.testing.expectEqual(sim.cli.SourceKind.file, parsed.value.source.kind);
    try std.testing.expectEqualStrings("scenarios/basic/weighted-fairness.zon", parsed.value.source.value);
    try std.testing.expectEqualStrings("weighted-fairness", parsed.value.scenario.name);
    try std.testing.expectEqual(@as(u32, 2), parsed.value.scenario.round_robin_quantum);
    try std.testing.expectEqual(sim.PolicyKind.cfs_like, parsed.value.policy.kind);
    try std.testing.expectEqualStrings("CFS-inspired", parsed.value.policy.display_name);
    try std.testing.expect(parsed.value.policy.quantum == null);
    try std.testing.expectEqual(@as(u32, 1), parsed.value.core_count);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.groups.len);

    try std.testing.expectEqual(@as(usize, 3), parsed.value.completion_order.len);
    try std.testing.expectEqualStrings("default", parsed.value.completion_order[0]);
    try std.testing.expectEqualStrings("heavy", parsed.value.completion_order[1]);
    try std.testing.expectEqualStrings("light", parsed.value.completion_order[2]);

    try std.testing.expect(parsed.value.trace.len != 0);
    try std.testing.expectEqual(@as(u32, 0), parsed.value.trace[0].tick);
    try std.testing.expectEqual(sim.TraceEventKind.arrival, parsed.value.trace[0].kind);
    try std.testing.expectEqualStrings("light", parsed.value.trace[0].task_id.?);
    try std.testing.expect(parsed.value.trace[0].group_id == null);
    try std.testing.expect(parsed.value.trace[0].domain_id == null);
    try std.testing.expectEqual(@as(?sim.CoreId, 0), parsed.value.trace[0].core_id);
    var saw_core_identity = false;
    for (parsed.value.trace) |entry| {
        if (entry.core_id) |core_id| {
            try std.testing.expectEqual(@as(sim.CoreId, 0), core_id);
            saw_core_identity = true;
        }
    }
    try std.testing.expect(saw_core_identity);

    try std.testing.expectEqual(@as(usize, 3), parsed.value.tasks.len);
    try std.testing.expectEqualStrings("light", parsed.value.tasks[0].id);
    try std.testing.expect(parsed.value.tasks[0].group_id == null);
    try std.testing.expectEqual(@as(u32, 512), parsed.value.tasks[0].weight);
    try std.testing.expectEqual(@as(?u32, null), parsed.value.tasks[0].sleep_after_ticks);
    try std.testing.expectEqual(@as(u32, 0), parsed.value.tasks[0].sleep_duration);
    try std.testing.expectEqual(@as(u32, 1), parsed.value.tasks[0].phase_count);
    try std.testing.expectEqual(@as(u32, 0), parsed.value.tasks[0].blocked_time);
    try std.testing.expectEqual(@as(u32, 4), parsed.value.tasks[1].burst_ticks);
    try std.testing.expectEqual(@as(u32, 2), parsed.value.tasks[2].total_executed);

    try std.testing.expectEqual(@as(u32, 3), parsed.value.aggregate.throughput_numerator);
    try std.testing.expectEqual(@as(u32, 10), parsed.value.aggregate.throughput_denominator);
    try std.testing.expectEqual(@as(u32, 3), parsed.value.aggregate.waiting_time_spread);
    var computed_max_waiting: u32 = 0;
    var computed_min_response: ?u32 = null;
    var computed_max_response: u32 = 0;
    for (parsed.value.tasks) |task| {
        computed_max_waiting = @max(computed_max_waiting, task.waiting_time);
        computed_max_response = @max(computed_max_response, task.response_time);
        computed_min_response = if (computed_min_response) |current|
            @min(current, task.response_time)
        else
            task.response_time;
    }
    try std.testing.expectEqual(computed_max_waiting, parsed.value.aggregate.max_waiting_time);
    try std.testing.expectEqual(computed_max_response, parsed.value.aggregate.max_response_time);
    try std.testing.expectEqual(computed_max_response - computed_min_response.?, parsed.value.aggregate.response_time_spread);
    try std.testing.expect(parsed.value.notes.len >= 2);
}

test "report contract validation rejects missing or unsupported schema and version" {
    try sim.cli.assertSupportedContract(sim.cli.schema_name, sim.cli.schema_version);
    try std.testing.expectError(error.MissingSchema, sim.cli.assertSupportedContract(null, sim.cli.schema_version));
    try std.testing.expectError(error.UnsupportedSchema, sim.cli.assertSupportedContract("zig-scheduler/other", sim.cli.schema_version));
    try std.testing.expectError(error.MissingVersion, sim.cli.assertSupportedContract(sim.cli.schema_name, null));
    try std.testing.expectError(error.UnsupportedVersion, sim.cli.assertSupportedContract(sim.cli.schema_name, sim.cli.schema_version + 1));
}

test "public report field lists stay aligned with additive core identity contract" {
    const expected_top_level = [_][]const u8{
        "schema",
        "version",
        "source",
        "scenario",
        "policy",
        "core_count",
        "topology_domains",
        "groups",
        "completion_order",
        "trace",
        "tasks",
        "aggregate",
        "notes",
    };
    const expected_trace_entry = [_][]const u8{
        "tick",
        "kind",
        "task_id",
        "group_id",
        "domain_id",
        "core_id",
    };
    const expected_task_fields = [_][]const u8{
        "id",
        "arrival_tick",
        "burst_ticks",
        "weight",
        "group_id",
        "sleep_after_ticks",
        "sleep_duration",
        "phase_count",
        "deadline_tick",
        "input_order",
        "first_dispatch_tick",
        "completion_time",
        "turnaround_time",
        "waiting_time",
        "blocked_time",
        "response_time",
        "total_executed",
    };

    try std.testing.expectEqual(expected_top_level.len, sim.cli.top_level_fields.len);
    for (expected_top_level, sim.cli.top_level_fields) |lhs, rhs| {
        try std.testing.expectEqualStrings(lhs, rhs);
    }

    try std.testing.expectEqual(expected_trace_entry.len, sim.cli.trace_entry_fields.len);
    for (expected_trace_entry, sim.cli.trace_entry_fields) |lhs, rhs| {
        try std.testing.expectEqualStrings(lhs, rhs);
    }

    try std.testing.expectEqual(expected_task_fields.len, sim.cli.task_fields.len);
    for (expected_task_fields, sim.cli.task_fields) |lhs, rhs| {
        try std.testing.expectEqualStrings(lhs, rhs);
    }
}

test "public trace taxonomy stays frozen" {
    const expected = [_]sim.TraceEventKind{
        .arrival,
        .dispatch,
        .tick,
        .preempt,
        .block,
        .wakeup,
        .complete,
        .idle,
    };

    try std.testing.expectEqual(expected.len, sim.cli.publicTraceEventKinds().len);
    for (expected, sim.cli.publicTraceEventKinds()) |lhs, rhs| {
        try std.testing.expectEqual(lhs, rhs);
    }
}

test "CLI multicore smoke exposes core identity for file scenarios" {
    const allocator = std.testing.allocator;
    var scenario = try sim.loadScenarioFile(allocator, "scenarios/basic/multicore-contention.zon");
    defer scenario.deinit();

    var result = try sim.simulate(allocator, &scenario, .fcfs);
    defer result.deinit();

    const report = sim.cli.SimulationReport.init(.{ .kind = .file, .value = "scenarios/basic/multicore-contention.zon" }, &scenario, &result);

    var human_buffer: std.ArrayList(u8) = .empty;
    defer human_buffer.deinit(allocator);
    var human_writer = list_writer.writer(&human_buffer, allocator);
    try sim.cli.writeHumanReport(&human_writer, report);
    try std.testing.expect(std.mem.indexOf(u8, human_buffer.items, "Core Count: 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, human_buffer.items, "core=1") != null);

    const rendered_json = try renderJson(allocator, .{ .kind = .file, .value = "scenarios/basic/multicore-contention.zon" }, &scenario, &result);
    defer allocator.free(rendered_json);
    try std.testing.expect(std.mem.indexOf(u8, rendered_json, "\"core_count\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered_json, "\"core_id\":1") != null);
}

test "blocked-state JSON export exposes sleep and blocked metrics" {
    const allocator = std.testing.allocator;
    var scenario = try sim.loadScenarioFile(allocator, "scenarios/basic/sleep-wakeup.zon");
    defer scenario.deinit();

    var result = try sim.simulate(allocator, &scenario, .fcfs);
    defer result.deinit();

    const rendered = try renderJson(allocator, .{ .kind = .file, .value = "scenarios/basic/sleep-wakeup.zon" }, &scenario, &result);
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"kind\":\"block\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"kind\":\"wakeup\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"sleep_after_ticks\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"sleep_duration\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"blocked_time\":2") != null);
}

test "multi-phase JSON export exposes derived phase counts" {
    const allocator = std.testing.allocator;
    var scenario = try sim.loadScenarioFile(allocator, "scenarios/basic/multi-phase-io.zon");
    defer scenario.deinit();

    var result = try sim.simulate(allocator, &scenario, .fcfs);
    defer result.deinit();

    const rendered = try renderJson(allocator, .{ .kind = .file, .value = "scenarios/basic/multi-phase-io.zon" }, &scenario, &result);
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"phase_count\":5") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"blocked_time\":3") != null);
}

test "deadline-inspired JSON export exposes task deadlines" {
    const allocator = std.testing.allocator;
    var scenario = try sim.loadScenarioFile(allocator, "scenarios/basic/deadline-priority.zon");
    defer scenario.deinit();

    var result = try sim.simulate(allocator, &scenario, .deadline);
    defer result.deinit();

    const rendered = try renderJson(allocator, .{ .kind = .file, .value = "scenarios/basic/deadline-priority.zon" }, &scenario, &result);
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"policy\":{\"kind\":\"deadline\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"deadline_tick\":3") != null);
}

test "group-aware JSON export exposes groups and task group ids" {
    const allocator = std.testing.allocator;
    var scenario = try sim.loadScenarioFile(allocator, "scenarios/basic/group-fairness.zon");
    defer scenario.deinit();

    var result = try sim.simulate(allocator, &scenario, .cfs_like);
    defer result.deinit();

    const rendered = try renderJson(allocator, .{ .kind = .file, .value = "scenarios/basic/group-fairness.zon" }, &scenario, &result);
    defer allocator.free(rendered);
    var parsed = try parseJsonReport(allocator, rendered);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 2), parsed.value.groups.len);
    try std.testing.expectEqualStrings("interactive", parsed.value.groups[0].id);
    try std.testing.expectEqual(@as(u32, 2048), parsed.value.groups[0].weight);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"group_id\":\"interactive\"") != null);
}

test "topology-aware JSON export exposes topology domains and domain-tagged trace events" {
    const allocator = std.testing.allocator;
    var scenario = try sim.loadScenarioFile(allocator, "scenarios/basic/topology-domains.zon");
    defer scenario.deinit();

    var result = try sim.simulate(allocator, &scenario, .fcfs);
    defer result.deinit();

    const rendered = try renderJson(allocator, .{ .kind = .file, .value = "scenarios/basic/topology-domains.zon" }, &scenario, &result);
    defer allocator.free(rendered);
    var parsed = try parseJsonReport(allocator, rendered);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 2), parsed.value.topology_domains.len);
    try std.testing.expectEqualStrings("node0", parsed.value.topology_domains[0].id);
    try std.testing.expectEqual(@as(sim.CoreId, 0), parsed.value.topology_domains[0].cores[0]);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"domain_id\":\"node0\"") != null);
}
