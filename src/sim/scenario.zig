const std = @import("std");
const types = @import("types.zig");

pub const BuiltinScenario = enum {
    staggered_arrivals,
    equal_arrival_contention,
    short_vs_long,
};

pub const BuiltinScenarioMeta = struct {
    id: BuiltinScenario,
    key: []const u8,
    path: []const u8,
    description: []const u8,
};

const builtin_scenarios = [_]BuiltinScenarioMeta{
    .{
        .id = .staggered_arrivals,
        .key = "staggered-arrivals",
        .path = "scenarios/basic/staggered-arrivals.zon",
        .description = "Staggered arrivals for deterministic waiting-time comparisons",
    },
    .{
        .id = .equal_arrival_contention,
        .key = "equal-arrival-contention",
        .path = "scenarios/basic/equal-arrival-contention.zon",
        .description = "Equal-arrival contention to compare ordering and fairness",
    },
    .{
        .id = .short_vs_long,
        .key = "short-vs-long",
        .path = "scenarios/basic/short-vs-long.zon",
        .description = "Golden-oracle short-job versus long-job contention",
    },
};

const legacy_aliases = [_]struct {
    alias: []const u8,
    canonical: BuiltinScenario,
}{
    .{ .alias = "arrivals", .canonical = .staggered_arrivals },
    .{ .alias = "contention", .canonical = .equal_arrival_contention },
};

pub fn listBuiltinScenarios() []const BuiltinScenarioMeta {
    return builtin_scenarios[0..];
}

pub fn loadBuiltinScenario(allocator: std.mem.Allocator, builtin: BuiltinScenario) !types.ScenarioOwned {
    const entry = builtinMeta(builtin);
    return loadScenarioFileWithName(allocator, entry.path, entry.key);
}

pub fn loadScenarioByName(allocator: std.mem.Allocator, name: []const u8) !types.ScenarioOwned {
    return loadNamedScenario(allocator, name);
}

pub fn loadNamedScenario(allocator: std.mem.Allocator, name: []const u8) !types.ScenarioOwned {
    if (resolveBuiltinByName(name)) |builtin| {
        return loadBuiltinScenario(allocator, builtin);
    }
    return error.UnknownScenario;
}

pub fn loadScenarioFile(allocator: std.mem.Allocator, path: []const u8) !types.ScenarioOwned {
    return loadScenarioFileWithName(allocator, path, "");
}

pub fn parseScenarioText(
    allocator: std.mem.Allocator,
    source: []const u8,
    expected_name: []const u8,
) !types.ScenarioOwned {
    var lines = std.mem.tokenizeScalar(u8, source, '\n');
    var task_specs: std.ArrayList(types.TaskSpec) = .empty;
    errdefer {
        for (task_specs.items) |task| allocator.free(task.id);
        task_specs.deinit(allocator);
    }

    var maybe_name: ?[]u8 = null;
    errdefer if (maybe_name) |name| allocator.free(name);

    var quantum: u32 = 1;

    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        if (std.mem.startsWith(u8, line, "name:")) {
            const value = std.mem.trim(u8, line["name:".len..], " \t");
            if (value.len == 0) return error.MissingName;
            if (maybe_name) |name| allocator.free(name);
            maybe_name = try allocator.dupe(u8, value);
            continue;
        }

        if (std.mem.startsWith(u8, line, "rr_quantum:")) {
            const value = std.mem.trim(u8, line["rr_quantum:".len..], " \t");
            quantum = std.fmt.parseInt(u32, value, 10) catch return error.InvalidInteger;
            continue;
        }

        if (std.mem.startsWith(u8, line, "task:")) {
            const payload = std.mem.trim(u8, line["task:".len..], " \t");
            var parts = std.mem.tokenizeAny(u8, payload, " \t");
            const id = parts.next() orelse return error.InvalidTaskLine;
            const arrival_text = parts.next() orelse return error.InvalidTaskLine;
            const burst_text = parts.next() orelse return error.InvalidTaskLine;
            if (parts.next() != null) return error.InvalidTaskLine;

            try task_specs.append(allocator, .{
                .id = try allocator.dupe(u8, id),
                .arrival_tick = std.fmt.parseInt(u32, arrival_text, 10) catch return error.InvalidInteger,
                .burst_ticks = std.fmt.parseInt(u32, burst_text, 10) catch return error.InvalidInteger,
            });
            continue;
        }

        return error.InvalidLine;
    }

    const name = maybe_name orelse return error.MissingName;
    if (expected_name.len != 0 and !std.mem.eql(u8, expected_name, name)) {
        return error.ScenarioNameMismatch;
    }

    const tasks = try task_specs.toOwnedSlice(allocator);
    errdefer {
        for (tasks) |task| allocator.free(task.id);
        allocator.free(tasks);
    }

    var scenario = types.ScenarioOwned{
        .allocator = allocator,
        .name = name,
        .round_robin_quantum = quantum,
        .tasks = tasks,
    };
    try normalizeAndValidate(&scenario);
    return scenario;
}

pub fn parseScenario(allocator: std.mem.Allocator, source: []const u8) !types.ScenarioOwned {
    return parseScenarioText(allocator, source, "");
}

pub fn freeScenario(_: std.mem.Allocator, scenario: types.ScenarioOwned) void {
    var owned = scenario;
    owned.deinit();
}

fn loadScenarioFileWithName(
    allocator: std.mem.Allocator,
    path: []const u8,
    expected_name: []const u8,
) !types.ScenarioOwned {
    const source = try std.fs.cwd().readFileAlloc(allocator, path, std.math.maxInt(usize));
    defer allocator.free(source);
    return parseScenarioText(allocator, source, expected_name);
}

fn resolveBuiltinByName(name: []const u8) ?BuiltinScenario {
    for (builtin_scenarios) |entry| {
        if (std.mem.eql(u8, entry.key, name)) return entry.id;
    }
    for (legacy_aliases) |entry| {
        if (std.mem.eql(u8, entry.alias, name)) return entry.canonical;
    }
    return null;
}

fn builtinMeta(builtin: BuiltinScenario) BuiltinScenarioMeta {
    for (builtin_scenarios) |entry| {
        if (entry.id == builtin) return entry;
    }
    unreachable;
}

fn normalizeAndValidate(scenario: *types.ScenarioOwned) !void {
    for (scenario.tasks, 0..) |*task, index| {
        task.input_order = @as(u32, @intCast(index));
        task.order = @as(u32, @intCast(index));
    }
    try scenario.validate();
}
