const std = @import("std");
const scenario = @import("scenario.zig");
const types = @import("types.zig");

pub const ScenarioPackEntry = struct {
    key: []const u8,
    path: []const u8,
    description: []const u8,
};

pub const ScenarioPack = struct {
    key: []const u8,
    directory: []const u8,
    description: []const u8,
    optional: bool,
    scenarios: []const ScenarioPackEntry,
};

const core_pack_entries = [_]ScenarioPackEntry{
    .{ .key = "arrivals", .path = "scenarios/basic/arrivals.zon", .description = "Canonical object-style arrival ordering fixture" },
    .{ .key = "contention", .path = "scenarios/basic/contention.zon", .description = "Equal-arrival contention teaching fixture" },
    .{ .key = "deadline-priority", .path = "scenarios/basic/deadline-priority.zon", .description = "Deadline-inspired comparison fixture" },
    .{ .key = "equal-arrival-contention", .path = "scenarios/basic/equal-arrival-contention.zon", .description = "Built-in contention alias target" },
    .{ .key = "group-fairness", .path = "scenarios/basic/group-fairness.zon", .description = "Group scheduling teaching fixture" },
    .{ .key = "latency-probe", .path = "scenarios/basic/latency-probe.zon", .description = "Latency comparison teaching fixture" },
    .{ .key = "multi-phase-io", .path = "scenarios/basic/multi-phase-io.zon", .description = "Deterministic CPU/wait phase fixture" },
    .{ .key = "multicore-balancing", .path = "scenarios/basic/multicore-balancing.zon", .description = "Idle-core rebalance fixture" },
    .{ .key = "multicore-contention", .path = "scenarios/basic/multicore-contention.zon", .description = "Baseline deterministic multicore fixture" },
    .{ .key = "multicore-rr-quantum", .path = "scenarios/basic/multicore-rr-quantum.zon", .description = "Multicore Round Robin preemption fixture" },
    .{ .key = "multicore-simultaneous-complete", .path = "scenarios/basic/multicore-simultaneous-complete.zon", .description = "Deterministic same-tick completion fixture" },
    .{ .key = "multicore-staggered", .path = "scenarios/basic/multicore-staggered.zon", .description = "Staggered multicore arrival fixture" },
    .{ .key = "multicore-weighted", .path = "scenarios/basic/multicore-weighted.zon", .description = "Weighted multicore fairness fixture" },
    .{ .key = "short-vs-long", .path = "scenarios/basic/short-vs-long.zon", .description = "Golden short-job versus long-job contention fixture" },
    .{ .key = "sleep-wakeup", .path = "scenarios/basic/sleep-wakeup.zon", .description = "Blocked/wakeup teaching fixture" },
    .{ .key = "staggered-arrivals", .path = "scenarios/basic/staggered-arrivals.zon", .description = "Built-in staggered arrivals fixture" },
    .{ .key = "starvation-pressure", .path = "scenarios/basic/starvation-pressure.zon", .description = "Weighted starvation-pressure probe fixture" },
    .{ .key = "topology-domains", .path = "scenarios/basic/topology-domains.zon", .description = "Topology-aware multicore teaching fixture" },
    .{ .key = "weighted-fairness", .path = "scenarios/basic/weighted-fairness.zon", .description = "Single-core weight-aware fairness fixture" },
};

const regression_pack_entries = [_]ScenarioPackEntry{};

const registered_packs = [_]ScenarioPack{
    .{
        .key = "core",
        .directory = "scenarios/basic",
        .description = "Committed teaching and regression-safe fixtures that ship with the core simulator",
        .optional = false,
        .scenarios = core_pack_entries[0..],
    },
    .{
        .key = "regressions",
        .directory = "scenarios/regressions",
        .description = "Optional minimized failure fixtures saved by property and extension workflows",
        .optional = true,
        .scenarios = regression_pack_entries[0..],
    },
};

pub fn listScenarioPacks() []const ScenarioPack {
    return registered_packs[0..];
}

pub fn findScenarioPack(pack_key: []const u8) ?ScenarioPack {
    for (registered_packs) |pack| {
        if (std.mem.eql(u8, pack.key, pack_key)) return pack;
    }
    return null;
}

pub fn listScenarioPackEntries(pack_key: []const u8) ?[]const ScenarioPackEntry {
    const pack = findScenarioPack(pack_key) orelse return null;
    return pack.scenarios;
}

pub fn findScenarioPackEntry(pack_key: []const u8, scenario_key: []const u8) ?ScenarioPackEntry {
    const pack = findScenarioPack(pack_key) orelse return null;
    for (pack.scenarios) |entry| {
        if (std.mem.eql(u8, entry.key, scenario_key)) return entry;
    }
    return null;
}

pub fn loadPackScenario(allocator: std.mem.Allocator, pack_key: []const u8, scenario_key: []const u8) !types.ScenarioOwned {
    const entry = findScenarioPackEntry(pack_key, scenario_key) orelse return error.UnknownScenario;
    return scenario.loadScenarioFile(allocator, entry.path);
}
