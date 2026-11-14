//! Causal latency attribution: why a task was off-CPU, how long it waited, and
//! which wakeup chain caused the wait.
//!
//! Two entry points share one bounded state machine:
//!
//! * `ChainTracker` is the incremental form used by `metrics.Index`. It keeps a
//!   fixed-depth wakeup path per recently woken task (depth <= `max_chain_depth`,
//!   PID-keyed, bounded map) and aggregates per-root critical chains. A wakeup
//!   edge extends the waker's most recent wakeup path; an edge that revisits a
//!   task in the path is a cycle and is cut, and an edge past the depth bound is
//!   cut too. Both cuts are counted, never silently dropped.
//! * `analyze` is a bounded second pass over an already-materialized
//!   `event.RawEvent` slice. It derives off-CPU causes from the switch-out
//!   `prev_state`, preemption waits (switch-out with `prev_state == RUNNING`,
//!   then switch-in without an intervening wakeup), and critical chains from the
//!   same tracker. Durations use saturating subtraction so out-of-order legacy
//!   rows degrade to zero instead of underflowing.
//!
//! Both forms are deterministic, allocate only in bounded structures, and mark
//! unknown data explicitly (`unknown`/`other` causes, unresolved counters,
//! truncated flags). Nothing is inferred from a missing wakeup as zero.

const std = @import("std");
const event = @import("../core/event.zig");
const json = @import("../core/json.zig");
const sched_state = @import("../core/sched_state.zig");
const session_meta = @import("../core/session_meta.zig");
const metrics_mod = @import("metrics.zig");

const Writer = std.Io.Writer;

pub const max_chain_depth = 8;
pub const max_tracked_tasks = 4096;
pub const max_chain_roots = 256;
pub const max_chain_output = 8;

pub const Chain = metrics_mod.Chain;
pub const CauseStat = metrics_mod.CauseStat;
pub const Histogram = metrics_mod.Histogram;

/// Counters that make every cut or fallback visible in the wire output.
pub const Counters = struct {
    edges: u64 = 0,
    roots: u64 = 0,
    cycles_cut: u64 = 0,
    depth_cut: u64 = 0,
    overflow: u64 = 0,
    too_many_tasks: u64 = 0,
};

pub const Snapshot = struct {
    chains: []const Chain = &.{},
    counters: Counters = .{},
};

pub const ChainTracker = struct {
    allocator: std.mem.Allocator,
    names: std.heap.ArenaAllocator,
    links: std.AutoHashMap(i32, Link),
    roots: std.AutoHashMap(i32, ChainAgg),
    counters: Counters = .{},

    const Link = struct {
        path: [max_chain_depth]i32 = @splat(-1),
        len: u8 = 0,
        wait_start_ns: u64 = 0,
        wait_pending: bool = false,
        comm: []const u8 = "",
    };

    const ChainAgg = struct {
        root_pid: i32 = -1,
        leaf_pid: i32 = -1,
        leaf_comm: []const u8 = "",
        depth: u8 = 0,
        count: u64 = 0,
        total_wait_us: u64 = 0,
        wait: Histogram = .{},
    };

    pub fn init(allocator: std.mem.Allocator) ChainTracker {
        return .{
            .allocator = allocator,
            .names = std.heap.ArenaAllocator.init(allocator),
            .links = std.AutoHashMap(i32, Link).init(allocator),
            .roots = std.AutoHashMap(i32, ChainAgg).init(allocator),
        };
    }

    pub fn deinit(self: *ChainTracker) void {
        self.links.deinit();
        self.roots.deinit();
        self.names.deinit();
    }

    fn intern(self: *ChainTracker, current: []const u8, text: []const u8) ![]const u8 {
        if (text.len == 0) return current;
        if (current.len != 0 and std.mem.eql(u8, current, text)) return current;
        return try self.names.allocator().dupe(u8, text);
    }

    fn containsPid(path: []const i32, pid: i32) bool {
        for (path) |candidate| {
            if (candidate == pid) return true;
        }
        return false;
    }

    /// Record one wakeup edge. `wake_resolves_wait` is true when the woken task
    /// was blocked, so the wakeup starts a wake-to-run wait sample. A redundant
    /// wakeup still extends the chain but cannot create a wait.
    pub fn onWakeup(
        self: *ChainTracker,
        waker: i32,
        woken: i32,
        comm: []const u8,
        ts_ns: u64,
        wake_resolves_wait: bool,
    ) !void {
        self.counters.edges += 1;
        if (woken <= 0) {
            self.counters.overflow += 1;
            return;
        }
        // A task waking itself is a causal cycle by construction.
        if (waker == woken) {
            self.counters.cycles_cut += 1;
            return;
        }
        var path: [max_chain_depth]i32 = @splat(-1);
        var len: u8 = 0;
        if (waker > 0) {
            if (self.links.getPtr(waker)) |link| {
                if (link.len != 0 and link.len <= max_chain_depth) {
                    if (containsPid(link.path[0..link.len], woken)) {
                        self.counters.cycles_cut += 1;
                        return;
                    }
                    @memcpy(path[0..link.len], link.path[0..link.len]);
                    len = link.len;
                }
            }
            if (len == 0) {
                // The waker itself was not woken inside the window: it is the
                // chain root. This is a lower bound (depth 1), not zero.
                self.counters.roots += 1;
                path[0] = waker;
                len = 1;
            }
        } else {
            // Unknown waker (legacy rows): the woken task is the root.
            self.counters.roots += 1;
        }
        if (len >= max_chain_depth) {
            self.counters.depth_cut += 1;
            try self.aggregate(path[0], woken, comm, max_chain_depth);
            return;
        }
        path[len] = woken;
        len += 1;
        try self.aggregate(path[0], woken, comm, len);

        var link: Link = .{
            .path = path,
            .len = len,
            .wait_start_ns = ts_ns,
            .wait_pending = wake_resolves_wait,
        };
        if (self.links.getPtr(woken)) |existing| {
            link.comm = try self.intern(existing.comm, comm);
            existing.* = link;
        } else if (self.links.count() < max_tracked_tasks) {
            link.comm = try self.intern("", comm);
            try self.links.put(woken, link);
        } else {
            // Bounded table: the chain edge is still counted above, but no new
            // causal link can start from this task.
            self.counters.too_many_tasks += 1;
        }
    }

    /// Record that `pid` ran. Resolves a pending wake-to-run wait into the
    /// critical-chain aggregate of the task's chain root. A comm mismatch means
    /// the PID was reused, so the stale link is discarded rather than credited.
    pub fn onRun(self: *ChainTracker, pid: i32, now_ns: u64, comm: []const u8) void {
        const link = self.links.getPtr(pid) orelse return;
        if (comm.len != 0 and link.comm.len != 0 and !std.mem.eql(u8, link.comm, comm)) {
            link.* = .{};
            return;
        }
        if (!link.wait_pending) return;
        link.wait_pending = false;
        const wait_us = (now_ns -| link.wait_start_ns) / 1000;
        const root = link.path[0];
        if (self.roots.getPtr(root)) |entry| {
            entry.wait.observe(wait_us);
            entry.total_wait_us +|= wait_us;
        }
    }

    fn aggregate(self: *ChainTracker, root: i32, leaf: i32, comm: []const u8, depth: u8) !void {
        if (self.roots.getPtr(root)) |existing| {
            existing.count += 1;
            if (depth >= existing.depth) {
                existing.depth = depth;
                existing.leaf_pid = leaf;
                existing.leaf_comm = try self.intern(existing.leaf_comm, comm);
            }
            return;
        }
        if (self.roots.count() >= max_chain_roots) {
            self.counters.overflow += 1;
            return;
        }
        var created: ChainAgg = .{
            .root_pid = root,
            .leaf_pid = leaf,
            .depth = depth,
            .count = 1,
        };
        created.leaf_comm = try self.intern("", comm);
        try self.roots.put(root, created);
    }

    /// Bounded critical-chain ranking: by accumulated hop wait (the critical
    /// chain), then by edge count, then by root pid for a stable order.
    pub fn snapshot(self: *ChainTracker, allocator: std.mem.Allocator, top: usize) !Snapshot {
        const limit = @min(top, max_chain_output);
        if (self.roots.count() == 0 or limit == 0) return .{ .counters = self.counters };
        var aggregates = try allocator.alloc(ChainAgg, self.roots.count());
        defer allocator.free(aggregates);
        var index: usize = 0;
        var iterator = self.roots.iterator();
        while (iterator.next()) |item| {
            if (index == aggregates.len) break;
            aggregates[index] = item.value_ptr.*;
            index += 1;
        }
        const list = aggregates[0..index];
        std.mem.sortUnstable(ChainAgg, list, {}, struct {
            fn less(_: void, a: ChainAgg, b: ChainAgg) bool {
                if (a.total_wait_us != b.total_wait_us) return a.total_wait_us > b.total_wait_us;
                if (a.count != b.count) return a.count > b.count;
                return a.root_pid < b.root_pid;
            }
        }.less);
        const take = @min(list.len, limit);
        var chains = try allocator.alloc(Chain, take);
        for (list[0..take], 0..) |item, chain_index| {
            chains[chain_index] = .{
                .root_pid = item.root_pid,
                .leaf_pid = item.leaf_pid,
                .leaf_comm = item.leaf_comm,
                .depth = item.depth,
                .count = item.count,
                .total_wait_us = item.total_wait_us,
                .p95_wait_us = item.wait.quantileUpper(950),
            };
        }
        return .{ .chains = chains, .counters = self.counters };
    }
};

/// Result of the bounded second pass over a materialized event slice. Mirrors
/// the incremental `metrics.Metrics` causal fields so either source can be
/// reported by `writeJson`.
pub const Analysis = struct {
    causes: [sched_state.cause_count]CauseStat = @splat(.{}),
    offcpu_samples: u64 = 0,
    offcpu_unresolved: u64 = 0,
    preempt: Histogram = .{},
    preemptions: u64 = 0,
    preempt_unresolved: u64 = 0,
    chains: []const Chain = &.{},
    counters: Counters = .{},

    /// Materialize an owned causal view from an incremental metrics snapshot.
    pub fn fromMetrics(allocator: std.mem.Allocator, metrics: *const metrics_mod.Metrics) !Analysis {
        var analysis: Analysis = .{
            .causes = metrics.causes,
            .offcpu_samples = metrics.offcpu_samples,
            .offcpu_unresolved = metrics.offcpu_unresolved,
            .preempt = metrics.preempt,
            .preemptions = metrics.preemptions,
            .preempt_unresolved = metrics.preempt_unresolved,
            .counters = .{
                .edges = metrics.chain_edges,
                .roots = metrics.chain_roots,
                .cycles_cut = metrics.chain_cycles_cut,
                .depth_cut = metrics.chain_depth_cut,
                .overflow = metrics.chain_overflow,
                .too_many_tasks = metrics.chain_too_many_tasks,
            },
        };
        if (metrics.chain_count != 0) {
            const count: usize = metrics.chain_count;
            analysis.chains = try allocator.dupe(Chain, metrics.chains[0..count]);
        }
        return analysis;
    }
};

const PendingSleep = struct {
    start_ns: u64,
    cause: sched_state.Cause,
};

const PendingPreempt = struct {
    start_ns: u64,
    woke: bool = false,
};

fn pidOf(value: u64) i32 {
    return @intCast(@min(value, std.math.maxInt(i32)));
}

/// Bounded second pass: per-cause off-CPU aggregation, preemption detection,
/// and critical-chain ranking over an event slice. Out-of-order timestamps
/// saturate to zero durations and stay counted by the caller's `out_of_order`.
pub fn analyze(allocator: std.mem.Allocator, events: []const event.RawEvent) !Analysis {
    var analysis: Analysis = .{};
    var chains = ChainTracker.init(allocator);
    defer chains.deinit();
    var sleeping = std.AutoHashMap(i32, PendingSleep).init(allocator);
    defer sleeping.deinit();
    var preempt = std.AutoHashMap(i32, PendingPreempt).init(allocator);
    defer preempt.deinit();
    var self_pid: i32 = -1;
    var self_seen = false;

    for (events) |entry| {
        switch (entry.kind) {
            .sched_switch => {
                const now = entry.ts_ns;
                const incoming = pidOf(entry.a);
                const outgoing = pidOf(entry.b);
                if (outgoing > 0) {
                    if (entry.c == sched_state.task_running) {
                        if (preempt.getPtr(outgoing)) |pending| {
                            pending.start_ns = now;
                            pending.woke = false;
                        } else {
                            preempt.put(outgoing, .{ .start_ns = now }) catch {};
                        }
                    } else {
                        _ = preempt.remove(outgoing);
                        if (sleeping.getPtr(outgoing)) |pending| {
                            pending.start_ns = now;
                            pending.cause = sched_state.causeOf(entry.c);
                        } else {
                            sleeping.put(outgoing, .{
                                .start_ns = now,
                                .cause = sched_state.causeOf(entry.c),
                            }) catch {};
                        }
                    }
                }
                if (incoming > 0) {
                    if (sleeping.fetchRemove(incoming)) |removed| {
                        const reason = @backingInt(removed.value.cause);
                        if (reason < sched_state.cause_count) {
                            analysis.causes[reason].count +|= 1;
                            analysis.causes[reason].total_us +|= (now -| removed.value.start_ns) / 1000;
                        }
                        analysis.offcpu_samples +|= 1;
                    }
                    if (preempt.fetchRemove(incoming)) |removed| {
                        if (!removed.value.woke) {
                            analysis.preempt.observe((now -| removed.value.start_ns) / 1000);
                        }
                    }
                    chains.onRun(incoming, now, entry.comm);
                }
            },
            .sched_wakeup => {
                const woken = pidOf(entry.a);
                if (woken <= 0) continue;
                if (preempt.getPtr(woken)) |pending| pending.woke = true;
                // The incremental pass excludes the recorder's own wakeup edges
                // from causal rankings; mirror it when the owner marker is in
                // the slice (a missing marker means unknown, not excluded).
                const woken_self = (self_seen and woken == self_pid) or
                    (!self_seen and session_meta.isProfilerComm(entry.comm));
                const waker_self = self_seen and entry.pid == self_pid;
                if (woken_self or waker_self) continue;
                const blocked = sleeping.contains(woken);
                chains.onWakeup(entry.pid, woken, entry.comm, entry.ts_ns, blocked) catch {};
            },
            .marker => {
                if (session_meta.ownerPid(entry)) |pid| {
                    self_pid = pid;
                    self_seen = true;
                }
            },
            else => {},
        }
    }

    analysis.offcpu_unresolved = sleeping.count();
    analysis.preempt_unresolved = preempt.count();
    analysis.preemptions = analysis.preempt.count;
    const snapshot = try chains.snapshot(allocator, max_chain_output);
    analysis.chains = snapshot.chains;
    analysis.counters = snapshot.counters;
    return analysis;
}

/// Write the canonical `latency` object (without a key prefix). Used by the
/// `why` report, the incident summary, and the metrics writer so all three
/// serialize identical causal fields. Keys are strictly ascending.
pub fn writeJson(w: *Writer, metrics: *const metrics_mod.Metrics) Writer.Error!void {
    var cause_values: [sched_state.cause_count]json.Value = undefined;
    var cause_entries: [sched_state.cause_count][3]json.Entry = undefined;
    var cause_count: usize = 0;
    const cause_names = @typeInfo(sched_state.Cause).@"enum".field_names;
    for (cause_names, 0..) |name, cause_index| {
        const stat = metrics.causes[cause_index];
        if (stat.count == 0) continue;
        cause_entries[cause_count][0] = .{ .key = "count", .value = .{ .unsigned = stat.count } };
        cause_entries[cause_count][1] = .{ .key = "reason", .value = .{ .string = name } };
        cause_entries[cause_count][2] = .{ .key = "total_us", .value = .{ .unsigned = stat.total_us } };
        cause_values[cause_count] = .{ .object = &cause_entries[cause_count] };
        cause_count += 1;
    }

    var chain_values: [max_chain_output]json.Value = undefined;
    var chain_entries: [max_chain_output][7]json.Entry = undefined;
    const written = @min(@as(usize, metrics.chain_count), max_chain_output);
    for (metrics.chains[0..written], 0..) |chain, index| {
        chain_entries[index][0] = .{ .key = "count", .value = .{ .unsigned = chain.count } };
        chain_entries[index][1] = .{ .key = "depth", .value = .{ .unsigned = chain.depth } };
        chain_entries[index][2] = .{ .key = "leaf_comm", .value = .{ .string = chain.leaf_comm } };
        chain_entries[index][3] = .{ .key = "leaf_pid", .value = .{ .integer = chain.leaf_pid } };
        chain_entries[index][4] = .{ .key = "p95_wait_us", .value = .{ .unsigned = chain.p95_wait_us } };
        chain_entries[index][5] = .{ .key = "root_pid", .value = .{ .integer = chain.root_pid } };
        chain_entries[index][6] = .{ .key = "total_wait_us", .value = .{ .unsigned = chain.total_wait_us } };
        chain_values[index] = .{ .object = &chain_entries[index] };
    }

    try json.write(w, .{ .object = &.{
        .{ .key = "causes", .value = .{ .array = cause_values[0..cause_count] } },
        .{ .key = "chain_cycles_cut", .value = .{ .unsigned = metrics.chain_cycles_cut } },
        .{ .key = "chain_depth_cut", .value = .{ .unsigned = metrics.chain_depth_cut } },
        .{ .key = "chain_edges", .value = .{ .unsigned = metrics.chain_edges } },
        .{ .key = "chain_overflow", .value = .{ .unsigned = metrics.chain_overflow } },
        .{ .key = "chain_roots", .value = .{ .unsigned = metrics.chain_roots } },
        .{ .key = "chain_too_many_tasks", .value = .{ .unsigned = metrics.chain_too_many_tasks } },
        .{ .key = "chain_truncated", .value = .{ .boolean = metrics.chain_truncated } },
        .{ .key = "chains", .value = .{ .array = chain_values[0..written] } },
        .{ .key = "offcpu_samples", .value = .{ .unsigned = metrics.offcpu_samples } },
        .{ .key = "offcpu_unresolved", .value = .{ .unsigned = metrics.offcpu_unresolved } },
        .{ .key = "preempt_p95_us", .value = .{ .unsigned = metrics.preempt.quantileUpper(950) } },
        .{ .key = "preempt_unresolved", .value = .{ .unsigned = metrics.preempt_unresolved } },
        .{ .key = "preemptions", .value = .{ .unsigned = metrics.preemptions } },
    } });
}

test "tracker follows the waker's most recent wakeup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tracker = ChainTracker.init(allocator);
    defer tracker.deinit();

    // 1 wakes 2 (1 is a chain root), 2 wakes 3, 3 runs.
    try tracker.onWakeup(1, 2, "b", 1_000, true);
    try tracker.onWakeup(2, 3, "c", 2_000, true);
    tracker.onRun(2, 2_500, "b");
    tracker.onRun(3, 4_000, "c");
    const snapshot = try tracker.snapshot(allocator, max_chain_output);
    try std.testing.expectEqual(@as(usize, 1), snapshot.chains.len);
    try std.testing.expectEqual(@as(i32, 1), snapshot.chains[0].root_pid);
    try std.testing.expectEqual(@as(u8, 3), snapshot.chains[0].depth);
    try std.testing.expectEqual(@as(u64, 2), snapshot.chains[0].count);
    try std.testing.expectEqual(@as(u64, 3), snapshot.chains[0].total_wait_us);
    try std.testing.expectEqual(@as(u64, 1), snapshot.counters.roots);
    try std.testing.expectEqual(@as(u64, 0), snapshot.counters.cycles_cut);
}

test "tracker cuts cycles and bounds depth" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tracker = ChainTracker.init(allocator);
    defer tracker.deinit();

    try tracker.onWakeup(1, 2, "b", 1, true);
    try tracker.onWakeup(2, 1, "a", 2, true); // cycle: 1 is in 2's path
    try std.testing.expectEqual(@as(u64, 1), tracker.counters.cycles_cut);
    try tracker.onWakeup(5, 5, "self", 3, true); // self wakeup is a cycle
    try std.testing.expectEqual(@as(u64, 2), tracker.counters.cycles_cut);

    // Build a maximal chain 10 -> 11 -> ... -> 18, then one edge past the bound.
    try tracker.onWakeup(9, 10, "t10", 10, false);
    var parent: i32 = 10;
    var child: i32 = 11;
    while (child <= 18) : ({
        parent = child;
        child += 1;
    }) {
        try tracker.onWakeup(parent, child, "t", @intCast(child), false);
    }
    try tracker.onWakeup(18, 19, "t19", 19, false);
    try std.testing.expectEqual(@as(u64, 1), tracker.counters.depth_cut);
    const snapshot = try tracker.snapshot(allocator, max_chain_output);
    for (snapshot.chains) |chain| {
        try std.testing.expect(chain.depth <= max_chain_depth);
    }
}

test "tracker discards a stale PID-reuse link on comm mismatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tracker = ChainTracker.init(allocator);
    defer tracker.deinit();
    try tracker.onWakeup(1, 20, "worker", 1_000, true);
    // PID 20 was recycled: the switch-in names a different task.
    tracker.onRun(20, 9_000, "replacement");
    const snapshot = try tracker.snapshot(allocator, max_chain_output);
    try std.testing.expectEqual(@as(u64, 0), snapshot.chains[0].total_wait_us);
}

test "tracker ranks critical chains by accumulated hop wait" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tracker = ChainTracker.init(allocator);
    defer tracker.deinit();

    try tracker.onWakeup(100, 101, "short", 1_000, true);
    tracker.onRun(101, 2_000, "short"); // 1us
    try tracker.onWakeup(200, 201, "long", 5_000, true);
    try tracker.onWakeup(201, 202, "long", 6_000, true);
    tracker.onRun(201, 6_000 + 50_000, "long"); // 50us
    tracker.onRun(202, 6_000 + 80_000, "long"); // 74us
    const snapshot = try tracker.snapshot(allocator, max_chain_output);
    try std.testing.expectEqual(@as(i32, 200), snapshot.chains[0].root_pid);
    try std.testing.expectEqual(@as(i32, 100), snapshot.chains[1].root_pid);
    try std.testing.expectEqual(@as(u64, 131), snapshot.chains[0].total_wait_us);
}

test "voluntary block and preemption are distinguished" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const events = [_]event.RawEvent{
        .{ .kind = .sched_switch, .ts_ns = 1_000_000, .a = 2, .b = 1, .c = 0, .comm = "b" },
        .{ .kind = .sched_switch, .ts_ns = 2_000_000, .a = 1, .b = 2, .c = 1, .comm = "a" },
        .{ .kind = .sched_wakeup, .ts_ns = 2_500_000, .pid = 1, .a = 2, .comm = "b" },
        .{ .kind = .sched_switch, .ts_ns = 3_000_000, .a = 2, .b = 1, .c = 0, .comm = "b" },
        .{ .kind = .sched_switch, .ts_ns = 3_500_000, .a = 1, .b = 2, .c = 0, .comm = "a" },
    };
    const analysis = try analyze(allocator, &events);
    try std.testing.expectEqual(@as(u64, 1), analysis.offcpu_samples);
    try std.testing.expectEqual(@as(u64, 1), analysis.causes[@backingInt(sched_state.Cause.interruptible)].count);
    try std.testing.expectEqual(@as(u64, 1_000), analysis.causes[@backingInt(sched_state.Cause.interruptible)].total_us);
    try std.testing.expectEqual(@as(u64, 2), analysis.preemptions);
    try std.testing.expectEqual(@as(u64, 2), analysis.preempt.count);
    try std.testing.expectEqual(@as(u64, 1), analysis.chains.len);
    try std.testing.expectEqual(@as(u64, 1), analysis.counters.roots);
}

test "a migration during the wait does not break attribution" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const events = [_]event.RawEvent{
        .{ .kind = .sched_switch, .ts_ns = 1_000_000, .a = 5, .b = 0, .c = 0, .comm = "w" },
        .{ .kind = .sched_switch, .ts_ns = 2_000_000, .a = 6, .b = 5, .c = 1, .comm = "x" },
        .{ .kind = .sched_migrate, .ts_ns = 2_500_000, .pid = 5, .a = 0, .b = 1, .comm = "w" },
        .{ .kind = .sched_wakeup, .ts_ns = 3_000_000, .pid = 6, .a = 5, .comm = "w" },
        .{ .kind = .sched_switch, .ts_ns = 5_000_000, .a = 5, .b = 6, .c = 1, .comm = "w" },
    };
    const analysis = try analyze(allocator, &events);
    try std.testing.expectEqual(@as(u64, 1), analysis.causes[@backingInt(sched_state.Cause.interruptible)].count);
    try std.testing.expectEqual(@as(u64, 3_000), analysis.causes[@backingInt(sched_state.Cause.interruptible)].total_us);
}

test "lost wakeups stay explicit instead of zero" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const events = [_]event.RawEvent{
        // Waker pid 0 is not a task: the edge still counts as a chain root.
        .{ .kind = .sched_wakeup, .ts_ns = 1_000, .pid = 0, .a = 7, .comm = "w" },
        // Unknown prev_state bits are attributed to `unknown`, never zeroed.
        .{ .kind = .sched_switch, .ts_ns = 2_000, .a = 8, .b = 9, .c = 0x10000, .comm = "x" },
        .{ .kind = .sched_switch, .ts_ns = 3_000, .a = 9, .b = 10, .c = 1, .comm = "x" },
        // A switch-in with no preceding switch-out is not invented as a wait.
        .{ .kind = .sched_switch, .ts_ns = 4_000, .a = 11, .b = 12, .c = 1, .comm = "y" },
    };
    const analysis = try analyze(allocator, &events);
    try std.testing.expectEqual(@as(u64, 1), analysis.counters.roots);
    try std.testing.expectEqual(@as(u64, 1), analysis.chains.len);
    try std.testing.expectEqual(@as(u8, 1), analysis.chains[0].depth);
    try std.testing.expectEqual(@as(u64, 1), analysis.causes[@backingInt(sched_state.Cause.unknown)].count);
    try std.testing.expectEqual(@as(u64, 1), analysis.causes[@backingInt(sched_state.Cause.unknown)].total_us);
    try std.testing.expectEqual(@as(u64, 0), analysis.preemptions);
}

test "out-of-order timestamps degrade to zero, never underflow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const events = [_]event.RawEvent{
        .{ .kind = .sched_switch, .ts_ns = 5_000_000, .a = 3, .b = 4, .c = 1, .comm = "sleeper" },
        .{ .kind = .sched_wakeup, .ts_ns = 6_000_000, .pid = 2, .a = 4, .comm = "sleeper" },
        // Replayed legacy reversal: the run row is older than the wakeup.
        .{ .kind = .sched_switch, .ts_ns = 1_000_000, .a = 4, .b = 5, .c = 1, .comm = "sleeper" },
    };
    const analysis = try analyze(allocator, &events);
    try std.testing.expectEqual(@as(u64, 1), analysis.offcpu_samples);
    try std.testing.expectEqual(@as(u64, 1), analysis.chains.len);
    try std.testing.expectEqual(@as(u64, 0), analysis.chains[0].total_wait_us);
}

test "self events are cycles, not crashes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const events = [_]event.RawEvent{
        .{ .kind = .sched_wakeup, .ts_ns = 1_000, .pid = 30, .a = 30, .comm = "self" },
        .{ .kind = .sched_switch, .ts_ns = 2_000, .a = 30, .b = 30, .c = 0, .comm = "self" },
    };
    const analysis = try analyze(allocator, &events);
    try std.testing.expectEqual(@as(u64, 1), analysis.counters.cycles_cut);
    try std.testing.expectEqual(@as(u64, 1), analysis.counters.edges);
}

test "latency json is canonical and omits empty causes" {
    var metrics: metrics_mod.Metrics = .{};
    metrics.causes[@backingInt(sched_state.Cause.interruptible)] = .{ .count = 2, .total_us = 500 };
    metrics.offcpu_samples = 2;
    metrics.preempt.observe(7);
    metrics.preemptions = 1;
    var buf: [4096]u8 = undefined;
    var writer = Writer.fixed(&buf);
    try writeJson(&writer, &metrics);
    const text = writer.buffered();
    try std.testing.expect(std.mem.startsWith(u8, text, "{\"causes\":[{\"count\":2,\"reason\":\"interruptible\",\"total_us\":500}]"));
    try std.testing.expect(std.mem.indexOf(u8, text, "\"chain_cycles_cut\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"offcpu_samples\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"preemptions\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"reason\":\"dead\"") == null);
}

test "second pass excludes recorder self wakeup chains" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const events = [_]event.RawEvent{
        .{ .kind = .marker, .ts_ns = 0, .pid = 9, .detail = "capture_owner", .comm = "xsprof" },
        // The recorder wakes itself: excluded from causal chains in both passes.
        .{ .kind = .sched_wakeup, .ts_ns = 1_000, .pid = 9, .a = 9, .comm = "xsprof" },
        // A workload wakeup is still tracked normally.
        .{ .kind = .sched_wakeup, .ts_ns = 2_000, .pid = 9, .a = 10, .comm = "worker" },
        .{ .kind = .sched_wakeup, .ts_ns = 3_000, .pid = 10, .a = 11, .comm = "worker-b" },
    };
    const analysis = try analyze(allocator, &events);
    try std.testing.expectEqual(@as(u64, 1), analysis.counters.edges);
    try std.testing.expectEqual(@as(usize, 1), analysis.chains.len);
    try std.testing.expectEqual(@as(i32, 10), analysis.chains[0].root_pid);
    try std.testing.expectEqual(@as(i32, 11), analysis.chains[0].leaf_pid);
}
