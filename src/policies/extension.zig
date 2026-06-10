const std = @import("std");
const types = @import("../sim/types.zig");

pub const PolicyDescriptor = struct {
    kind: types.PolicyKind,
    key: []const u8,
    display_name: []const u8,
    module_path: []const u8,
    description: []const u8,
};

pub const PolicyInterfaceKind = enum {
    queue,
    chooser,
};

pub const PolicyObjective = enum {
    convoy_baseline,
    time_slice_latency,
    weighted_fairness,
    deadline_order,
};

pub const PolicyModel = struct {
    kind: types.PolicyKind,
    objective: PolicyObjective,
    decision_signal: []const u8,
    fairness_signal: []const u8,
    latency_signal: []const u8,
    deterministic_tie_break: []const u8,
    explanation: []const u8,
};

pub const PolicyContract = struct {
    kind: types.PolicyKind,
    interface_kind: PolicyInterfaceKind,
    descriptor_owner: []const u8,
    state_owner: []const u8,
    implementation_owner: []const u8,
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

const builtin_policy_contracts = [_]PolicyContract{
    .{
        .kind = .fcfs,
        .interface_kind = .queue,
        .descriptor_owner = "src/policies/extension.zig",
        .state_owner = "src/sim/types.zig",
        .implementation_owner = "src/policies/fcfs.zig",
    },
    .{
        .kind = .round_robin,
        .interface_kind = .queue,
        .descriptor_owner = "src/policies/extension.zig",
        .state_owner = "src/sim/types.zig",
        .implementation_owner = "src/policies/round_robin.zig",
    },
    .{
        .kind = .cfs_like,
        .interface_kind = .chooser,
        .descriptor_owner = "src/policies/extension.zig",
        .state_owner = "src/sim/types.zig",
        .implementation_owner = "src/policies/cfs_like.zig",
    },
    .{
        .kind = .deadline,
        .interface_kind = .chooser,
        .descriptor_owner = "src/policies/extension.zig",
        .state_owner = "src/sim/types.zig",
        .implementation_owner = "src/policies/deadline.zig",
    },
};

const builtin_policy_models = [_]PolicyModel{
    .{
        .kind = .fcfs,
        .objective = .convoy_baseline,
        .decision_signal = "oldest-ready-task",
        .fairness_signal = "declaration-order waiting exposure",
        .latency_signal = "convoy and response-time baseline",
        .deterministic_tie_break = "ready-queue order then scenario declaration order",
        .explanation = "FCFS is the deterministic baseline for showing how arrival order can dominate latency.",
    },
    .{
        .kind = .round_robin,
        .objective = .time_slice_latency,
        .decision_signal = "ready-queue rotation after quantum pressure",
        .fairness_signal = "bounded turn rotation among runnable peers",
        .latency_signal = "shorter first-response opportunities under runnable contention",
        .deterministic_tie_break = "ready-queue order after explicit rotation",
        .explanation = "Round Robin models time-sliced latency pressure without claiming any host scheduler behavior.",
    },
    .{
        .kind = .cfs_like,
        .objective = .weighted_fairness,
        .decision_signal = "lowest virtual runtime",
        .fairness_signal = "weight-normalized virtual runtime",
        .latency_signal = "preemption when a runnable peer has lower virtual runtime",
        .deterministic_tie_break = "scenario declaration order for equal virtual runtime",
        .explanation = "CFS-inspired selection makes fairness pressure explainable through deterministic virtual-runtime accounting.",
    },
    .{
        .kind = .deadline,
        .objective = .deadline_order,
        .decision_signal = "earliest declared deadline",
        .fairness_signal = "deadline priority can intentionally dominate equal-share fairness",
        .latency_signal = "preemption when an earlier deadline becomes runnable",
        .deterministic_tie_break = "scenario declaration order for equal deadline",
        .explanation = "Deadline-inspired selection explains deadline pressure without admission-control or real-time guarantees.",
    },
};

pub fn listPolicyDescriptors() []const PolicyDescriptor {
    return builtin_policy_descriptors[0..];
}

pub fn listPolicyContracts() []const PolicyContract {
    return builtin_policy_contracts[0..];
}

pub fn listPolicyModels() []const PolicyModel {
    return builtin_policy_models[0..];
}

pub fn describePolicy(kind: types.PolicyKind) PolicyDescriptor {
    for (builtin_policy_descriptors) |descriptor| {
        if (descriptor.kind == kind) return descriptor;
    }
    unreachable;
}

pub fn describePolicyContract(kind: types.PolicyKind) PolicyContract {
    for (builtin_policy_contracts) |contract| {
        if (contract.kind == kind) return contract;
    }
    unreachable;
}

pub fn describePolicyModel(kind: types.PolicyKind) PolicyModel {
    for (builtin_policy_models) |model| {
        if (model.kind == kind) return model;
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
