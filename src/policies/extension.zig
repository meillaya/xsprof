const std = @import("std");
const types = @import("../sim/types.zig");

pub const PolicyDescriptor = struct {
    kind: types.PolicyKind,
    key: []const u8,
    display_name: []const u8,
    module_path: []const u8,
    description: []const u8,
};

const builtin_policy_descriptors = [_]PolicyDescriptor{
    .{
        .kind = .fcfs,
        .key = "fcfs",
        .display_name = "FCFS",
        .module_path = "src/policies/fcfs.zig",
        .description = "Queue-ordered FIFO baseline policy",
    },
    .{
        .kind = .round_robin,
        .key = "round-robin",
        .display_name = "Round Robin",
        .module_path = "src/policies/round_robin.zig",
        .description = "Quantum-based ready-queue rotation policy",
    },
    .{
        .kind = .cfs_like,
        .key = "cfs-like",
        .display_name = "CFS-inspired",
        .module_path = "src/policies/cfs_like.zig",
        .description = "Deterministic fairness-oriented chooser with vruntime accounting",
    },
    .{
        .kind = .deadline,
        .key = "deadline",
        .display_name = "Deadline-inspired",
        .module_path = "src/policies/deadline.zig",
        .description = "Deterministic earliest-deadline-first teaching policy",
    },
};

pub fn listPolicyDescriptors() []const PolicyDescriptor {
    return builtin_policy_descriptors[0..];
}

pub fn describePolicy(kind: types.PolicyKind) PolicyDescriptor {
    for (builtin_policy_descriptors) |descriptor| {
        if (descriptor.kind == kind) return descriptor;
    }
    unreachable;
}

pub fn validateModuleContract(comptime Module: type) void {
    if (!@hasDecl(Module, "selectNext") and !@hasDecl(Module, "chooseRunnable")) {
        @compileError("policy modules must declare selectNext(...) or chooseRunnable(...)");
    }
}

pub fn usesSingleCoreReadyQueue(comptime Module: type) bool {
    validateModuleContract(Module);
    return @hasDecl(Module, "selectNext");
}

pub fn keepsRunningSelection(comptime Module: type) bool {
    validateModuleContract(Module);
    if (@hasDecl(Module, "keeps_running_selection")) return @field(Module, "keeps_running_selection");
    return @hasDecl(Module, "chooseRunnable");
}

pub fn selectNextSingle(
    comptime RuntimeTask: type,
    comptime Module: type,
    ready_queue: *std.ArrayList(usize),
    runtimes: []const RuntimeTask,
) ?usize {
    validateModuleContract(Module);
    if (@hasDecl(Module, "selectNextSingle")) return Module.selectNextSingle(ready_queue, runtimes);
    if (@hasDecl(Module, "selectNext")) return Module.selectNext(ready_queue);
    return Module.chooseRunnable(RuntimeTask, runtimes);
}

pub fn shouldPreemptSingle(
    comptime RuntimeTask: type,
    comptime Module: type,
    current: ?usize,
    current_quantum: u32,
    quantum: u32,
    ready_len: usize,
    runtimes: []const RuntimeTask,
) bool {
    const current_index = current orelse return false;
    validateModuleContract(Module);

    if (@hasDecl(Module, "shouldPreemptSingle")) {
        return Module.shouldPreemptSingle(current, current_quantum, quantum, ready_len, runtimes);
    }
    if (@hasDecl(Module, "shouldPreempt")) {
        return Module.shouldPreempt(current_quantum, quantum, ready_len);
    }
    if (@hasDecl(Module, "chooseRunnable")) {
        const best_index = Module.chooseRunnable(RuntimeTask, runtimes) orelse return false;
        return best_index != current_index;
    }
    return false;
}

pub fn onTaskTick(comptime Module: type, task: anytype) void {
    validateModuleContract(Module);
    if (@hasDecl(Module, "onTaskTick")) Module.onTaskTick(task);
}
