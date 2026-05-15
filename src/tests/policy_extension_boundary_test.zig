const std = @import("std");
const sim = @import("../root.zig");

const MockRuntimeTask = struct {
    state: sim.TaskState,
    vruntime: u64,
    input_order: u32,
    weight: u32,
    effective_weight: u32,
    deadline_tick: ?u32 = null,
};

const QueueOnlyPolicy = struct {
    pub fn selectNext(ready_queue: *std.ArrayList(usize)) ?usize {
        if (ready_queue.items.len == 0) return null;
        return ready_queue.orderedRemove(ready_queue.items.len - 1);
    }
};

const ChoosingPolicy = struct {
    pub const keeps_running_selection = true;

    pub fn chooseRunnable(comptime RuntimeTask: type, tasks: []const RuntimeTask) ?usize {
        var best_index: ?usize = null;
        var best_weight: u32 = 0;
        for (tasks, 0..) |task, index| {
            if (task.state != .ready and task.state != .running) continue;
            if (best_index == null or task.effective_weight > best_weight) {
                best_index = index;
                best_weight = task.effective_weight;
            }
        }
        return best_index;
    }

    pub fn onTaskTick(task: anytype) void {
        task.vruntime += 7;
    }
};

test "M14 built-in policy descriptors remain explicit and complete" {
    const descriptors = sim.policies.extension.listPolicyDescriptors();
    try std.testing.expectEqual(@as(usize, 4), descriptors.len);
    try std.testing.expectEqual(sim.PolicyKind.fcfs, descriptors[0].kind);
    try std.testing.expectEqualStrings("src/policies/fcfs.zig", descriptors[0].module_path);
    try std.testing.expectEqual(sim.PolicyKind.deadline, descriptors[3].kind);
    try std.testing.expectEqualStrings("Deadline-inspired", descriptors[3].display_name);

    const engine_source = try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), "src/sim/engine.zig", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(engine_source);
    const class_source = try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), "src/policies/class.zig", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(class_source);

    try std.testing.expect(std.mem.indexOf(u8, engine_source, "@import(\"../policies/fcfs.zig\")") == null);
    try std.testing.expect(std.mem.indexOf(u8, class_source, "@import(\"extension.zig\")") != null);
}

test "M24 experimental policies stay outside the built-in stable descriptor set" {
    const stable_descriptors = sim.policies.extension.listPolicyDescriptors();
    const experimental_descriptors = sim.policies.experimental.listExperimentalPolicyDescriptors();

    try std.testing.expectEqual(@as(usize, 4), stable_descriptors.len);
    try std.testing.expectEqual(@as(usize, 1), experimental_descriptors.len);
    try std.testing.expectEqualStrings("lottery", experimental_descriptors[0].key);
    try std.testing.expectEqualStrings("experimental-only", experimental_descriptors[0].unstable_label);
    try std.testing.expect(std.mem.indexOf(u8, experimental_descriptors[0].promotion_rule, "promotion") != null);

    for (stable_descriptors) |descriptor| {
        try std.testing.expect(!std.mem.eql(u8, descriptor.key, experimental_descriptors[0].key));
    }
}

test "M14 built-in policy modules satisfy the documented extension contract" {
    comptime sim.policies.extension.validateModuleContract(sim.policies.fcfs);
    comptime sim.policies.extension.validateModuleContract(sim.policies.round_robin);
    comptime sim.policies.extension.validateModuleContract(sim.policies.cfs_like);
    comptime sim.policies.extension.validateModuleContract(sim.policies.deadline);

    try std.testing.expect(sim.policies.extension.usesSingleCoreReadyQueue(sim.policies.fcfs));
    try std.testing.expect(!sim.policies.extension.usesSingleCoreReadyQueue(sim.policies.cfs_like));
    try std.testing.expect(sim.policies.extension.keepsRunningSelection(sim.policies.deadline));
}

test "M34 policy boundary separates interface state and implementation ownership" {
    const contracts = sim.policies.extension.listPolicyContracts();
    try std.testing.expectEqual(@as(usize, 4), contracts.len);

    for (contracts) |contract| {
        const descriptor = sim.policies.extension.describePolicy(contract.kind);
        try std.testing.expectEqual(contract.kind, descriptor.kind);
        try std.testing.expectEqualStrings("src/policies/extension.zig", contract.descriptor_owner);
        try std.testing.expectEqualStrings("src/sim/types.zig", contract.state_owner);
        try std.testing.expect(std.mem.startsWith(u8, contract.implementation_owner, "src/policies/"));
        try std.testing.expect(std.mem.endsWith(u8, contract.implementation_owner, ".zig"));
    }

    try std.testing.expectEqual(sim.policies.extension.PolicyInterfaceKind.queue, sim.policies.extension.describePolicyContract(.fcfs).interface_kind);
    try std.testing.expectEqual(sim.policies.extension.PolicyInterfaceKind.queue, sim.policies.extension.describePolicyContract(.round_robin).interface_kind);
    try std.testing.expectEqual(sim.policies.extension.PolicyInterfaceKind.chooser, sim.policies.extension.describePolicyContract(.cfs_like).interface_kind);
    try std.testing.expectEqual(sim.policies.extension.PolicyInterfaceKind.chooser, sim.policies.extension.describePolicyContract(.deadline).interface_kind);
}

test "M24 experimental policy satisfies the extension contract but remains unstable" {
    comptime sim.policies.extension.validateModuleContract(sim.policies.experimental.lottery_policy);
    try std.testing.expect(!sim.policies.extension.usesSingleCoreReadyQueue(sim.policies.experimental.lottery_policy));
    try std.testing.expect(sim.policies.experimental.lottery_policy.unstable);
}

test "M14 extension adapter supplies queue defaults without extra engine hooks" {
    var ready_queue: std.ArrayList(usize) = .empty;
    defer ready_queue.deinit(std.testing.allocator);
    try ready_queue.append(std.testing.allocator, 1);
    try ready_queue.append(std.testing.allocator, 2);

    const runtimes = [_]MockRuntimeTask{
        .{ .state = .running, .vruntime = 0, .input_order = 0, .weight = 1024, .effective_weight = 1024 },
        .{ .state = .ready, .vruntime = 3, .input_order = 1, .weight = 1024, .effective_weight = 1024 },
        .{ .state = .ready, .vruntime = 1, .input_order = 2, .weight = 1024, .effective_weight = 1024 },
    };

    try std.testing.expect(sim.policies.extension.usesSingleCoreReadyQueue(QueueOnlyPolicy));
    try std.testing.expectEqual(
        @as(?usize, 2),
        sim.policies.extension.selectNextSingle(MockRuntimeTask, QueueOnlyPolicy, &ready_queue, runtimes[0..]),
    );
    try std.testing.expect(!sim.policies.extension.shouldPreemptSingle(
        MockRuntimeTask,
        QueueOnlyPolicy,
        0,
        1,
        2,
        ready_queue.items.len,
        runtimes[0..],
    ));
}

test "M14 extension adapter supports chooser-style policies with tick hooks" {
    var ready_queue: std.ArrayList(usize) = .empty;
    defer ready_queue.deinit(std.testing.allocator);

    const runtimes = [_]MockRuntimeTask{
        .{ .state = .running, .vruntime = 2, .input_order = 0, .weight = 1024, .effective_weight = 1024, .deadline_tick = 9 },
        .{ .state = .ready, .vruntime = 1, .input_order = 1, .weight = 1024, .effective_weight = 4096, .deadline_tick = 3 },
    };

    try std.testing.expect(!sim.policies.extension.usesSingleCoreReadyQueue(ChoosingPolicy));
    try std.testing.expect(sim.policies.extension.keepsRunningSelection(ChoosingPolicy));
    try std.testing.expectEqual(
        @as(?usize, 1),
        sim.policies.extension.selectNextSingle(MockRuntimeTask, ChoosingPolicy, &ready_queue, runtimes[0..]),
    );
    try std.testing.expect(sim.policies.extension.shouldPreemptSingle(
        MockRuntimeTask,
        ChoosingPolicy,
        0,
        0,
        2,
        1,
        runtimes[0..],
    ));

    var task = MockRuntimeTask{
        .state = .running,
        .vruntime = 0,
        .input_order = 0,
        .weight = 1024,
        .effective_weight = 2048,
    };
    sim.policies.extension.onTaskTick(ChoosingPolicy, &task);
    try std.testing.expectEqual(@as(u64, 7), task.vruntime);
}
