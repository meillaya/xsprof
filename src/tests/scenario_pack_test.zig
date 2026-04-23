const std = @import("std");
const sim = @import("../root.zig");

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return try std.fs.cwd().readFileAlloc(allocator, path, std.math.maxInt(usize));
}

fn renderJson(
    allocator: std.mem.Allocator,
    entry: sim.scenario_packs.ScenarioPackEntry,
) ![]u8 {
    var scenario = try sim.scenario_packs.loadPackScenario(allocator, "core/basic", entry.key);
    defer scenario.deinit();

    var result = try sim.simulate(allocator, &scenario, entry.recommended_policy.?);
    defer result.deinit();

    const report = sim.cli.SimulationReport.init(.{ .kind = .file, .value = entry.path }, &scenario, &result);
    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(allocator);
    var writer = buffer.writer(allocator);
    try sim.cli.writeJsonReport(&writer, report);
    return try buffer.toOwnedSlice(allocator);
}

test "M14 scenario pack registry exposes committed core fixtures and optional regression pack" {
    const packs = sim.scenario_packs.listScenarioPacks();
    try std.testing.expectEqual(@as(usize, 2), packs.len);

    try std.testing.expectEqualStrings("core/basic", packs[0].key);
    try std.testing.expectEqualStrings("scenarios/basic", packs[0].directory);
    try std.testing.expect(!packs[0].optional);
    try std.testing.expect(packs[0].scenarios.len >= 10);

    try std.testing.expectEqualStrings("regressions", packs[1].key);
    try std.testing.expectEqualStrings("scenarios/regressions", packs[1].directory);
    try std.testing.expect(packs[1].optional);
}

test "M14 scenario pack loader resolves core fixtures without optional extras" {
    var scenario = try sim.scenario_packs.loadPackScenario(std.testing.allocator, "core/basic", "weighted-fairness");
    defer scenario.deinit();

    try std.testing.expectEqualStrings("weighted-fairness", scenario.name);
    try std.testing.expectEqual(@as(usize, 3), scenario.tasks.len);
    try std.testing.expectEqual(@as(u32, 2), scenario.round_robin_quantum);
}

test "M14 scenario pack registry keeps optional regression lane isolated from core loading" {
    try std.testing.expect(sim.scenario_packs.findScenarioPack("core/basic") != null);
    try std.testing.expect(sim.scenario_packs.findScenarioPack("regressions") != null);
    try std.testing.expectEqual(@as(?[]const sim.scenario_packs.ScenarioPackEntry, null), sim.scenario_packs.listScenarioPackEntries("missing"));
    try std.testing.expectError(
        error.UnknownScenario,
        sim.scenario_packs.loadPackScenario(std.testing.allocator, "regressions", "missing-fixture"),
    );

    var scenario = try sim.scenario_packs.loadPackScenario(std.testing.allocator, "core/basic", "topology-domains");
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

test "M17 canonical scenario corpus covers required curriculum themes and metadata" {
    const entries = sim.scenario_packs.listScenarioPackEntries("core/basic").?;
    var saw_convoy = false;
    var saw_starvation = false;
    var saw_bursty_io = false;
    var saw_balancing = false;
    var saw_topology = false;
    var canonical_count: usize = 0;

    for (entries) |entry| {
        if (!entry.canonical) continue;
        canonical_count += 1;
        try std.testing.expect(entry.description.len != 0);
        try std.testing.expect(std.mem.startsWith(u8, entry.path, "scenarios/basic/"));
        try std.testing.expect(entry.theme != null);
        try std.testing.expect(entry.explanation_doc != null);
        try std.testing.expect(entry.recommended_policy != null);
        try std.testing.expect(entry.manual_demo);
        try std.testing.expect(entry.regression_use);
        try std.fs.cwd().access(entry.path, .{});
        try std.fs.cwd().access(entry.explanation_doc.?, .{});

        const explanation = try readFileAlloc(std.testing.allocator, entry.explanation_doc.?);
        defer std.testing.allocator.free(explanation);
        try std.testing.expect(std.mem.indexOf(u8, explanation, entry.key) != null or std.mem.indexOf(u8, explanation, entry.path) != null);

        switch (entry.theme.?) {
            .convoy => saw_convoy = true,
            .starvation => saw_starvation = true,
            .bursty_io => saw_bursty_io = true,
            .balancing => saw_balancing = true,
            .topology => saw_topology = true,
            else => {},
        }
    }

    try std.testing.expect(canonical_count >= 8);
    try std.testing.expect(saw_convoy);
    try std.testing.expect(saw_starvation);
    try std.testing.expect(saw_bursty_io);
    try std.testing.expect(saw_balancing);
    try std.testing.expect(saw_topology);
}

test "M21 shortlist helper stays exact and explanation docs resolve" {
    const shortlist = sim.scenario_packs.listM21TeachingEntries();
    try std.testing.expectEqual(@as(usize, 3), shortlist.len);

    try std.testing.expectEqualStrings("short-vs-long", shortlist[0].key);
    try std.testing.expectEqual(sim.PolicyKind.fcfs, shortlist[0].recommended_policy.?);
    try std.testing.expectEqualStrings("sleep-wakeup", shortlist[1].key);
    try std.testing.expectEqual(sim.PolicyKind.cfs_like, shortlist[1].recommended_policy.?);
    try std.testing.expectEqualStrings("multicore-balancing", shortlist[2].key);
    try std.testing.expectEqual(sim.PolicyKind.fcfs, shortlist[2].recommended_policy.?);

    for (shortlist) |entry| {
        try std.fs.cwd().access(entry.path, .{});
        try std.testing.expect(entry.explanation_doc != null);
        try std.fs.cwd().access(entry.explanation_doc.?, .{});
        try std.testing.expect(sim.scenario_packs.findM21TeachingEntry(entry.key) != null);
    }

    try std.testing.expect(sim.scenario_packs.findM21TeachingEntry("group-fairness") == null);
}

test "M17 canonical scenarios support deterministic smoke runs for demos and regression use" {
    const allocator = std.testing.allocator;
    const entries = sim.scenario_packs.listScenarioPackEntries("core/basic").?;

    for (entries) |entry| {
        if (!entry.canonical) continue;

        var scenario = try sim.scenario_packs.loadPackScenario(allocator, "core/basic", entry.key);
        defer scenario.deinit();
        try std.testing.expectEqualStrings(entry.key, scenario.name);

        const first = try renderJson(allocator, entry);
        defer allocator.free(first);
        const second = try renderJson(allocator, entry);
        defer allocator.free(second);

        try std.testing.expectEqualStrings(first, second);
        try std.testing.expect(std.mem.indexOf(u8, first, "\"schema\":\"zig-scheduler/report\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, first, "\"completion_order\"") != null);
    }
}

test "M17 docs describe the canonical scenario corpus and manual demo path" {
    const allocator = std.testing.allocator;
    const phase_doc = try readFileAlloc(allocator, "docs/phase1-simulator.md");
    defer allocator.free(phase_doc);
    const corpus_doc = try readFileAlloc(allocator, "docs/m17-scenario-corpus.md");
    defer allocator.free(corpus_doc);
    const project_doc = try readFileAlloc(allocator, "docs/project-architecture-and-status.md");
    defer allocator.free(project_doc);

    try std.testing.expect(std.mem.indexOf(u8, corpus_doc, "zig build sim -- --scenario-file") != null);
    try std.testing.expect(std.mem.indexOf(u8, corpus_doc, "short-vs-long") != null);
    try std.testing.expect(std.mem.indexOf(u8, corpus_doc, "starvation-pressure") != null);
    try std.testing.expect(std.mem.indexOf(u8, corpus_doc, "multi-phase-io") != null);
    try std.testing.expect(std.mem.indexOf(u8, corpus_doc, "multicore-balancing") != null);
    try std.testing.expect(std.mem.indexOf(u8, corpus_doc, "topology-domains") != null);
    try std.testing.expect(std.mem.indexOf(u8, corpus_doc, "manual demos") != null);
    try std.testing.expect(std.mem.indexOf(u8, corpus_doc, "automated regression") != null);
    try std.testing.expect(std.mem.indexOf(u8, corpus_doc, "zig build run -- --scenario-file scenarios/basic/multicore-balancing.zon --policy fcfs") != null);
    try std.testing.expect(std.mem.indexOf(u8, phase_doc, "M17") != null);
    try std.testing.expect(std.mem.indexOf(u8, project_doc, "M17 adds an explicit canonical scenario corpus") != null);
}

test "M21 teaching docs stay aligned with the exact three-anchor shortlist" {
    const allocator = std.testing.allocator;
    const m21_doc = try readFileAlloc(allocator, "docs/m21-simulator-first-teaching-surface.md");
    defer allocator.free(m21_doc);
    const corpus_doc = try readFileAlloc(allocator, "docs/m17-scenario-corpus.md");
    defer allocator.free(corpus_doc);
    const teaching_pack = try readFileAlloc(allocator, "docs/labs/simulator-teaching-pack.md");
    defer allocator.free(teaching_pack);

    try std.testing.expect(std.mem.indexOf(u8, m21_doc, "short-vs-long") != null);
    try std.testing.expect(std.mem.indexOf(u8, m21_doc, "sleep-wakeup") != null);
    try std.testing.expect(std.mem.indexOf(u8, m21_doc, "multicore-balancing") != null);
    try std.testing.expect(std.mem.indexOf(u8, corpus_doc, "docs/labs/simulator-teaching-pack.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, teaching_pack, "three") != null);

    const shortlist = sim.scenario_packs.listM21TeachingEntries();
    for (shortlist) |entry| {
        try std.testing.expect(std.mem.indexOf(u8, teaching_pack, entry.key) != null);
    }

    try std.testing.expect(std.mem.indexOf(u8, teaching_pack, "group-fairness") == null);
    try std.testing.expect(std.mem.indexOf(u8, teaching_pack, "topology-domains") == null);
}

test "M23 courseware docs derive the core package from the exact M21 shortlist" {
    const allocator = std.testing.allocator;
    const package_doc = try readFileAlloc(allocator, "docs/courseware/m23-teaching-distribution.md");
    defer allocator.free(package_doc);
    const assignment_doc = try readFileAlloc(allocator, "docs/courseware/assignment-pack-01.md");
    defer allocator.free(assignment_doc);
    const teaching_pack = try readFileAlloc(allocator, "docs/labs/simulator-teaching-pack.md");
    defer allocator.free(teaching_pack);

    const shortlist = sim.scenario_packs.listM21TeachingEntries();
    try std.testing.expectEqual(@as(usize, 3), shortlist.len);

    for (shortlist) |entry| {
        try std.testing.expect(std.mem.indexOf(u8, assignment_doc, entry.key) != null);
        try std.testing.expect(std.mem.indexOf(u8, teaching_pack, entry.key) != null);
    }

    try std.testing.expect(std.mem.indexOf(u8, package_doc, "package shell over M21") != null);
    try std.testing.expect(std.mem.indexOf(u8, assignment_doc, "group-fairness") == null);
    try std.testing.expect(std.mem.indexOf(u8, assignment_doc, "topology-domains") == null);
}
