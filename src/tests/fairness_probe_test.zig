const std = @import("std");
const sim = @import("../root.zig");

fn loadLatencyProbe(allocator: std.mem.Allocator) !sim.ScenarioOwned {
    return sim.loadScenarioFile(allocator, "scenarios/basic/latency-probe.zon");
}

fn loadStarvationPressure(allocator: std.mem.Allocator) !sim.ScenarioOwned {
    return sim.loadScenarioFile(allocator, "scenarios/basic/starvation-pressure.zon");
}

test "latency probe shows round-robin response improvements over FCFS" {
    const allocator = std.testing.allocator;
    var scenario = try loadLatencyProbe(allocator);
    defer scenario.deinit();

    var fcfs = try sim.simulate(allocator, &scenario, .fcfs);
    defer fcfs.deinit();
    var rr = try sim.simulate(allocator, &scenario, .round_robin);
    defer rr.deinit();

    try std.testing.expect(rr.aggregate.max_response_time < fcfs.aggregate.max_response_time);
    try std.testing.expect(rr.aggregate.response_time_spread < fcfs.aggregate.response_time_spread);

    const fcfs_short = fcfs.taskById("s4") orelse return error.MissingShortTask;
    const rr_short = rr.taskById("s4") orelse return error.MissingShortTask;
    try std.testing.expect(rr_short.response_time < fcfs_short.response_time);
}

test "starvation-pressure fixture exposes uneven waiting under weighted fair scheduling" {
    const allocator = std.testing.allocator;
    var scenario = try loadStarvationPressure(allocator);
    defer scenario.deinit();

    var result = try sim.simulate(allocator, &scenario, .cfs_like);
    defer result.deinit();

    const low = result.taskById("low") orelse return error.MissingLowTask;
    const heavy_a = result.taskById("heavyA") orelse return error.MissingHeavyTask;

    try std.testing.expect(low.waiting_time > heavy_a.waiting_time);
    try std.testing.expectEqual(low.waiting_time, result.aggregate.max_waiting_time);
    try std.testing.expect(result.aggregate.waiting_time_spread >= 4);
    try std.testing.expect(result.aggregate.max_response_time >= result.aggregate.response_time_spread);
}

test "M8 docs keep fairness claims evidence-based" {
    const allocator = std.testing.allocator;
    const phase_doc = try std.fs.cwd().readFileAlloc(allocator, "docs/phase1-simulator.md", std.math.maxInt(usize));
    defer allocator.free(phase_doc);
    const fairness_doc = try std.fs.cwd().readFileAlloc(allocator, "docs/m8-fairness-probes.md", std.math.maxInt(usize));
    defer allocator.free(fairness_doc);
    const corpus_doc = try std.fs.cwd().readFileAlloc(allocator, "docs/m17-scenario-corpus.md", std.math.maxInt(usize));
    defer allocator.free(corpus_doc);

    try std.testing.expect(std.mem.indexOf(u8, corpus_doc, "latency-probe") != null);
    try std.testing.expect(std.mem.indexOf(u8, corpus_doc, "starvation-pressure") != null);
    try std.testing.expect(std.mem.indexOf(u8, phase_doc, "max_waiting_time") != null);
    try std.testing.expect(std.mem.indexOf(u8, fairness_doc, "not formal starvation proofs") != null);
    try std.testing.expect(std.mem.indexOf(u8, fairness_doc, "evidence-based") != null);
}
