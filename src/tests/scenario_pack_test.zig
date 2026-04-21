const std = @import("std");
const sim = @import("../root.zig");

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return try std.fs.cwd().readFileAlloc(allocator, path, std.math.maxInt(usize));
}

test "M14 scenario pack registry exposes committed core fixtures and optional regression pack" {
    const packs = sim.scenario_packs.listScenarioPacks();
    try std.testing.expectEqual(@as(usize, 2), packs.len);

    try std.testing.expectEqualStrings("core", packs[0].key);
    try std.testing.expectEqualStrings("scenarios/basic", packs[0].directory);
    try std.testing.expect(!packs[0].optional);
    try std.testing.expect(packs[0].scenarios.len >= 10);

    try std.testing.expectEqualStrings("regressions", packs[1].key);
    try std.testing.expectEqualStrings("scenarios/regressions", packs[1].directory);
    try std.testing.expect(packs[1].optional);
}

test "M14 scenario pack loader resolves core fixtures without optional extras" {
    var scenario = try sim.scenario_packs.loadPackScenario(std.testing.allocator, "core", "weighted-fairness");
    defer scenario.deinit();

    try std.testing.expectEqualStrings("weighted-fairness", scenario.name);
    try std.testing.expectEqual(@as(usize, 3), scenario.tasks.len);
    try std.testing.expectEqual(@as(u32, 2), scenario.round_robin_quantum);
}

test "M14 scenario pack registry keeps optional regression lane isolated from core loading" {
    try std.testing.expect(sim.scenario_packs.findScenarioPack("core") != null);
    try std.testing.expect(sim.scenario_packs.findScenarioPack("regressions") != null);
    try std.testing.expectEqual(@as(?[]const sim.scenario_packs.ScenarioPackEntry, null), sim.scenario_packs.listScenarioPackEntries("missing"));
    try std.testing.expectError(
        error.UnknownScenario,
        sim.scenario_packs.loadPackScenario(std.testing.allocator, "regressions", "missing-fixture"),
    );

    var scenario = try sim.scenario_packs.loadPackScenario(std.testing.allocator, "core", "topology-domains");
    defer scenario.deinit();
    try std.testing.expectEqual(@as(u32, 4), scenario.core_count);
    try std.testing.expectEqual(@as(usize, 2), scenario.domains.len);
}

test "M14 docs describe scenario pack layout and extension loading boundary" {
    const allocator = std.testing.allocator;
    const doc = try readFileAlloc(allocator, "docs/m14-extension-boundary.md");
    defer allocator.free(doc);

    try std.testing.expect(std.mem.indexOf(u8, doc, "scenarios/basic") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "scenarios/regressions") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "loadPackScenario") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "optional packs") != null);
}
