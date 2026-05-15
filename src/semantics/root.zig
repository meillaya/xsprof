const std = @import("std");
const list_writer = @import("list_writer");

pub const contract_name = "zig-scheduler/scheduling-semantics-v2";
pub const contract_version: u32 = 2;

pub const SchedulingClassV2 = enum {
    fcfs,
    round_robin,
    cfs_fair,
    deadline,

    pub fn label(self: SchedulingClassV2) []const u8 {
        return switch (self) {
            .fcfs => "FCFS stable arrival order",
            .round_robin => "Round Robin quantum rotation",
            .cfs_fair => "CFS-inspired weighted fairness",
            .deadline => "Deadline-inspired admissible earliest deadline",
        };
    }
};

pub const RunQueueModel = enum {
    global_single,
    per_core_fifo,
    per_domain_weighted,

    pub fn label(self: RunQueueModel) []const u8 {
        return switch (self) {
            .global_single => "one global ready queue",
            .per_core_fifo => "per-core FIFO queues with deterministic rebalance",
            .per_domain_weighted => "domain-aware weighted queues",
        };
    }
};

pub const SemanticsFeature = struct {
    area: []const u8,
    name: []const u8,
    owner: []const u8,
    evidence: []const u8,
};

pub const features = [_]SemanticsFeature{
    .{ .area = "semantics contract", .name = "scheduling-class contract v2", .owner = "src/semantics/root.zig", .evidence = contract_name },
    .{ .area = "priority mapping", .name = "priority and nice mapping", .owner = "niceToWeight", .evidence = "deterministic nice[-20,19] -> weight table" },
    .{ .area = "fairness model", .name = "fairness v2", .owner = "fairnessScore", .evidence = "weighted vruntime normalization" },
    .{ .area = "deadline admission", .name = "deadline admission", .owner = "admitDeadline", .evidence = "runtime must fit arrival/deadline window" },
    .{ .area = "runqueue model", .name = "multi-queue runqueues", .owner = "RunQueueModel", .evidence = "global/per-core/domain models are named" },
    .{ .area = "affinity model", .name = "affinity and pinning", .owner = "allowsCore", .evidence = "u64 core masks with explicit all-cores helper" },
    .{ .area = "topology model", .name = "topology cost model", .owner = "topologyCost", .evidence = "same-core, same-domain, cross-domain cost tiers" },
    .{ .area = "group budget model", .name = "group quota/burst accounting", .owner = "groupBudgetState", .evidence = "remaining quota and burst debt are explicit" },
    .{ .area = "decision log", .name = "explainable decision log", .owner = "DecisionLog", .evidence = "stable textual decision records" },
    .{ .area = "replay diff", .name = "deterministic replay/diff engine", .owner = "diffDecisions", .evidence = "first mismatch includes index and task/core deltas" },
};

pub const Nice = i8;

const nice_weights = [_]u32{
    88761, 71755, 56483, 46273, 36291,
    29154, 23254, 18705, 14949, 11916,
    9548,  7620,  6100,  4904,  3906,
    3121,  2501,  1991,  1586,  1277,
    1024,  820,   655,   526,   423,
    335,   272,   215,   172,   137,
    110,   87,    70,    56,    45,
    36,    29,    23,    18,    15,
};

pub fn clampNice(nice: Nice) Nice {
    return @max(@as(Nice, -20), @min(@as(Nice, 19), nice));
}

pub fn niceToWeight(nice: Nice) u32 {
    const clamped = clampNice(nice);
    const index: usize = @intCast(@as(i16, clamped) + 20);
    return nice_weights[index];
}

pub fn priorityFromNice(nice: Nice) u8 {
    const clamped = clampNice(nice);
    return @intCast(@as(i16, clamped) + 20);
}

pub const FairnessInput = struct {
    vruntime: u64,
    nice: Nice = 0,
    group_weight: u32 = 1024,
};

pub fn fairnessScore(input: FairnessInput) u64 {
    const task_weight = niceToWeight(input.nice);
    const combined = @max(@as(u64, 1), (@as(u64, task_weight) * @as(u64, input.group_weight)) / 1024);
    return (input.vruntime * 1024) / combined;
}

pub const DeadlineSpec = struct {
    arrival_tick: u32,
    runtime_ticks: u32,
    deadline_tick: u32,
};

pub fn admitDeadline(spec: DeadlineSpec) bool {
    if (spec.runtime_ticks == 0) return false;
    if (spec.deadline_tick < spec.arrival_tick) return false;
    return spec.runtime_ticks <= spec.deadline_tick - spec.arrival_tick;
}

pub fn fullAffinity(core_count: u8) u64 {
    if (core_count == 0) return 0;
    if (core_count >= 64) return std.math.maxInt(u64);
    const shift: u6 = @intCast(core_count);
    return (@as(u64, 1) << shift) - 1;
}

pub fn allowsCore(mask: u64, core_id: u6) bool {
    return (mask & (@as(u64, 1) << core_id)) != 0;
}

pub const TopologyRelation = enum { same_core, same_domain, cross_domain };

pub fn topologyCost(relation: TopologyRelation) u32 {
    return switch (relation) {
        .same_core => 0,
        .same_domain => 10,
        .cross_domain => 100,
    };
}

pub const GroupBudgetInput = struct {
    quota_ticks: u32,
    used_ticks: u32,
    burst_credit: u32 = 0,
};

pub const GroupBudgetState = struct {
    remaining_ticks: u32,
    burst_debt: u32,
    throttled: bool,
};

pub fn groupBudgetState(input: GroupBudgetInput) GroupBudgetState {
    if (input.quota_ticks == 0) return .{ .remaining_ticks = std.math.maxInt(u32), .burst_debt = 0, .throttled = false };
    const allowed = input.quota_ticks + input.burst_credit;
    if (input.used_ticks <= allowed) return .{ .remaining_ticks = allowed - input.used_ticks, .burst_debt = 0, .throttled = false };
    return .{ .remaining_ticks = 0, .burst_debt = input.used_ticks - allowed, .throttled = true };
}

pub const Decision = struct {
    tick: u32,
    class: SchedulingClassV2,
    runqueue: RunQueueModel,
    task_id: []const u8,
    core_id: u32,
    reason: []const u8,
};

pub const DecisionLog = struct {
    allocator: std.mem.Allocator,
    decisions: std.ArrayList(Decision) = .empty,

    pub fn init(allocator: std.mem.Allocator) DecisionLog {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *DecisionLog) void {
        self.decisions.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn append(self: *DecisionLog, decision: Decision) !void {
        try self.decisions.append(self.allocator, decision);
    }

    pub fn render(self: *const DecisionLog, allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        var writer = list_writer.writer(&out, allocator);
        for (self.decisions.items) |decision| {
            try writer.print("t={d} class={s} queue={s} task={s} core={d} reason={s}\n", .{
                decision.tick,
                @tagName(decision.class),
                @tagName(decision.runqueue),
                decision.task_id,
                decision.core_id,
                decision.reason,
            });
        }
        return try out.toOwnedSlice(allocator);
    }
};

pub const DecisionDiff = struct {
    equal: bool,
    index: usize,
    expected_task: ?[]const u8 = null,
    actual_task: ?[]const u8 = null,
    expected_core: ?u32 = null,
    actual_core: ?u32 = null,
};

pub fn diffDecisions(expected: []const Decision, actual: []const Decision) DecisionDiff {
    const limit = @min(expected.len, actual.len);
    for (0..limit) |index| {
        const left = expected[index];
        const right = actual[index];
        if (left.tick != right.tick or left.class != right.class or left.runqueue != right.runqueue or !std.mem.eql(u8, left.task_id, right.task_id) or left.core_id != right.core_id) {
            return .{ .equal = false, .index = index, .expected_task = left.task_id, .actual_task = right.task_id, .expected_core = left.core_id, .actual_core = right.core_id };
        }
    }
    if (expected.len != actual.len) {
        return .{ .equal = false, .index = limit };
    }
    return .{ .equal = true, .index = expected.len };
}

pub fn renderMarkdown(allocator: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var writer = list_writer.writer(&out, allocator);
    try writer.print("# scheduling semantics v{d}\n\n", .{contract_version});
    try writer.print("Contract: `{s}`\n\n", .{contract_name});
    try writer.writeAll("| area | feature | owner | evidence |\n| --- | --- | --- | --- |\n");
    for (features) |feature| {
        try writer.print("| {s} | {s} | `{s}` | {s} |\n", .{ feature.area, feature.name, feature.owner, feature.evidence });
    }
    return try out.toOwnedSlice(allocator);
}

test "nice and fairness semantics are deterministic" {
    try std.testing.expectEqual(@as(u32, 1024), niceToWeight(0));
    try std.testing.expect(niceToWeight(-20) > niceToWeight(0));
    try std.testing.expect(niceToWeight(19) < niceToWeight(0));
    try std.testing.expect(fairnessScore(.{ .vruntime = 10, .nice = -5 }) < fairnessScore(.{ .vruntime = 10, .nice = 5 }));
}

test "deadline affinity topology and group budget semantics are explicit" {
    try std.testing.expect(admitDeadline(.{ .arrival_tick = 2, .runtime_ticks = 3, .deadline_tick = 5 }));
    try std.testing.expect(!admitDeadline(.{ .arrival_tick = 2, .runtime_ticks = 4, .deadline_tick = 5 }));
    const mask = fullAffinity(4);
    try std.testing.expect(allowsCore(mask, 0));
    try std.testing.expect(allowsCore(mask, 3));
    try std.testing.expect(!allowsCore(mask, 4));
    try std.testing.expectEqual(std.math.maxInt(u64), fullAffinity(64));
    try std.testing.expect(topologyCost(.same_core) < topologyCost(.same_domain));
    try std.testing.expect(topologyCost(.same_domain) < topologyCost(.cross_domain));
    const budget = groupBudgetState(.{ .quota_ticks = 10, .used_ticks = 12, .burst_credit = 1 });
    try std.testing.expect(budget.throttled);
    try std.testing.expectEqual(@as(u32, 1), budget.burst_debt);
}

test "decision log replay diff finds first deterministic mismatch" {
    const expected = [_]Decision{
        .{ .tick = 0, .class = .fcfs, .runqueue = .global_single, .task_id = "A", .core_id = 0, .reason = "arrival order" },
        .{ .tick = 1, .class = .fcfs, .runqueue = .global_single, .task_id = "B", .core_id = 0, .reason = "next arrival" },
    };
    const actual = [_]Decision{
        .{ .tick = 0, .class = .fcfs, .runqueue = .global_single, .task_id = "A", .core_id = 0, .reason = "arrival order" },
        .{ .tick = 1, .class = .fcfs, .runqueue = .global_single, .task_id = "C", .core_id = 0, .reason = "replay" },
    };
    const diff = diffDecisions(&expected, &actual);
    try std.testing.expect(!diff.equal);
    try std.testing.expectEqual(@as(usize, 1), diff.index);
    try std.testing.expectEqualStrings("B", diff.expected_task.?);
    try std.testing.expectEqualStrings("C", diff.actual_task.?);
}
