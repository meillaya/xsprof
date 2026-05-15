const std = @import("std");
const list_writer = @import("list_writer");
const scheduler = @import("zig_scheduler");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const source =
        \\.{
        \\    .name = "m22-embed-smoke",
        \\    .tasks = .{
        \\        .{ .id = "A", .arrival_tick = 0, .burst_ticks = 2 },
        \\        .{ .id = "B", .arrival_tick = 1, .burst_ticks = 1 },
        \\    },
        \\}
    ;

    var scenario = try scheduler.scenario_io.parseScenarioText(allocator, source, "m22-embed-smoke");
    defer scenario.deinit();

    var result = try scheduler.simulate(allocator, &scenario, scheduler.model.PolicyKind.fcfs);
    defer result.deinit();

    const report = scheduler.report.SimulationReport.init(
        .{ .kind = .file, .value = "inline:m22-embed-smoke" },
        &scenario,
        &result,
    );

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);
    var writer = list_writer.writer(&buffer, allocator);
    try scheduler.report.writeJsonReport(&writer, report);

    if (std.mem.indexOf(u8, buffer.items, scheduler.report.schema_name) == null) return error.SmokeFailure;
    if (std.mem.indexOf(u8, buffer.items, "\"scenario\":{\"name\":\"m22-embed-smoke\"") == null) return error.SmokeFailure;
}
