const std = @import("std");
const list_writer = @import("list_writer");
const contract_inventory = @import("../contract/inventory.zig");
const sdk = @import("../lib.zig");

fn expectDeclNamesExact(comptime T: type, comptime expected: []const []const u8) !void {
    const decls = std.meta.declarations(T);
    try std.testing.expectEqual(expected.len, decls.len);
    inline for (expected, 0..) |name, index| {
        try std.testing.expectEqualStrings(name, decls[index].name);
    }
}

test "public root stable subset stays exact" {
    try expectDeclNamesExact(sdk, &.{
        "sdk_api_version",
        "model",
        "scenario_io",
        "simulate",
        "report",
    });
}

test "public root excludes internal namespaces" {
    try std.testing.expect(!@hasDecl(sdk, "engine"));
    try std.testing.expect(!@hasDecl(sdk, "metrics"));
    try std.testing.expect(!@hasDecl(sdk, "policies"));
    try std.testing.expect(!@hasDecl(sdk, "scenario_packs"));
    try std.testing.expect(!@hasDecl(sdk, "cli"));
    try std.testing.expect(!@hasDecl(sdk, "property"));
    try std.testing.expect(!@hasDecl(sdk, "observability"));
    try std.testing.expect(!@hasDecl(sdk, "observability_comparison"));
}

test "model namespace exposes the documented stable subset" {
    try expectDeclNamesExact(sdk.model, &.{
        "PolicyKind",
        "CoreId",
        "DomainSpec",
        "GroupSpec",
        "TaskSpec",
        "TaskPhase",
        "TaskPhaseKind",
        "ScenarioOwned",
        "SimulationResult",
        "TaskMetrics",
        "AggregateMetrics",
        "TraceEntry",
        "TraceEventKind",
        "ValidationError",
        "default_task_weight",
        "max_task_weight",
    });
}

test "scenario_io namespace exposes the documented stable subset" {
    try expectDeclNamesExact(sdk.scenario_io, &.{
        "parseScenarioText",
        "parseScenario",
        "loadScenarioFile",
        "freeScenario",
    });
}

test "report namespace exposes the documented stable subset" {
    try expectDeclNamesExact(sdk.report, &.{
        "schema_name",
        "schema_version",
        "ContractError",
        "SourceKind",
        "SourceInfo",
        "SimulationReport",
        "assertSupportedContract",
        "publicTraceEventKinds",
        "writeJsonReport",
    });
}

test "public sdk workflow uses documented parse simulate export path" {
    const allocator = std.testing.allocator;
    const source =
        \\.{
        \\    .name = "library-sdk-test",
        \\    .tasks = .{
        \\        .{ .id = "A", .arrival_tick = 0, .burst_ticks = 2 },
        \\        .{ .id = "B", .arrival_tick = 1, .burst_ticks = 1 },
        \\    },
        \\}
    ;

    var scenario = try sdk.scenario_io.parseScenarioText(allocator, source, "library-sdk-test");
    defer scenario.deinit();

    var result = try sdk.simulate(allocator, &scenario, sdk.model.PolicyKind.fcfs);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.tasks.len);
    try std.testing.expectEqualStrings("A", result.tasks[0].id);

    const report = sdk.report.SimulationReport.init(
        .{ .kind = .file, .value = "inline:library-sdk-test" },
        &scenario,
        &result,
    );
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);
    var writer = list_writer.writer(&buffer, allocator);
    try sdk.report.writeJsonReport(&writer, report);

    try std.testing.expect(std.mem.indexOf(u8, buffer.items, sdk.report.schema_name) != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"scenario\":{\"name\":\"library-sdk-test\"") != null);
}

test "public sdk scenario free helper owns parsed scenario" {
    const allocator = std.testing.allocator;
    const source =
        \\.{
        \\    .name = "library-sdk-free-helper-test",
        \\    .tasks = .{
        \\        .{ .id = "A", .arrival_tick = 0, .burst_ticks = 1 },
        \\    },
        \\}
    ;

    const scenario = try sdk.scenario_io.parseScenarioText(allocator, source, "library-sdk-free-helper-test");
    sdk.scenario_io.freeScenario(allocator, scenario);
}

test "M31-M32 inventory records owner modules and production-boundary classes" {
    try std.testing.expectEqual(@as(usize, 9), contract_inventory.contract_surfaces.len);

    var runtime_portable: usize = 0;
    var lab_only: usize = 0;
    var intentionally_non_runtime: usize = 0;
    var saw_report = false;
    var saw_adr_gate = false;

    for (contract_inventory.contract_surfaces) |surface| {
        try std.testing.expect(surface.name.len != 0);
        try std.testing.expect(surface.owner_module.len != 0);
        switch (surface.boundary_class) {
            .runtime_portable => runtime_portable += 1,
            .lab_only => lab_only += 1,
            .intentionally_non_runtime => intentionally_non_runtime += 1,
        }
        if (std.mem.eql(u8, surface.owner_module, "src/contract/report.zig")) saw_report = true;
        if (std.mem.eql(u8, surface.owner_module, "docs/adr/0003-m25-productionization-gate.md")) saw_adr_gate = true;
    }

    try std.testing.expect(runtime_portable >= 1);
    try std.testing.expect(lab_only >= 1);
    try std.testing.expect(intentionally_non_runtime >= 1);
    try std.testing.expect(saw_report);
    try std.testing.expect(saw_adr_gate);
}
