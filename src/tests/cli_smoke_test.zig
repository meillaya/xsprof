const std = @import("std");
const sim = @import("../root.zig");

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
