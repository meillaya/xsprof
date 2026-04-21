const std = @import("std");
const cli = @import("../cli/root.zig");
const engine = @import("../sim/engine.zig");
const scenario_mod = @import("../sim/scenario.zig");
const types = @import("../sim/types.zig");

pub const GeneratorOptions = struct {
    seed: u64,
    max_tasks: u8 = 5,
    max_arrival_tick: u32 = 6,
    max_burst_ticks: u32 = 6,
    max_core_count: u32 = 4,
    allow_weights: bool = true,
    allow_deadlines: bool = true,
    allow_groups: bool = true,
    allow_topology: bool = true,
};

pub const GeneratedGroup = struct {
    weight: u32 = types.default_group_weight,
    quota_ticks: u32 = 0,
};

pub const GeneratedTask = struct {
    arrival_tick: u32,
    burst_ticks: u32,
    weight: ?u32 = null,
    group_index: ?usize = null,
    deadline_tick: ?u32 = null,
};

pub const GeneratedScenario = struct {
    allocator: std.mem.Allocator,
    name: []u8,
    round_robin_quantum: u32,
    core_count: u32,
    use_topology_domains: bool,
    groups: []GeneratedGroup,
    tasks: []GeneratedTask,

    pub fn deinit(self: *GeneratedScenario) void {
        self.allocator.free(self.name);
        self.allocator.free(self.groups);
        self.allocator.free(self.tasks);
        self.* = undefined;
    }

    pub fn clone(self: *const GeneratedScenario, allocator: std.mem.Allocator) !GeneratedScenario {
        const name = try allocator.dupe(u8, self.name);
        errdefer allocator.free(name);

        const groups = try allocator.dupe(GeneratedGroup, self.groups);
        errdefer allocator.free(groups);

        const tasks = try allocator.dupe(GeneratedTask, self.tasks);
        errdefer allocator.free(tasks);

        return .{
            .allocator = allocator,
            .name = name,
            .round_robin_quantum = self.round_robin_quantum,
            .core_count = self.core_count,
            .use_topology_domains = self.use_topology_domains,
            .groups = groups,
            .tasks = tasks,
        };
    }

    pub fn sizeScore(self: GeneratedScenario) usize {
        var score: usize = self.tasks.len * 1000;
        score += self.groups.len * 200;
        score += @as(usize, self.core_count) * 50;
        score += @as(usize, self.round_robin_quantum) * 20;
        if (self.usesTopologyDomains()) score += 100;

        for (self.groups) |group| {
            score += @as(usize, group.weight / 256);
            score += group.quota_ticks;
        }

        for (self.tasks) |task| {
            score += task.arrival_tick;
            score += task.burst_ticks * 10;
            if (task.weight != null) score += 10;
            if (task.group_index != null) score += 10;
            if (task.deadline_tick) |deadline_tick| {
                score += 10;
                score += deadline_tick - task.arrival_tick;
            }
        }

        return score;
    }

    pub fn renderZonAlloc(self: *const GeneratedScenario, allocator: std.mem.Allocator) ![]u8 {
        var buffer: std.ArrayList(u8) = .empty;
        errdefer buffer.deinit(allocator);

        var writer = buffer.writer(allocator);
        try writer.writeAll(".{\n");
        try writer.print("    .name = \"{s}\",\n", .{self.name});
        try writer.print("    .quantum = {d},\n", .{self.round_robin_quantum});
        try writer.print("    .core_count = {d},\n", .{self.core_count});

        if (self.usesTopologyDomains()) {
            const split = (self.core_count + 1) / 2;
            try writer.writeAll("    .topology_domains = .{\n");
            try writer.writeAll("        .{ .id = \"node0\", .cores = .{");
            try writeCoreList(&writer, 0, split);
            try writer.writeAll(" } },\n");
            try writer.writeAll("        .{ .id = \"node1\", .cores = .{");
            try writeCoreList(&writer, split, self.core_count);
            try writer.writeAll(" } },\n");
            try writer.writeAll("    },\n");
        }

        if (self.groups.len != 0) {
            try writer.writeAll("    .groups = .{\n");
            for (self.groups, 0..) |group, index| {
                try writer.print(
                    "        .{{ .id = \"g{d}\", .weight = {d}, .quota_ticks = {d} }},\n",
                    .{ index, group.weight, group.quota_ticks },
                );
            }
            try writer.writeAll("    },\n");
        }

        try writer.writeAll("    .tasks = .{\n");
        for (self.tasks, 0..) |task, index| {
            try writer.print(
                "        .{{ .id = \"T{d}\", .arrival_tick = {d}, .burst_ticks = {d}",
                .{ index, task.arrival_tick, task.burst_ticks },
            );
            if (task.weight) |weight| try writer.print(", .weight = {d}", .{weight});
            if (task.group_index) |group_index| try writer.print(", .group_id = \"g{d}\"", .{group_index});
            if (task.deadline_tick) |deadline_tick| try writer.print(", .deadline_tick = {d}", .{deadline_tick});
            try writer.writeAll(" },\n");
        }
        try writer.writeAll("    },\n");
        try writer.writeAll("}\n");

        return try buffer.toOwnedSlice(allocator);
    }

    pub fn materialize(self: *const GeneratedScenario, allocator: std.mem.Allocator) !types.ScenarioOwned {
        const zon = try self.renderZonAlloc(allocator);
        defer allocator.free(zon);

        var scenario = try scenario_mod.parseScenarioText(allocator, zon, self.name);
        try scenario.validate();
        return scenario;
    }

    pub fn writeZonFile(self: *const GeneratedScenario, allocator: std.mem.Allocator, dir: anytype, sub_path: []const u8) !void {
        const zon = try self.renderZonAlloc(allocator);
        defer allocator.free(zon);
        try dir.writeFile(.{ .sub_path = sub_path, .data = zon });
    }

    pub fn renderJsonAlloc(
        self: *const GeneratedScenario,
        allocator: std.mem.Allocator,
        policy: types.PolicyKind,
    ) ![]u8 {
        var scenario = try self.materialize(allocator);
        defer scenario.deinit();
        var result = try engine.simulate(allocator, &scenario, policy);
        defer result.deinit();

        const source: cli.SourceInfo = .{ .kind = .file, .value = self.name };
        const report = cli.SimulationReport.init(source, &scenario, &result);

        var buffer: std.ArrayList(u8) = .empty;
        errdefer buffer.deinit(allocator);
        var writer = buffer.writer(allocator);
        try cli.writeJsonReport(&writer, report);
        return try buffer.toOwnedSlice(allocator);
    }

    fn usesTopologyDomains(self: *const GeneratedScenario) bool {
        return self.use_topology_domains and self.core_count > 1;
    }
};

pub fn generateScenario(allocator: std.mem.Allocator, options: GeneratorOptions) !GeneratedScenario {
    var prng = std.Random.DefaultPrng.init(options.seed);
    const random = prng.random();

    const max_tasks = @max(options.max_tasks, 1);
    const task_count: usize = @intCast(random.intRangeAtMost(u8, 1, max_tasks));

    const core_limit = @max(@as(u32, 1), options.max_core_count);
    const raw_core_count = if (task_count > 1)
        random.intRangeAtMost(u32, 1, core_limit)
    else
        @as(u32, 1);
    const core_count = @min(raw_core_count, @as(u32, @intCast(task_count)));

    const use_groups = options.allow_groups and task_count >= 2 and random.boolean();
    const group_count: usize = if (use_groups) 2 else 0;
    const groups = try allocator.alloc(GeneratedGroup, group_count);
    errdefer allocator.free(groups);
    for (groups, 0..) |*group, index| {
        group.* = .{
            .weight = if (index == 0) 2048 else 768,
            .quota_ticks = if (index == 0 and random.boolean()) 1 else 0,
        };
    }

    const tasks = try allocator.alloc(GeneratedTask, task_count);
    errdefer allocator.free(tasks);
    for (tasks, 0..) |*task, index| {
        const arrival_tick = random.intRangeAtMost(u32, 0, options.max_arrival_tick);
        const burst_ticks = random.intRangeAtMost(u32, 1, @max(options.max_burst_ticks, 1));

        const weight = if (options.allow_weights and random.boolean())
            switch (random.uintAtMost(u8, 3)) {
                0 => @as(u32, 256),
                1 => @as(u32, 512),
                2 => @as(u32, 2048),
                else => @as(u32, types.max_task_weight),
            }
        else
            null;

        const deadline_tick = if (options.allow_deadlines and random.boolean())
            arrival_tick + burst_ticks + random.intRangeAtMost(u32, 0, 6)
        else
            null;

        task.* = .{
            .arrival_tick = arrival_tick,
            .burst_ticks = burst_ticks,
            .weight = weight,
            .group_index = if (group_count == 0) null else random.uintAtMost(usize, group_count - 1),
            .deadline_tick = deadline_tick,
        };

        if (group_count != 0 and index == 0) task.group_index = 0;
    }

    const name = try std.fmt.allocPrint(allocator, "generated-m13-{d}", .{options.seed});
    errdefer allocator.free(name);

    return .{
        .allocator = allocator,
        .name = name,
        .round_robin_quantum = random.intRangeAtMost(u32, 1, 4),
        .core_count = core_count,
        .use_topology_domains = options.allow_topology and core_count > 1 and random.boolean(),
        .groups = groups,
        .tasks = tasks,
    };
}

pub fn shrinkScenario(
    allocator: std.mem.Allocator,
    initial: *const GeneratedScenario,
    context: anytype,
    comptime predicate: fn (@TypeOf(context), *const GeneratedScenario) anyerror!bool,
) !GeneratedScenario {
    var current = try initial.clone(allocator);
    errdefer current.deinit();

    var changed = true;
    while (changed) {
        changed = false;

        if (current.tasks.len > 1) {
            var index = current.tasks.len;
            while (index > 0) {
                index -= 1;
                var candidate = try current.clone(allocator);
                errdefer candidate.deinit();
                try removeTaskAt(&candidate, allocator, index);
                if (candidate.sizeScore() < current.sizeScore() and try predicate(context, &candidate)) {
                    current.deinit();
                    current = candidate;
                    changed = true;
                    break;
                }
                candidate.deinit();
            }
            if (changed) continue;
        }

        if (current.use_topology_domains) {
            var candidate = try current.clone(allocator);
            errdefer candidate.deinit();
            candidate.use_topology_domains = false;
            if (candidate.sizeScore() < current.sizeScore() and try predicate(context, &candidate)) {
                current.deinit();
                current = candidate;
                changed = true;
                continue;
            }
            candidate.deinit();
        }

        if (current.core_count > 1) {
            var candidate = try current.clone(allocator);
            errdefer candidate.deinit();
            candidate.core_count = 1;
            candidate.use_topology_domains = false;
            if (candidate.sizeScore() < current.sizeScore() and try predicate(context, &candidate)) {
                current.deinit();
                current = candidate;
                changed = true;
                continue;
            }
            candidate.deinit();
        }

        if (current.groups.len != 0) {
            var candidate = try current.clone(allocator);
            errdefer candidate.deinit();
            candidate.allocator.free(candidate.groups);
            candidate.groups = try candidate.allocator.alloc(GeneratedGroup, 0);
            for (candidate.tasks) |*task| task.group_index = null;
            if (candidate.sizeScore() < current.sizeScore() and try predicate(context, &candidate)) {
                current.deinit();
                current = candidate;
                changed = true;
                continue;
            }
            candidate.deinit();
        }

        if (current.round_robin_quantum > 1) {
            var candidate = try current.clone(allocator);
            errdefer candidate.deinit();
            candidate.round_robin_quantum = 1;
            if (candidate.sizeScore() < current.sizeScore() and try predicate(context, &candidate)) {
                current.deinit();
                current = candidate;
                changed = true;
                continue;
            }
            candidate.deinit();
        }

        var task_index: usize = 0;
        while (task_index < current.tasks.len) : (task_index += 1) {
            if (try trySimplifyTask(allocator, &current, task_index, context, predicate)) {
                changed = true;
                break;
            }
        }
    }

    return current;
}

fn trySimplifyTask(
    allocator: std.mem.Allocator,
    current: *GeneratedScenario,
    task_index: usize,
    context: anytype,
    comptime predicate: fn (@TypeOf(context), *const GeneratedScenario) anyerror!bool,
) !bool {
    const mutations = [_]struct {
        apply: *const fn (*GeneratedTask) void,
    }{
        .{ .apply = clearGroupMutation },
        .{ .apply = clearWeightMutation },
        .{ .apply = clearDeadlineMutation },
        .{ .apply = reduceArrivalMutation },
        .{ .apply = reduceBurstMutation },
    };

    for (mutations) |mutation| {
        var candidate = try current.clone(allocator);
        errdefer candidate.deinit();
        mutation.apply(&candidate.tasks[task_index]);
        if (candidate.sizeScore() < current.sizeScore() and try predicate(context, &candidate)) {
            current.deinit();
            current.* = candidate;
            return true;
        }
        candidate.deinit();
    }

    return false;
}

fn clearGroupMutation(task: *GeneratedTask) void {
    task.group_index = null;
}

fn clearWeightMutation(task: *GeneratedTask) void {
    task.weight = null;
}

fn clearDeadlineMutation(task: *GeneratedTask) void {
    task.deadline_tick = null;
}

fn reduceArrivalMutation(task: *GeneratedTask) void {
    task.arrival_tick = 0;
}

fn reduceBurstMutation(task: *GeneratedTask) void {
    task.burst_ticks = 1;
    if (task.deadline_tick) |deadline_tick| {
        task.deadline_tick = @min(deadline_tick, task.arrival_tick + 1);
    }
}

fn removeTaskAt(self: *GeneratedScenario, allocator: std.mem.Allocator, index: usize) !void {
    const reduced = try allocator.alloc(GeneratedTask, self.tasks.len - 1);
    errdefer allocator.free(reduced);

    if (index != 0) {
        @memcpy(reduced[0..index], self.tasks[0..index]);
    }
    if (index + 1 < self.tasks.len) {
        @memcpy(reduced[index..], self.tasks[index + 1 ..]);
    }

    allocator.free(self.tasks);
    self.tasks = reduced;
}

fn writeCoreList(writer: anytype, start: u32, end: u32) !void {
    var core_id = start;
    while (core_id < end) : (core_id += 1) {
        if (core_id != start) try writer.writeAll(", ");
        try writer.print("{d}", .{core_id});
    }
}
