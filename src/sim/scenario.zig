const std = @import("std");
const types = @import("types.zig");

pub const BuiltinScenario = enum {
    arrivals,
    contention,
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
        .id = .arrivals,
        .key = "arrivals",
        .path = "scenarios/basic/arrivals.zon",
        .description = "Staggered arrivals with moderate CPU bursts",
    },
    .{
        .id = .contention,
        .key = "contention",
        .path = "scenarios/basic/contention.zon",
        .description = "Equal-arrival contention for fairness comparisons",
    },
    .{
        .id = .short_vs_long,
        .key = "short-vs-long",
        .path = "scenarios/basic/short-vs-long.zon",
        .description = "Golden-oracle short-job versus long-job contention",
    },
};

pub fn listBuiltinScenarios() []const BuiltinScenarioMeta {
    return builtin_scenarios[0..];
}

pub fn loadBuiltinScenario(
    allocator: std.mem.Allocator,
    builtin: BuiltinScenario,
) !types.Scenario {
    for (builtin_scenarios) |entry| {
        if (entry.id == builtin) {
            return loadScenarioFile(allocator, entry.path);
        }
    }
    unreachable;
}

pub fn loadNamedScenario(
    allocator: std.mem.Allocator,
    name: []const u8,
) !types.Scenario {
    for (builtin_scenarios) |entry| {
        if (std.mem.eql(u8, entry.key, name)) {
            return loadScenarioFile(allocator, entry.path);
        }
    }

    return error.UnknownScenario;
}

pub fn loadScenarioFile(
    allocator: std.mem.Allocator,
    path: []const u8,
) !types.Scenario {
    const source = try std.fs.cwd().readFileAlloc(allocator, path, std.math.maxInt(usize));
    defer allocator.free(source);

    const source_z = try allocator.dupeZ(u8, source);
    defer allocator.free(source_z);

    return parseScenario(allocator, source_z);
}

pub fn parseScenario(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
) !types.Scenario {
    var diag: std.zon.parse.Diagnostics = .{};
    var scenario = try std.zon.parse.fromSliceAlloc(types.Scenario, allocator, source, &diag, .{});
    errdefer std.zon.parse.free(allocator, scenario);

    try normalizeAndValidate(&scenario);
    return scenario;
}

pub fn freeScenario(allocator: std.mem.Allocator, scenario: types.Scenario) void {
    std.zon.parse.free(allocator, scenario);
}

fn normalizeAndValidate(scenario: *types.Scenario) !void {
    try scenario.validate();

    for (scenario.tasks, 0..) |*task, index| {
        task.order = @as(u32, @intCast(index));
    }

    for (scenario.tasks, 0..) |task, index| {
        for (scenario.tasks[index + 1 ..]) |other| {
            if (std.mem.eql(u8, task.id, other.id)) {
                return error.DuplicateTaskId;
            }
        }
    }
}
