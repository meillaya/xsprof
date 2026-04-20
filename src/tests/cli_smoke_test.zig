const std = @import("std");
const sim = @import("../root.zig");

test "CLI report includes required sections" {
    const allocator = std.testing.allocator;
    var scenario = try sim.loadScenarioByName(allocator, "short-vs-long");
    defer scenario.deinit();

    var result = try sim.simulate(allocator, &scenario, .round_robin);
    defer result.deinit();

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);
    try sim.cli.writeSimulationReport(buffer.writer(allocator), &scenario, &result);

    const rendered = buffer.items;
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Scenario:") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Policy:") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Completion Order:") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Trace:") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Per-Task Metrics:") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Aggregate Metrics:") != null);
}
