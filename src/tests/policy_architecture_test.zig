const std = @import("std");
const sim = @import("../root.zig");

const MockRuntimeTask = struct {
    state: sim.TaskState,
    vruntime: u64,
    input_order: u32,
    weight: u32,
    deadline_tick: ?u32 = null,
    group_index: ?usize = null,
};

test "scheduler class selects and updates policy behavior through one boundary" {
    const Class = sim.policies.class.SchedulerClass(MockRuntimeTask);

    var ready_queue: std.ArrayList(usize) = .empty;
    defer ready_queue.deinit(std.testing.allocator);
    try ready_queue.append(std.testing.allocator, 1);
    try ready_queue.append(std.testing.allocator, 2);

    const runtimes = [_]MockRuntimeTask{
        .{ .state = .running, .vruntime = 4, .input_order = 0, .weight = sim.default_task_weight, .deadline_tick = 9, .group_index = 0 },
        .{ .state = .ready, .vruntime = 2, .input_order = 1, .weight = sim.default_task_weight, .deadline_tick = 5, .group_index = 1 },
        .{ .state = .ready, .vruntime = 1, .input_order = 2, .weight = sim.default_task_weight * 2, .deadline_tick = 3, .group_index = 1 },
    };

    const fcfs = Class.resolve(.fcfs);
    try std.testing.expect(fcfs.useSingleCoreReadyQueue());
    try std.testing.expectEqual(@as(?usize, 1), fcfs.selectNextSingle(&ready_queue, runtimes[0..]));

    try ready_queue.append(std.testing.allocator, 1);
    try ready_queue.append(std.testing.allocator, 2);
    const rr = Class.resolve(.round_robin);
    try std.testing.expect(rr.useSingleCoreReadyQueue());
    try std.testing.expect(rr.shouldPreemptSingle(0, 2, 2, ready_queue.items.len, runtimes[0..]));
    try std.testing.expectEqual(@as(?usize, 2), rr.selectNextSingle(&ready_queue, runtimes[0..]));

    const cfs = Class.resolve(.cfs_like);
    try std.testing.expect(!cfs.useSingleCoreReadyQueue());
    try std.testing.expectEqual(@as(?usize, 2), cfs.selectNextSingle(&ready_queue, runtimes[0..]));

    const deadline = Class.resolve(.deadline);
    try std.testing.expect(!deadline.useSingleCoreReadyQueue());
    try std.testing.expectEqual(@as(?usize, 2), deadline.selectNextSingle(&ready_queue, runtimes[0..]));

    var task = MockRuntimeTask{ .state = .running, .vruntime = 0, .input_order = 0, .weight = sim.default_task_weight, .deadline_tick = 10, .group_index = 0 };
    cfs.onTaskTick(&task);
    try std.testing.expect(task.vruntime != 0);
    const unchanged = task.vruntime;
    fcfs.onTaskTick(&task);
    try std.testing.expectEqual(unchanged, task.vruntime);
}

test "engine depends on scheduling class boundary instead of direct policy imports" {
    const allocator = std.testing.allocator;
    const engine_source = try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), "src/sim/engine.zig", allocator, .unlimited);
    defer allocator.free(engine_source);
    const class_source = try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), "src/policies/class.zig", allocator, .unlimited);
    defer allocator.free(class_source);

    try std.testing.expect(std.mem.indexOf(u8, engine_source, "@import(\"../policies/class.zig\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, engine_source, "@import(\"../policies/fcfs.zig\")") == null);
    try std.testing.expect(std.mem.indexOf(u8, engine_source, "@import(\"../policies/round_robin.zig\")") == null);
    try std.testing.expect(std.mem.indexOf(u8, engine_source, "@import(\"../policies/cfs_like.zig\")") == null);

    try std.testing.expect(std.mem.indexOf(u8, class_source, "@import(\"fcfs.zig\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, class_source, "@import(\"round_robin.zig\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, class_source, "@import(\"cfs_like.zig\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, engine_source, "@import(\"../policies/experimental/lottery.zig\")") == null);
}

test "downstream tools consume report contracts instead of engine internals" {
    const allocator = std.testing.allocator;
    const files = [_][]const u8{
        "src/analysis/root.zig",
        "src/analysis/model.zig",
        "src/bench/root.zig",
        "src/report_pipeline/root.zig",
        "src/tui/root.zig",
    };

    for (files) |path| {
        const source = try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .unlimited);
        defer allocator.free(source);
        try std.testing.expect(std.mem.indexOf(u8, source, "sim/engine.zig") == null);
        try std.testing.expect(std.mem.indexOf(u8, source, "sim/types.zig") == null);
    }

    const analysis_model = try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), "src/analysis/model.zig", allocator, .unlimited);
    defer allocator.free(analysis_model);
    try std.testing.expect(std.mem.indexOf(u8, analysis_model, "@import(\"report_contract\")") != null);
}
