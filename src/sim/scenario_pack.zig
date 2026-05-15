const std = @import("std");
const scenario = @import("scenario.zig");
const types = @import("types.zig");

pub const ScenarioPackEntry = struct {
    key: []const u8,
    path: []const u8,
    description: []const u8,
    picker_policy: types.PolicyKind = .fcfs,
    canonical: bool = false,
    theme: ?CurriculumTheme = null,
    explanation_doc: ?[]const u8 = null,
    recommended_policy: ?types.PolicyKind = null,
    manual_demo: bool = false,
    regression_use: bool = false,
};

pub const ScenarioPack = struct {
    key: []const u8,
    directory: []const u8,
    description: []const u8,
    optional: bool,
    scenarios: []const ScenarioPackEntry,
};

pub const CurriculumTheme = enum {
    convoy,
    blocked_wakeup,
    bursty_io,
    starvation,
    deadlines,
    groups,
    balancing,
    topology,
    fairness,
};

pub fn curriculumThemeLabel(theme: CurriculumTheme) []const u8 {
    return switch (theme) {
        .convoy => "convoy",
        .blocked_wakeup => "blocked/wakeup",
        .bursty_io => "bursty I/O",
        .starvation => "starvation",
        .deadlines => "deadlines",
        .groups => "groups",
        .balancing => "balancing",
        .topology => "topology",
        .fairness => "fairness",
    };
}

const core_pack_entries = [_]ScenarioPackEntry{
    .{ .key = "arrivals", .path = "scenarios/basic/arrivals.zon", .description = "Canonical object-style arrival ordering fixture", .picker_policy = .fcfs },
    .{ .key = "contention", .path = "scenarios/basic/contention.zon", .description = "Equal-arrival contention teaching fixture", .picker_policy = .fcfs },
    .{
        .key = "deadline-priority",
        .path = "scenarios/basic/deadline-priority.zon",
        .description = "Deadline-inspired comparison fixture",
        .picker_policy = .deadline,
        .canonical = true,
        .theme = .deadlines,
        .explanation_doc = "docs/deadline-policy.md",
        .recommended_policy = .deadline,
        .manual_demo = true,
        .regression_use = true,
    },
    .{ .key = "equal-arrival-contention", .path = "scenarios/basic/equal-arrival-contention.zon", .description = "Built-in contention alias target", .picker_policy = .fcfs },
    .{
        .key = "group-fairness",
        .path = "scenarios/basic/group-fairness.zon",
        .description = "Group scheduling teaching fixture",
        .picker_policy = .cfs_like,
        .canonical = true,
        .theme = .groups,
        .explanation_doc = "docs/group-scheduling.md",
        .recommended_policy = .cfs_like,
        .manual_demo = true,
        .regression_use = true,
    },
    .{
        .key = "latency-probe",
        .path = "scenarios/basic/latency-probe.zon",
        .description = "Latency comparison teaching fixture",
        .picker_policy = .round_robin,
        .canonical = true,
        .theme = .fairness,
        .explanation_doc = "docs/fairness-probes.md",
        .recommended_policy = .round_robin,
        .manual_demo = true,
        .regression_use = true,
    },
    .{
        .key = "multi-phase-io",
        .path = "scenarios/basic/multi-phase-io.zon",
        .description = "Deterministic CPU/wait phase fixture",
        .picker_policy = .round_robin,
        .canonical = true,
        .theme = .bursty_io,
        .explanation_doc = "docs/phase1-simulator.md",
        .recommended_policy = .round_robin,
        .manual_demo = true,
        .regression_use = true,
    },
    .{
        .key = "multicore-balancing",
        .path = "scenarios/basic/multicore-balancing.zon",
        .description = "Idle-core rebalance fixture",
        .picker_policy = .fcfs,
        .canonical = true,
        .theme = .balancing,
        .explanation_doc = "docs/scenario-corpus.md",
        .recommended_policy = .fcfs,
        .manual_demo = true,
        .regression_use = true,
    },
    .{ .key = "multicore-contention", .path = "scenarios/basic/multicore-contention.zon", .description = "Baseline deterministic multicore fixture", .picker_policy = .fcfs },
    .{ .key = "multicore-rr-quantum", .path = "scenarios/basic/multicore-rr-quantum.zon", .description = "Multicore Round Robin preemption fixture", .picker_policy = .round_robin },
    .{ .key = "multicore-simultaneous-complete", .path = "scenarios/basic/multicore-simultaneous-complete.zon", .description = "Deterministic same-tick completion fixture", .picker_policy = .fcfs },
    .{ .key = "multicore-staggered", .path = "scenarios/basic/multicore-staggered.zon", .description = "Staggered multicore arrival fixture", .picker_policy = .fcfs },
    .{ .key = "multicore-weighted", .path = "scenarios/basic/multicore-weighted.zon", .description = "Weighted multicore fairness fixture", .picker_policy = .cfs_like },
    .{
        .key = "short-vs-long",
        .path = "scenarios/basic/short-vs-long.zon",
        .description = "Golden short-job versus long-job contention fixture",
        .picker_policy = .fcfs,
        .canonical = true,
        .theme = .convoy,
        .explanation_doc = "docs/phase1-scenario-c-walkthrough.md",
        .recommended_policy = .fcfs,
        .manual_demo = true,
        .regression_use = true,
    },
    .{
        .key = "sleep-wakeup",
        .path = "scenarios/basic/sleep-wakeup.zon",
        .description = "Blocked/wakeup teaching fixture",
        .picker_policy = .cfs_like,
        .canonical = true,
        .theme = .blocked_wakeup,
        .explanation_doc = "docs/phase1-simulator.md",
        .recommended_policy = .cfs_like,
        .manual_demo = true,
        .regression_use = true,
    },
    .{ .key = "staggered-arrivals", .path = "scenarios/basic/staggered-arrivals.zon", .description = "Built-in staggered arrivals fixture", .picker_policy = .fcfs },
    .{
        .key = "starvation-pressure",
        .path = "scenarios/basic/starvation-pressure.zon",
        .description = "Weighted starvation-pressure probe fixture",
        .picker_policy = .cfs_like,
        .canonical = true,
        .theme = .starvation,
        .explanation_doc = "docs/fairness-probes.md",
        .recommended_policy = .cfs_like,
        .manual_demo = true,
        .regression_use = true,
    },
    .{
        .key = "topology-domains",
        .path = "scenarios/basic/topology-domains.zon",
        .description = "Topology-aware multicore teaching fixture",
        .picker_policy = .fcfs,
        .canonical = true,
        .theme = .topology,
        .explanation_doc = "docs/topology-simulation.md",
        .recommended_policy = .fcfs,
        .manual_demo = true,
        .regression_use = true,
    },
    .{ .key = "weighted-fairness", .path = "scenarios/basic/weighted-fairness.zon", .description = "Single-core weight-aware fairness fixture", .picker_policy = .cfs_like },
};

pub const core_pack_key = "core/basic";

const regression_pack_entries = [_]ScenarioPackEntry{};

const registered_packs = [_]ScenarioPack{
    .{
        .key = "core/basic",
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

fn mustFindCoreEntry(comptime scenario_key: []const u8) ScenarioPackEntry {
    inline for (core_pack_entries) |entry| {
        if (std.mem.eql(u8, entry.key, scenario_key)) return entry;
    }
    @compileError("unknown core scenario key in teaching shortlist: " ++ scenario_key);
}

const teaching_entries = [_]ScenarioPackEntry{
    mustFindCoreEntry("short-vs-long"),
    mustFindCoreEntry("sleep-wakeup"),
    mustFindCoreEntry("multicore-balancing"),
};

pub fn listScenarioPacks() []const ScenarioPack {
    return registered_packs[0..];
}

pub fn listteachingTeachingEntries() []const ScenarioPackEntry {
    return teaching_entries[0..];
}

pub fn findteachingTeachingEntry(scenario_key: []const u8) ?ScenarioPackEntry {
    for (teaching_entries) |entry| {
        if (std.mem.eql(u8, entry.key, scenario_key)) return entry;
    }
    return null;
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
