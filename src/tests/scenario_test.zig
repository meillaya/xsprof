const std = @import("std");
const scheduler = @import("../root.zig");

test "builtin golden scenario fixture matches plan inputs" {
    var scenario = try scheduler.loadBuiltinScenario(std.testing.allocator, .short_vs_long);
    defer scenario.deinit();

    try std.testing.expectEqualStrings("short-vs-long", scenario.name);
    try std.testing.expectEqual(@as(u32, 2), scenario.round_robin_quantum);
    try std.testing.expectEqual(@as(usize, 3), scenario.tasks.len);

    try expectTask(scenario.tasks[0], "L", 0, 8, 0);
    try expectTask(scenario.tasks[1], "S1", 1, 2, 1);
    try expectTask(scenario.tasks[2], "S2", 2, 1, 2);
}

test "named scenario loader resolves arrivals fixture" {
    var scenario = try scheduler.loadNamedScenario(std.testing.allocator, "staggered-arrivals");
    defer scenario.deinit();

    try std.testing.expectEqualStrings("staggered-arrivals", scenario.name);
    try std.testing.expectEqual(@as(usize, 3), scenario.tasks.len);
}

test "scenario pack registry keeps the core/basic layout explicit" {
    const packs = scheduler.listScenarioPacks();
    try std.testing.expectEqual(@as(usize, 1), packs.len);
    try std.testing.expectEqual(scheduler.ScenarioPack.core_basic, packs[0].id);
    try std.testing.expectEqualStrings("core/basic", packs[0].key);
    try std.testing.expectEqualStrings("scenarios/basic", packs[0].directory);
    try std.testing.expect(!packs[0].optional);

    const entries = scheduler.listScenarioPackEntries(.core_basic);
    try std.testing.expectEqual(@as(usize, 3), entries.len);
    try std.testing.expectEqualStrings("staggered-arrivals", entries[0].key);
    try std.testing.expectEqualStrings("staggered-arrivals.zon", entries[0].file_name);
    try std.testing.expectEqualStrings("short-vs-long", entries[2].key);
}

test "pack-qualified names load through the scenario pack registry" {
    var scenario = try scheduler.loadNamedScenario(std.testing.allocator, "core/basic:short-vs-long");
    defer scenario.deinit();

    try std.testing.expectEqualStrings("short-vs-long", scenario.name);
    try std.testing.expectEqual(@as(usize, 3), scenario.tasks.len);
}

test "canonical object style scenario files load by path" {
    var scenario = try scheduler.loadScenarioFile(std.testing.allocator, "scenarios/basic/arrivals.zon");
    defer scenario.deinit();

    try std.testing.expectEqualStrings("arrivals", scenario.name);
    try std.testing.expectEqual(@as(u32, 2), scenario.round_robin_quantum);
    try std.testing.expectEqual(@as(usize, 4), scenario.tasks.len);
    try expectTask(scenario.tasks[0], "A", 0, 5, 0);
    try expectTask(scenario.tasks[3], "D", 6, 1, 3);
}

test "committed multicore fixture corpus parses with explicit core counts" {
    const fixtures = [_]struct {
        path: []const u8,
        name: []const u8,
    }{
        .{ .path = "scenarios/basic/multicore-contention.zon", .name = "multicore-contention" },
        .{ .path = "scenarios/basic/multicore-balancing.zon", .name = "multicore-balancing" },
        .{ .path = "scenarios/basic/multicore-staggered.zon", .name = "multicore-staggered" },
        .{ .path = "scenarios/basic/multicore-weighted.zon", .name = "multicore-weighted" },
        .{ .path = "scenarios/basic/multicore-simultaneous-complete.zon", .name = "multicore-simultaneous-complete" },
        .{ .path = "scenarios/basic/multicore-rr-quantum.zon", .name = "multicore-rr-quantum" },
    };

    for (fixtures) |fixture| {
        var scenario = try scheduler.loadScenarioFile(std.testing.allocator, fixture.path);
        defer scenario.deinit();
        try std.testing.expectEqualStrings(fixture.name, scenario.name);
        try std.testing.expectEqual(@as(u32, 2), scenario.core_count);
        try std.testing.expect(scenario.tasks.len >= 3);
    }
}

test "canonical object style scenario files parse core counts" {
    var scenario = try scheduler.loadScenarioFile(std.testing.allocator, "scenarios/basic/multicore-contention.zon");
    defer scenario.deinit();

    try std.testing.expectEqualStrings("multicore-contention", scenario.name);
    try std.testing.expectEqual(@as(u32, 2), scenario.core_count);
    try std.testing.expectEqual(@as(usize, 4), scenario.tasks.len);
}

test "canonical object style scenario files parse task weights" {
    var scenario = try scheduler.loadScenarioFile(std.testing.allocator, "scenarios/basic/weighted-fairness.zon");
    defer scenario.deinit();

    try std.testing.expectEqualStrings("weighted-fairness", scenario.name);
    try std.testing.expectEqual(@as(usize, 3), scenario.tasks.len);
    try expectTaskWithWeight(scenario.tasks[0], "light", 0, 4, 512, 0);
    try expectTaskWithWeight(scenario.tasks[1], "heavy", 0, 4, 2048, 1);
    try expectTaskWithWeight(scenario.tasks[2], "default", 0, 2, scheduler.default_task_weight, 2);
}

test "canonical object style scenario files parse deterministic sleep and wake configuration" {
    var scenario = try scheduler.loadScenarioFile(std.testing.allocator, "scenarios/basic/sleep-wakeup.zon");
    defer scenario.deinit();

    try std.testing.expectEqualStrings("sleep-wakeup", scenario.name);
    try std.testing.expectEqual(@as(usize, 2), scenario.tasks.len);
    try expectTaskWithSleep(scenario.tasks[0], "A", 0, 4, scheduler.default_task_weight, 2, 2, 0);
    try expectTaskWithSleep(scenario.tasks[1], "B", 1, 2, scheduler.default_task_weight, null, 0, 1);
}

test "canonical object style scenario files parse multi-phase workloads" {
    var scenario = try scheduler.loadScenarioFile(std.testing.allocator, "scenarios/basic/multi-phase-io.zon");
    defer scenario.deinit();

    try std.testing.expectEqualStrings("multi-phase-io", scenario.name);
    try std.testing.expectEqual(@as(usize, 2), scenario.tasks.len);
    try std.testing.expectEqual(@as(u32, 5), scenario.tasks[0].burst_ticks);
    try std.testing.expectEqual(@as(u32, 5), scenario.tasks[0].phaseCount());
    try std.testing.expectEqual(@as(?u32, null), scenario.tasks[0].sleep_after_ticks);
    try std.testing.expect(scenario.tasks[0].phases != null);
    try std.testing.expectEqual(scheduler.TaskPhaseKind.cpu, scenario.tasks[0].phases.?[0].kind);
    try std.testing.expectEqual(scheduler.TaskPhaseKind.wait, scenario.tasks[0].phases.?[1].kind);
}

test "canonical object style scenario files parse task deadlines" {
    var scenario = try scheduler.loadScenarioFile(std.testing.allocator, "scenarios/basic/deadline-priority.zon");
    defer scenario.deinit();

    try std.testing.expectEqualStrings("deadline-priority", scenario.name);
    try std.testing.expectEqual(@as(?u32, 12), scenario.tasks[0].deadline_tick);
    try std.testing.expectEqual(@as(?u32, 3), scenario.tasks[1].deadline_tick);
}

test "canonical object style scenario files parse group membership and group weights" {
    var scenario = try scheduler.loadScenarioFile(std.testing.allocator, "scenarios/basic/group-fairness.zon");
    defer scenario.deinit();

    try std.testing.expectEqualStrings("group-fairness", scenario.name);
    try std.testing.expectEqual(@as(usize, 2), scenario.groups.len);
    try std.testing.expectEqualStrings("interactive", scenario.groups[0].id);
    try std.testing.expectEqual(@as(u32, 2048), scenario.groups[0].weight);
    try std.testing.expectEqual(@as(u32, 1), scenario.groups[0].quota_ticks);
    try std.testing.expectEqualStrings("interactive", scenario.tasks[0].group_id.?);
    try std.testing.expectEqualStrings("batch", scenario.tasks[2].group_id.?);
}

test "canonical object style scenario files parse topology domains" {
    var scenario = try scheduler.loadScenarioFile(std.testing.allocator, "scenarios/basic/topology-domains.zon");
    defer scenario.deinit();

    try std.testing.expectEqualStrings("topology-domains", scenario.name);
    try std.testing.expectEqual(@as(u32, 4), scenario.core_count);
    try std.testing.expectEqual(@as(usize, 2), scenario.domains.len);
    try std.testing.expectEqualStrings("node0", scenario.domains[0].id);
    try std.testing.expectEqual(@as(scheduler.CoreId, 0), scenario.domains[0].cores[0]);
    try std.testing.expectEqual(@as(scheduler.CoreId, 3), scenario.domains[1].cores[1]);
}

test "topology domains must cover each core exactly once" {
    const source =
        \\.{
        \\    .name = "bad-topology",
        \\    .core_count = 4,
        \\    .topology_domains = .{
        \\        .{ .id = "node0", .cores = .{ 0, 1 } },
        \\        .{ .id = "node1", .cores = .{ 1, 2 } },
        \\    },
        \\    .tasks = .{ .{ .id = "A", .arrival_tick = 0, .burst_ticks = 2 } },
        \\}
    ;
    try std.testing.expectError(error.DuplicateDomainCore, scheduler.parseScenarioText(std.testing.allocator, source, "bad-topology"));
}

test "group references must resolve to declared groups" {
    const source =
        \\.{
        \\    .name = "unknown-group",
        \\    .groups = .{ .{ .id = "interactive" } },
        \\    .tasks = .{ .{ .id = "A", .arrival_tick = 0, .burst_ticks = 2, .group_id = "missing" } },
        \\}
    ;
    try std.testing.expectError(
        error.UnknownGroup,
        scheduler.parseScenarioText(std.testing.allocator, source, "unknown-group"),
    );
}

test "sleep configuration requires positive duration and a valid post-dispatch point" {
    const missing_duration =
        \\.{
        \\    .name = "missing-sleep-duration",
        \\    .tasks = .{
        \\        .{ .id = "A", .arrival_tick = 0, .burst_ticks = 4, .sleep_after_ticks = 2 },
        \\    },
        \\}
    ;
    try std.testing.expectError(
        error.InvalidSleepDuration,
        scheduler.parseScenarioText(std.testing.allocator, missing_duration, "missing-sleep-duration"),
    );

    const invalid_after =
        \\.{
        \\    .name = "invalid-sleep-after",
        \\    .tasks = .{
        \\        .{ .id = "A", .arrival_tick = 0, .burst_ticks = 4, .sleep_after_ticks = 4, .sleep_duration = 1 },
        \\    },
        \\}
    ;
    try std.testing.expectError(
        error.InvalidSleepAfterTicks,
        scheduler.parseScenarioText(std.testing.allocator, invalid_after, "invalid-sleep-after"),
    );
}

test "M6 docs keep blocked-state semantics educational and simulator-scoped" {
    const allocator = std.testing.allocator;
    const readme = try std.fs.cwd().readFileAlloc(allocator, "README.md", std.math.maxInt(usize));
    defer allocator.free(readme);
    const phase_doc = try std.fs.cwd().readFileAlloc(allocator, "docs/phase1-simulator.md", std.math.maxInt(usize));
    defer allocator.free(phase_doc);
    const linux_doc = try std.fs.cwd().readFileAlloc(allocator, "docs/linux-mapping.md", std.math.maxInt(usize));
    defer allocator.free(linux_doc);

    try std.testing.expect(std.mem.indexOf(u8, readme, "sleep_after_ticks") != null);
    try std.testing.expect(std.mem.indexOf(u8, readme, "phases") != null);
    try std.testing.expect(std.mem.indexOf(u8, readme, "deadline-priority") != null);
    try std.testing.expect(std.mem.indexOf(u8, readme, "group-fairness") != null);
    try std.testing.expect(std.mem.indexOf(u8, readme, "topology-domains") != null);
    try std.testing.expect(std.mem.indexOf(u8, readme, "scenarios/basic/sleep-wakeup.zon") != null);
    try std.testing.expect(std.mem.indexOf(u8, readme, "scenarios/basic/multi-phase-io.zon") != null);
    try std.testing.expect(std.mem.indexOf(u8, phase_doc, "Deterministic blocked / wakeup model") != null);
    try std.testing.expect(std.mem.indexOf(u8, phase_doc, "not attempt to reproduce Linux wakeup races") != null);
    try std.testing.expect(std.mem.indexOf(u8, phase_doc, "group-level scheduling ideas") != null);
    try std.testing.expect(std.mem.indexOf(u8, phase_doc, "Topolog") != null);
    try std.testing.expect(std.mem.indexOf(u8, linux_doc, "No wait queues, interrupts, I/O completion, or Linux wakeup fidelity") != null);
}

test "legacy line oriented scenario text remains supported" {
    const source =
        \\name: legacy-demo
        \\rr_quantum: 3
        \\task: A 0 2
        \\task: B 1 1
        \\
    ;

    var scenario = try scheduler.parseScenarioText(std.testing.allocator, source, "legacy-demo");
    defer scenario.deinit();

    try std.testing.expectEqualStrings("legacy-demo", scenario.name);
    try std.testing.expectEqual(@as(u32, 3), scenario.round_robin_quantum);
    try std.testing.expectEqual(@as(usize, 2), scenario.tasks.len);
    try expectTask(scenario.tasks[0], "A", 0, 2, 0);
    try expectTask(scenario.tasks[1], "B", 1, 1, 1);
}

test "legacy line oriented task weights remain supported as an optional compatibility field" {
    const source =
        \\name: weighted-legacy-demo
        \\rr_quantum: 3
        \\task: A 0 2 2048
        \\task: B 1 1
        \\
    ;

    var scenario = try scheduler.parseScenarioText(std.testing.allocator, source, "weighted-legacy-demo");
    defer scenario.deinit();

    try expectTaskWithWeight(scenario.tasks[0], "A", 0, 2, 2048, 0);
    try expectTaskWithWeight(scenario.tasks[1], "B", 1, 1, scheduler.default_task_weight, 1);
}

test "zero task weight is rejected" {
    const source =
        \\.{
        \\    .name = "invalid-weight",
        \\    .tasks = .{
        \\        .{ .id = "A", .arrival_tick = 0, .burst_ticks = 2, .weight = 0 },
        \\    },
        \\}
    ;

    try std.testing.expectError(
        error.InvalidWeight,
        scheduler.parseScenarioText(std.testing.allocator, source, "invalid-weight"),
    );
}

test "task weights above the supported range are rejected" {
    const source =
        \\.{
        \\    .name = "too-heavy",
        \\    .tasks = .{
        \\        .{ .id = "A", .arrival_tick = 0, .burst_ticks = 2, .weight = 4097 },
        \\    },
        \\}
    ;

    try std.testing.expectError(
        error.InvalidWeight,
        scheduler.parseScenarioText(std.testing.allocator, source, "too-heavy"),
    );
}

test "duplicate task ids are rejected" {
    const source =
        \\name: duplicate-task-ids
        \\rr_quantum: 1
        \\task: A 0 2
        \\task: A 1 1
        \\
    ;

    try std.testing.expectError(
        error.DuplicateTaskId,
        scheduler.parseScenarioText(std.testing.allocator, source, "duplicate-task-ids"),
    );
}

test "generated scenario helper emits valid scenarios across deterministic seeds" {
    const allocator = std.testing.allocator;

    for (0..8) |seed| {
        const source = try buildGeneratedScenarioSource(allocator, @intCast(seed));
        defer allocator.free(source);

        const expected_name = try std.fmt.allocPrint(allocator, "generated-m13-{d}", .{seed});
        defer allocator.free(expected_name);

        var scenario = try scheduler.parseScenarioText(allocator, source, expected_name);
        defer scenario.deinit();

        try scenario.validate();
        try std.testing.expectEqualStrings(expected_name, scenario.name);
        try std.testing.expect(scenario.tasks.len >= 3);
        try std.testing.expect(scenario.round_robin_quantum >= 1);

        if (scenario.core_count > 1) {
            try std.testing.expectEqual(@as(usize, @intCast(scenario.core_count)), scenario.domains.len);
        }

        for (scenario.tasks) |task| {
            try std.testing.expect(task.deadline_tick != null);
            if (task.group_id) |group_id| {
                try std.testing.expect(scenario.groupById(group_id) != null);
            }
            if (task.phases) |phases| {
                try std.testing.expect(phases.len >= 3);
                try std.testing.expectEqual(scheduler.TaskPhaseKind.cpu, phases[0].kind);
                try std.testing.expectEqual(scheduler.TaskPhaseKind.cpu, phases[phases.len - 1].kind);
            }
        }
    }
}

fn buildGeneratedScenarioSource(allocator: std.mem.Allocator, seed: u32) ![]u8 {
    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(allocator);

    const name = try std.fmt.allocPrint(allocator, "generated-m13-{d}", .{seed});
    defer allocator.free(name);

    const core_count: u32 = if (seed % 2 == 0) 1 else 2;
    const use_groups = seed % 3 != 1;

    try buffer.appendSlice(allocator, ".{\n");
    var writer = buffer.writer(allocator);
    try writer.print("    .name = \"{s}\",\n", .{name});
    try writer.print("    .rr_quantum = {d},\n", .{1 + (seed % 3)});
    if (core_count > 1) {
        try writer.print("    .core_count = {d},\n", .{core_count});
        try buffer.appendSlice(allocator, "    .topology_domains = .{\n");
        for (0..core_count) |core_id| {
            try writer.print("        .{{ .id = \"node{d}\", .cores = .{{ {d} }} }},\n", .{ core_id, core_id });
        }
        try buffer.appendSlice(allocator, "    },\n");
    }
    if (use_groups) {
        try buffer.appendSlice(allocator, "    .groups = .{\n");
        try buffer.appendSlice(allocator, "        .{ .id = \"interactive\", .weight = 2048, .quota_ticks = 1 },\n");
        try buffer.appendSlice(allocator, "        .{ .id = \"batch\", .weight = 1024 },\n");
        try buffer.appendSlice(allocator, "    },\n");
    }
    try buffer.appendSlice(allocator, "    .tasks = .{\n");
    const task_count: u32 = 3 + (seed % 3);
    for (0..task_count) |task_index| {
        const arrival_tick: u32 = @intCast((seed + task_index * 2) % 5);
        const burst_ticks: u32 = 2 + @as(u32, @intCast((seed * 5 + task_index * 7) % 4));
        const weight: u32 = switch ((seed + @as(u32, @intCast(task_index))) % 3) {
            0 => 512,
            1 => scheduler.default_task_weight,
            else => 2048,
        };
        const deadline_tick = arrival_tick + burst_ticks + 2 + @as(u32, @intCast((seed + task_index) % 3));
        const use_phases = ((seed + @as(u32, @intCast(task_index))) % 2) == 0;

        try writer.print("        .{{ .id = \"T{d}\", .arrival_tick = {d}, ", .{ task_index, arrival_tick });
        if (use_phases) {
            try writer.print(
                ".burst_ticks = {d}, .phases = .{{ .{{ .kind = .cpu, .ticks = 1 }}, .{{ .kind = .wait, .ticks = 1 }}, .{{ .kind = .cpu, .ticks = {d} }} }}, ",
                .{ burst_ticks, burst_ticks - 1 },
            );
        } else {
            try writer.print(".burst_ticks = {d}, ", .{burst_ticks});
        }
        try writer.print(".weight = {d}, ", .{weight});
        if (use_groups) {
            const group_id = if (task_index % 2 == 0) "interactive" else "batch";
            try writer.print(".group_id = \"{s}\", ", .{group_id});
        }
        try writer.print(".deadline_tick = {d} }},\n", .{deadline_tick});
    }
    try buffer.appendSlice(allocator, "    },\n");
    try buffer.appendSlice(allocator, "}\n");

    return try buffer.toOwnedSlice(allocator);
}

fn expectTask(
    task: scheduler.TaskSpec,
    expected_id: []const u8,
    expected_arrival: u32,
    expected_burst: u32,
    expected_order: u32,
) !void {
    try expectTaskWithWeight(task, expected_id, expected_arrival, expected_burst, scheduler.default_task_weight, expected_order);
}

fn expectTaskWithSleep(
    task: scheduler.TaskSpec,
    expected_id: []const u8,
    expected_arrival: u32,
    expected_burst: u32,
    expected_weight: u32,
    expected_sleep_after_ticks: ?u32,
    expected_sleep_duration: u32,
    expected_order: u32,
) !void {
    try expectTaskWithWeight(task, expected_id, expected_arrival, expected_burst, expected_weight, expected_order);
    try std.testing.expectEqual(expected_sleep_after_ticks, task.sleep_after_ticks);
    try std.testing.expectEqual(expected_sleep_duration, task.sleep_duration);
}

fn expectTaskWithWeight(
    task: scheduler.TaskSpec,
    expected_id: []const u8,
    expected_arrival: u32,
    expected_burst: u32,
    expected_weight: u32,
    expected_order: u32,
) !void {
    try std.testing.expectEqualStrings(expected_id, task.id);
    try std.testing.expectEqual(expected_arrival, task.arrival_tick);
    try std.testing.expectEqual(expected_burst, task.burst_ticks);
    try std.testing.expectEqual(expected_weight, task.weight);
    try std.testing.expectEqual(expected_order, task.input_order);
}
