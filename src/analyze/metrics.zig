//! Incremental scheduler metrics: wakeup-to-run latency, off-CPU time, CPU
//! busy, migrations, and page faults. Quantiles are bounded log histograms.

const std = @import("std");
const event = @import("../core/event.zig");
const loss = @import("../core/loss.zig");
const sched_state = @import("../core/sched_state.zig");
const session_meta = @import("../core/session_meta.zig");
const latency = @import("latency.zig");

const max_cpus = 256;
const bucket_count = 64;

/// Bounded per-cause off-CPU aggregate: one switch-out attributed to a decoded
/// `prev_state` cause and the accumulated time until the task ran again.
pub const CauseStat = struct {
    count: u64 = 0,
    total_us: u64 = 0,
};

/// A bounded critical wakeup chain: one causal root, its deepest observed leaf,
/// and the accumulated wake-to-run wait of every edge in chains rooted there.
pub const Chain = struct {
    root_pid: i32 = -1,
    leaf_pid: i32 = -1,
    leaf_comm: []const u8 = "",
    depth: u8 = 0,
    count: u64 = 0,
    total_wait_us: u64 = 0,
    p95_wait_us: u64 = 0,
};

pub const max_chains = latency.max_chain_output;

pub const Histogram = struct {
    buckets: [bucket_count]u64 = @splat(0),
    count: u64 = 0,
    total_us: u64 = 0,
    max_us: u64 = 0,

    pub fn observe(self: *Histogram, us_value: u64) void {
        const bucket: usize = if (us_value <= 1) 0 else @min(bucket_count - 1, 63 - @clz(us_value));
        self.buckets[bucket] += 1;
        self.count += 1;
        self.total_us +|= us_value;
        self.max_us = @max(self.max_us, us_value);
    }

    pub fn quantileUpper(self: *const Histogram, permille: u64) u64 {
        if (self.count == 0) return 0;
        const target = @max(1, (self.count * permille + 999) / 1000);
        var seen: u64 = 0;
        for (self.buckets, 0..) |count, index| {
            seen += count;
            if (seen >= target) {
                const shift: u6 = @intCast(@min(63, index + 1));
                return @as(u64, 1) << shift;
            }
        }
        return self.max_us;
    }
};

pub const WakeupPair = struct {
    waker_pid: i32,
    woken_pid: i32,
    waker_comm: []const u8 = "",
    woken_comm: []const u8 = "",
    count: u64 = 0,
    p95_wait_us: u64 = 0,
};

pub const TaskMetric = struct {
    pid: i32,
    comm: []const u8,
    is_self: bool = false,
    switches: u64 = 0,
    wakeups: u64 = 0,
    migrations: u64 = 0,
    faults_minor: u64 = 0,
    faults_major: u64 = 0,
    wait_samples: u64 = 0,
    wait_p50_us: u64 = 0,
    wait_p95_us: u64 = 0,
    wait_p99_us: u64 = 0,
    wait_max_us: u64 = 0,
    offcpu_p95_us: u64 = 0,
    /// Blocked-sleep samples attributed to the decoded switch-out cause.
    offcpu_by_reason: [sched_state.cause_count]CauseStat = @splat(CauseStat{}),
    /// Detected involuntary preemptions and their wait distribution.
    preemptions: u64 = 0,
    preempt_p95_us: u64 = 0,
    last_cpu: i32 = -1,
};

pub const CpuMetric = struct {
    cpu: u8,
    busy_us: u64 = 0,
    idle_us: u64 = 0,
    switches: u64 = 0,
    faults: u64 = 0,
};

pub const Metrics = struct {
    events: u64 = 0,
    first_us: u64 = 0,
    last_us: u64 = 0,
    switches: u64 = 0,
    wakeups: u64 = 0,
    self_wakeups: u64 = 0,
    unnecessary_wakeups: u64 = 0,
    unresolved_wakeups: u64 = 0,
    self_unnecessary_wakeups: u64 = 0,
    migrations: u64 = 0,
    faults_minor: u64 = 0,
    faults_major: u64 = 0,
    lost: u64 = 0,
    /// Per-kind breakdown of `lost`; every loss marker kind is counted.
    loss_by_kind: loss.ByKind = .{},
    out_of_order: u64 = 0,
    pairs_truncated: bool = false,
    wait: Histogram = .{},
    offcpu: Histogram = .{},
    /// Blocked-sleep samples whose cause could not be attributed (unknown bits,
    /// bare modifiers) are counted in `causes[.unknown/.other]`, never dropped.
    offcpu_samples: u64 = 0,
    /// Tasks that were still blocked when the window ended: duration unknown.
    offcpu_unresolved: u64 = 0,
    causes: [sched_state.cause_count]CauseStat = @splat(CauseStat{}),
    preempt: Histogram = .{},
    preemptions: u64 = 0,
    preempt_unresolved: u64 = 0,
    chains: [max_chains]Chain = @splat(Chain{}),
    chain_count: u8 = 0,
    chain_edges: u64 = 0,
    chain_roots: u64 = 0,
    chain_cycles_cut: u64 = 0,
    chain_depth_cut: u64 = 0,
    chain_overflow: u64 = 0,
    chain_too_many_tasks: u64 = 0,
    chain_truncated: bool = false,
    /// Experimental sampled-stack rows: counted only. No latency is invented
    /// for them (they carry no scheduler state and no wakeup edges).
    stack_frames: u64 = 0,
    stack_samples: u64 = 0,
    cpus: []const CpuMetric = &.{},
    tasks: []const TaskMetric = &.{},
    wakeup_pairs: []const WakeupPair = &.{},
};

const Task = struct {
    pid: i32,
    comm: []const u8 = "",
    switches: u64 = 0,
    wakeups: u64 = 0,
    migrations: u64 = 0,
    faults_minor: u64 = 0,
    faults_major: u64 = 0,
    wait: Histogram = .{},
    offcpu: Histogram = .{},
    offcpu_by_reason: [sched_state.cause_count]CauseStat = @splat(CauseStat{}),
    preempt: Histogram = .{},
    last_cpu: i32 = -1,
    runnable_since_ns: ?u64 = null,
    sleep_since_ns: ?u64 = null,
    sleep_cause: sched_state.Cause = .unknown,
    preempt_since_ns: ?u64 = null,
    preempt_wakeup: bool = false,
    wakeup_pending: bool = false,
    running: bool = false,
    last_waker_pid: i32 = -1,
};

const PairKey = struct {
    waker: i32,
    woken: i32,
};

const PairAgg = struct {
    count: u64 = 0,
    wait: Histogram = .{},
    woken_comm: []const u8 = "",
};

const Cpu = struct {
    busy_us: u64 = 0,
    idle_us: u64 = 0,
    switches: u64 = 0,
    faults: u64 = 0,
    active_since_ns: ?u64 = null,
    active_pid: i32 = -1,
};

pub const Index = struct {
    allocator: std.mem.Allocator,
    tasks: std.AutoHashMap(i32, Task),
    names: std.heap.ArenaAllocator,
    cpu: [max_cpus]Cpu = @splat(.{}),
    first_us: u64 = std.math.maxInt(u64),
    last_us: u64 = 0,
    switches: u64 = 0,
    wakeups: u64 = 0,
    migrations: u64 = 0,
    faults_minor: u64 = 0,
    faults_major: u64 = 0,
    loss_counter: loss.Counter = .{},
    wait: Histogram = .{},
    offcpu: Histogram = .{},
    causes: [sched_state.cause_count]CauseStat = @splat(CauseStat{}),
    preempt: Histogram = .{},
    events: u64 = 0,
    self_pid: i32 = -1,
    self_seen: bool = false,
    self_wakeups: u64 = 0,
    redundant_wakeups: u64 = 0,
    self_redundant_wakeups: u64 = 0,
    timed_events: usize = 0,
    pairs: std.AutoHashMap(PairKey, PairAgg),
    pair_overflow: u64 = 0,
    out_of_order: u64 = 0,
    last_timed_ns: ?u64 = null,
    stack_frames: u64 = 0,
    stack_samples: u64 = 0,
    chains: latency.ChainTracker,

    pub fn setSelf(self: *Index, meta: *const session_meta.Meta) void {
        if (!meta.self_seen) return;
        self.self_pid = meta.self_pid;
        self.self_seen = true;
    }

    fn isSelf(self: *const Index, pid: i32, comm: []const u8) bool {
        if (self.self_seen) return pid > 0 and pid == self.self_pid;
        return session_meta.isProfilerComm(comm);
    }

    pub fn init(allocator: std.mem.Allocator) Index {
        return .{
            .allocator = allocator,
            .tasks = std.AutoHashMap(i32, Task).init(allocator),
            .names = std.heap.ArenaAllocator.init(allocator),
            .pairs = std.AutoHashMap(PairKey, PairAgg).init(allocator),
            .chains = latency.ChainTracker.init(allocator),
        };
    }

    pub fn deinit(self: *Index) void {
        self.tasks.deinit();
        self.pairs.deinit();
        self.chains.deinit();
        self.names.deinit();
    }

    fn getTask(self: *Index, pid: i32) !*Task {
        if (self.tasks.getPtr(pid)) |value| return value;
        try self.tasks.put(pid, .{ .pid = pid });
        return self.tasks.getPtr(pid).?;
    }

    pub fn append(self: *Index, events: []const event.RawEvent) !void {
        self.events += events.len;
        for (events) |entry| {
            if (!session_meta.isMetadata(entry)) {
                const us = entry.ts_ns / 1000;
                if (self.last_timed_ns) |last_ns| {
                    if (entry.ts_ns < last_ns) self.out_of_order += 1;
                }
                self.last_timed_ns = entry.ts_ns;
                self.first_us = @min(self.first_us, us);
                self.last_us = @max(self.last_us, us);
                self.timed_events += 1;
            }
            switch (entry.kind) {
                .sched_switch => try self.onSwitch(entry),
                .sched_wakeup => {
                    self.wakeups += 1;
                    const pid: i32 = @intCast(@min(entry.a, std.math.maxInt(i32)));
                    const is_self = self.isSelf(pid, entry.comm);
                    if (is_self) self.self_wakeups += 1;
                    const task = try self.getTask(pid);
                    task.wakeups += 1;
                    if (task.comm.len == 0 and entry.comm.len != 0) {
                        task.comm = try self.names.allocator().dupe(u8, entry.comm);
                    }
                    const was_blocked = !task.running and task.runnable_since_ns == null;
                    if (task.preempt_since_ns != null) task.preempt_wakeup = true;
                    if (was_blocked) {
                        task.runnable_since_ns = entry.ts_ns;
                        task.wakeup_pending = true;
                    } else if (is_self) {
                        self.self_redundant_wakeups += 1;
                    } else {
                        self.redundant_wakeups += 1;
                    }
                    const waker: i32 = entry.pid;
                    if (!is_self and pid > 0 and !(waker > 0 and self.isSelf(waker, ""))) {
                        try self.chains.onWakeup(waker, pid, entry.comm, entry.ts_ns, was_blocked);
                    }
                    if (!is_self and waker > 0 and pid > 0 and !self.isSelf(waker, "")) {
                        task.last_waker_pid = waker;
                        const key: PairKey = .{ .waker = waker, .woken = pid };
                        if (self.pairs.getPtr(key)) |pair| {
                            pair.count += 1;
                        } else if (self.pairs.count() < 4096) {
                            var pair: PairAgg = .{ .count = 1 };
                            if (entry.comm.len != 0) {
                                pair.woken_comm = try self.names.allocator().dupe(u8, entry.comm);
                            }
                            try self.pairs.put(key, pair);
                        } else {
                            self.pair_overflow += 1;
                        }
                    }
                },
                .sched_migrate => {
                    self.migrations += 1;
                    if (entry.pid >= 0) {
                        const task = try self.getTask(entry.pid);
                        task.migrations += 1;
                    }
                },
                .page_fault => {
                    if (entry.b == 1) self.faults_major += 1 else self.faults_minor += 1;
                    if (entry.pid >= 0) {
                        const task = try self.getTask(entry.pid);
                        if (entry.b == 1) task.faults_major += 1 else task.faults_minor += 1;
                    }
                    if (entry.cpu >= 0 and entry.cpu < max_cpus) {
                        self.cpu[@intCast(entry.cpu)].faults += 1;
                    }
                },
                .marker => {
                    if (session_meta.ownerPid(entry)) |pid| {
                        self.self_pid = pid;
                        self.self_seen = true;
                    }
                    // Loss accounting is centralized: every registered kind
                    // counts, not just the sample_loss markers the old
                    // substring scan happened to match.
                    _ = self.loss_counter.add(entry.detail);
                },
                .stack_sample => {
                    // Sampling rows are counted, never interpreted as
                    // scheduler latency (they carry no wakeup/switch state).
                    self.stack_samples +|= 1;
                    self.stack_frames +|= entry.stack.len;
                },
                else => {},
            }
        }
    }

    fn onSwitch(self: *Index, entry: event.RawEvent) !void {
        self.switches += 1;
        const now = entry.ts_ns;
        if (entry.cpu >= 0 and entry.cpu < max_cpus) {
            const cpu = &self.cpu[@intCast(entry.cpu)];
            if (cpu.active_since_ns) |started| {
                const delta = (now -| started) / 1000;
                if (cpu.active_pid == 0) cpu.idle_us +|= delta else cpu.busy_us +|= delta;
            }
            cpu.active_since_ns = now;
            cpu.active_pid = @intCast(@min(entry.a, std.math.maxInt(i32)));
            cpu.switches += 1;
        }

        const outgoing_pid: i32 = @intCast(@min(entry.b, std.math.maxInt(i32)));
        {
            const outgoing = try self.getTask(outgoing_pid);
            outgoing.last_cpu = entry.cpu;
            outgoing.running = false;
            outgoing.wakeup_pending = false;
            // Legacy captures may still carry the kernel preemption marker:
            // normalize before deciding (`c == 0` == left the CPU runnable).
            const prev_state = sched_state.normalizePrevState(entry.c);
            if (prev_state == sched_state.task_running) {
                // Still runnable: this is a preemption candidate. It becomes a
                // measured preemption only if the task runs again without an
                // intervening wakeup (an already-runnable task needs no wakeup).
                outgoing.sleep_since_ns = null;
                outgoing.runnable_since_ns = now;
                if (outgoing_pid > 0 and outgoing.preempt_since_ns == null) {
                    outgoing.preempt_since_ns = now;
                    outgoing.preempt_wakeup = false;
                }
            } else {
                outgoing.sleep_since_ns = now;
                outgoing.sleep_cause = sched_state.causeOf(prev_state);
                outgoing.preempt_since_ns = null;
                outgoing.preempt_wakeup = false;
            }
        }
        {
            const incoming = try self.getTask(@intCast(@min(entry.a, std.math.maxInt(i32))));
            incoming.switches += 1;
            incoming.last_cpu = entry.cpu;
            incoming.running = true;
            incoming.wakeup_pending = false;
            if (entry.comm.len != 0 and
                (incoming.comm.len == 0 or !std.mem.eql(u8, incoming.comm, entry.comm)))
            {
                incoming.comm = try self.names.allocator().dupe(u8, entry.comm);
            }
            if (incoming.runnable_since_ns) |started| {
                const wait_us = (now -| started) / 1000;
                incoming.wait.observe(wait_us);
                self.wait.observe(wait_us);
                if (incoming.last_waker_pid > 0) {
                    if (self.pairs.getPtr(.{
                        .waker = incoming.last_waker_pid,
                        .woken = incoming.pid,
                    })) |pair| {
                        pair.wait.observe(wait_us);
                    }
                    incoming.last_waker_pid = -1;
                }
                incoming.runnable_since_ns = null;
            }
            if (incoming.sleep_since_ns) |started| {
                const offcpu_us = (now -| started) / 1000;
                incoming.offcpu.observe(offcpu_us);
                self.offcpu.observe(offcpu_us);
                const reason = @backingInt(incoming.sleep_cause);
                incoming.offcpu_by_reason[reason].count +|= 1;
                incoming.offcpu_by_reason[reason].total_us +|= offcpu_us;
                self.causes[reason].count +|= 1;
                self.causes[reason].total_us +|= offcpu_us;
                incoming.sleep_since_ns = null;
            }
            if (incoming.preempt_since_ns) |started| {
                // Only an involuntary wait counts: a wakeup in between means the
                // task was re-queued by a waker, not resumed by the scheduler.
                if (!incoming.preempt_wakeup) {
                    const preempt_us = (now -| started) / 1000;
                    incoming.preempt.observe(preempt_us);
                    self.preempt.observe(preempt_us);
                }
                incoming.preempt_since_ns = null;
                incoming.preempt_wakeup = false;
            }
            self.chains.onRun(incoming.pid, now, entry.comm);
        }
    }

    pub fn snapshot(self: *Index, allocator: std.mem.Allocator) !Metrics {
        var task_list: std.ArrayList(TaskMetric) = .empty;
        errdefer task_list.deinit(allocator);
        var unresolved: u64 = 0;
        var self_unresolved: u64 = 0;
        var offcpu_unresolved: u64 = 0;
        var preempt_unresolved: u64 = 0;
        var iterator = self.tasks.iterator();
        while (iterator.next()) |item| {
            const task = item.value_ptr;
            const is_self = self.isSelf(task.pid, task.comm);
            if (task.wakeup_pending) {
                if (is_self) self_unresolved += 1 else unresolved += 1;
            }
            if (task.sleep_since_ns != null) offcpu_unresolved += 1;
            if (task.preempt_since_ns != null) preempt_unresolved += 1;
            try task_list.append(allocator, .{
                .pid = task.pid,
                .comm = try allocator.dupe(u8, task.comm),
                .is_self = is_self,
                .switches = task.switches,
                .wakeups = task.wakeups,
                .migrations = task.migrations,
                .faults_minor = task.faults_minor,
                .faults_major = task.faults_major,
                .wait_samples = task.wait.count,
                .wait_p50_us = task.wait.quantileUpper(500),
                .wait_p95_us = task.wait.quantileUpper(950),
                .wait_p99_us = task.wait.quantileUpper(990),
                .wait_max_us = task.wait.max_us,
                .offcpu_p95_us = task.offcpu.quantileUpper(950),
                .offcpu_by_reason = task.offcpu_by_reason,
                .preemptions = task.preempt.count,
                .preempt_p95_us = task.preempt.quantileUpper(950),
                .last_cpu = task.last_cpu,
            });
        }
        std.mem.sortUnstable(TaskMetric, task_list.items, {}, struct {
            fn less(_: void, a: TaskMetric, b: TaskMetric) bool {
                if (a.wait_p95_us != b.wait_p95_us) return a.wait_p95_us > b.wait_p95_us;
                if (!std.mem.eql(u8, a.comm, b.comm)) return std.mem.order(u8, a.comm, b.comm) == .lt;
                return a.pid < b.pid;
            }
        }.less);

        var cpu_list: std.ArrayList(CpuMetric) = .empty;
        errdefer cpu_list.deinit(allocator);
        for (self.cpu, 0..) |cpu, index| {
            if (cpu.switches == 0 and cpu.faults == 0) continue;
            try cpu_list.append(allocator, .{
                .cpu = @intCast(index),
                .busy_us = cpu.busy_us,
                .idle_us = cpu.idle_us,
                .switches = cpu.switches,
                .faults = cpu.faults,
            });
        }
        var pair_list: std.ArrayList(WakeupPair) = .empty;
        errdefer pair_list.deinit(allocator);
        var pair_it = self.pairs.iterator();
        while (pair_it.next()) |item| {
            const key = item.key_ptr.*;
            const pair = item.value_ptr.*;
            const waker_comm = if (self.tasks.get(key.waker)) |waker| waker.comm else "";
            const woken_comm = if (pair.woken_comm.len != 0)
                pair.woken_comm
            else if (self.tasks.get(key.woken)) |woken| woken.comm else "";
            try pair_list.append(allocator, .{
                .waker_pid = key.waker,
                .woken_pid = key.woken,
                .waker_comm = try allocator.dupe(u8, waker_comm),
                .woken_comm = try allocator.dupe(u8, woken_comm),
                .count = pair.count,
                .p95_wait_us = pair.wait.quantileUpper(950),
            });
        }
        std.mem.sortUnstable(WakeupPair, pair_list.items, {}, struct {
            fn less(_: void, a: WakeupPair, b: WakeupPair) bool {
                if (a.count != b.count) return a.count > b.count;
                if (a.p95_wait_us != b.p95_wait_us) return a.p95_wait_us > b.p95_wait_us;
                if (!std.mem.eql(u8, a.woken_comm, b.woken_comm)) {
                    return std.mem.order(u8, a.woken_comm, b.woken_comm) == .lt;
                }
                if (a.waker_pid != b.waker_pid) return a.waker_pid < b.waker_pid;
                return a.woken_pid < b.woken_pid;
            }
        }.less);
        const pair_total = pair_list.items.len;
        const pair_cap = @min(pair_total, 32);
        const pairs_truncated = pair_total > pair_cap or self.pair_overflow != 0;

        const chain_snapshot = try self.chains.snapshot(allocator, max_chains);
        const chain_count: u8 = @intCast(chain_snapshot.chains.len);
        var chain_array: [max_chains]Chain = @splat(Chain{});
        for (chain_snapshot.chains, 0..) |chain, chain_index| {
            chain_array[chain_index] = chain;
            chain_array[chain_index].leaf_comm = try allocator.dupe(u8, chain.leaf_comm);
        }
        if (chain_snapshot.chains.len != 0) allocator.free(chain_snapshot.chains);

        return .{
            .events = self.events,
            .first_us = if (self.timed_events == 0) 0 else self.first_us,
            .last_us = if (self.timed_events == 0) 0 else self.last_us,
            .switches = self.switches,
            .wakeups = self.wakeups,
            .self_wakeups = self.self_wakeups,
            .unnecessary_wakeups = self.redundant_wakeups + unresolved,
            .unresolved_wakeups = unresolved,
            .self_unnecessary_wakeups = self.self_redundant_wakeups + self_unresolved,
            .migrations = self.migrations,
            .faults_minor = self.faults_minor,
            .faults_major = self.faults_major,
            .lost = self.loss_counter.total(),
            .loss_by_kind = self.loss_counter.totals,
            .out_of_order = self.out_of_order,
            .pairs_truncated = pairs_truncated,
            .wait = self.wait,
            .offcpu = self.offcpu,
            .offcpu_samples = self.offcpu.count,
            .offcpu_unresolved = offcpu_unresolved,
            .causes = self.causes,
            .preempt = self.preempt,
            .preemptions = self.preempt.count,
            .preempt_unresolved = preempt_unresolved,
            .chains = chain_array,
            .chain_count = chain_count,
            .chain_edges = chain_snapshot.counters.edges,
            .chain_roots = chain_snapshot.counters.roots,
            .chain_cycles_cut = chain_snapshot.counters.cycles_cut,
            .chain_depth_cut = chain_snapshot.counters.depth_cut,
            .chain_overflow = chain_snapshot.counters.overflow,
            .chain_too_many_tasks = chain_snapshot.counters.too_many_tasks,
            .chain_truncated = chain_snapshot.counters.overflow != 0 or
                chain_snapshot.counters.too_many_tasks != 0,
            .stack_frames = self.stack_frames,
            .stack_samples = self.stack_samples,
            .cpus = try cpu_list.toOwnedSlice(allocator),
            .tasks = try task_list.toOwnedSlice(allocator),
            .wakeup_pairs = try pair_list.toOwnedSlice(allocator),
        };
    }
};

// Checks wakeup-to-run and preemption waits with exact synthetic timestamps.
test "metrics measure waits and preemption" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var index = Index.init(arena.allocator());
    const events = [_]event.RawEvent{
        .{ .kind = .sched_switch, .ts_ns = 0, .cpu = 0, .a = 1, .b = 0, .c = 1, .comm = "a" },
        .{ .kind = .sched_switch, .ts_ns = 50_000, .cpu = 0, .a = 0, .b = 1, .c = 1, .comm = "" },
        .{ .kind = .sched_wakeup, .ts_ns = 100_000, .cpu = 0, .a = 1, .comm = "a" },
        .{ .kind = .sched_switch, .ts_ns = 300_000, .cpu = 0, .a = 1, .b = 2, .c = 1, .comm = "a" },
        .{ .kind = .sched_wakeup, .ts_ns = 320_000, .cpu = 0, .a = 2, .comm = "b" },
        .{ .kind = .sched_switch, .ts_ns = 350_000, .cpu = 0, .a = 2, .b = 1, .c = 0, .comm = "b" },
    };
    try index.append(&events);
    const metrics = try index.snapshot(arena.allocator());
    try std.testing.expectEqual(@as(u64, 4), metrics.switches);
    var found_a = false;
    var found_b = false;
    for (metrics.tasks) |task| {
        if (std.mem.eql(u8, task.comm, "a")) {
            found_a = task.wait_samples == 1;
            try std.testing.expect(task.wait_p95_us >= 200);
        }
        if (std.mem.eql(u8, task.comm, "b")) {
            found_b = task.wait_samples == 1;
        }
    }
    try std.testing.expect(found_a);
    try std.testing.expect(found_b);
    try std.testing.expect(metrics.cpus.len == 1);
    try std.testing.expect(metrics.cpus[0].busy_us >= 50);
}

test "wakeup pairs attribute wait and expose ordering skew" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var index = Index.init(arena.allocator());
    const events = [_]event.RawEvent{
        .{ .kind = .sched_wakeup, .ts_ns = 10_000, .cpu = 0, .pid = 9, .a = 1, .comm = "worker" },
        .{ .kind = .sched_switch, .ts_ns = 20_000, .cpu = 0, .a = 1, .b = 0, .c = 1, .comm = "worker" },
        .{ .kind = .sched_wakeup, .ts_ns = 15_000, .cpu = 0, .a = 2, .pid = 9, .comm = "worker" },
    };
    try index.append(&events);
    const metrics = try index.snapshot(arena.allocator());
    try std.testing.expectEqual(@as(u64, 1), metrics.out_of_order);
    var found = false;
    for (metrics.wakeup_pairs) |pair| {
        if (pair.waker_pid == 9 and pair.woken_pid == 1) {
            found = true;
            try std.testing.expectEqualStrings("worker", pair.woken_comm);
            try std.testing.expect(pair.p95_wait_us > 0);
        }
    }
    try std.testing.expect(found);
}

test "unnecessary wakeups count redundant and unresolved, not followed runs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var index = Index.init(arena.allocator());
    const events = [_]event.RawEvent{
        .{ .kind = .sched_wakeup, .ts_ns = 0, .cpu = 0, .a = 1, .comm = "a" },
        .{ .kind = .sched_switch, .ts_ns = 10, .cpu = 0, .a = 1, .b = 0, .c = 1, .comm = "a" },
        .{ .kind = .sched_wakeup, .ts_ns = 20, .cpu = 0, .a = 1, .comm = "a" },
        .{ .kind = .sched_wakeup, .ts_ns = 30, .cpu = 0, .a = 2, .comm = "b" },
        .{ .kind = .sched_switch, .ts_ns = 40, .cpu = 0, .a = 2, .b = 1, .c = 1, .comm = "b" },
        .{ .kind = .sched_wakeup, .ts_ns = 50, .cpu = 0, .a = 3, .comm = "c" },
    };
    try index.append(&events);
    const metrics = try index.snapshot(arena.allocator());
    try std.testing.expectEqual(@as(u64, 4), metrics.wakeups);
    try std.testing.expectEqual(@as(u64, 2), metrics.unnecessary_wakeups);
    try std.testing.expectEqual(@as(u64, 1), metrics.unresolved_wakeups);
    try std.testing.expectEqual(@as(u64, 0), metrics.self_wakeups);
}

test "recorder wakeups are excluded from workload churn" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var index = Index.init(arena.allocator());
    const events = [_]event.RawEvent{
        .{ .kind = .marker, .ts_ns = 0, .pid = 7, .detail = "capture_owner" },
        .{ .kind = .sched_wakeup, .ts_ns = 10, .cpu = 0, .a = 7, .comm = "xsprof" },
        .{ .kind = .sched_wakeup, .ts_ns = 20, .cpu = 0, .a = 9, .comm = "worker" },
    };
    try index.append(&events);
    const metrics = try index.snapshot(arena.allocator());
    try std.testing.expectEqual(@as(u64, 2), metrics.wakeups);
    try std.testing.expectEqual(@as(u64, 1), metrics.self_wakeups);
    try std.testing.expectEqual(@as(u64, 1), metrics.unnecessary_wakeups);
    try std.testing.expectEqual(@as(u64, 1), metrics.self_unnecessary_wakeups);
    var self_task = false;
    var worker_task = false;
    for (metrics.tasks) |task| {
        if (std.mem.eql(u8, task.comm, "xsprof")) self_task = task.is_self;
        if (std.mem.eql(u8, task.comm, "worker")) worker_task = !task.is_self;
    }
    try std.testing.expect(self_task);
    try std.testing.expect(worker_task);
}

// Checks that the index owns task names instead of borrowing caller buffers.
test "metrics own comm strings" {
    var names_buf = [_]u8{ 'w', 'o', 'r', 'k', 'e', 'r' };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var index = Index.init(arena.allocator());
    const events = [_]event.RawEvent{
        .{ .kind = .sched_switch, .ts_ns = 0, .cpu = 0, .a = 1, .b = 0, .c = 1, .comm = &names_buf },
    };
    try index.append(&events);
    @memset(&names_buf, 'x');
    const metrics = try index.snapshot(arena.allocator());
    index.deinit();
    var found = false;
    for (metrics.tasks) |task| {
        if (task.pid == 1) {
            found = true;
            try std.testing.expectEqualStrings("worker", task.comm);
        }
    }
    try std.testing.expect(found);
}

// Checks the shared loss registry counts every kind, including retention gaps
// and segment corruption/truncation that the old substring scan missed.
test "metrics count every loss kind through the registry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var index = Index.init(allocator);
    defer index.deinit();
    const events = [_]event.RawEvent{
        .{ .kind = .marker, .detail = "sample_loss perf_ring lost=3" },
        .{ .kind = .marker, .detail = "sample_loss live_ui dropped=2 reason=trim" },
        .{ .kind = .marker, .detail = "retention_loss requested_from_wall_ns=1 oldest_wall_ns=2" },
        .{ .kind = .marker, .detail = "capture_corrupt_segment offset=0 dropped=1" },
        .{ .kind = .marker, .detail = "capture_truncated_tail missing_footer=1 dropped=1" },
        .{ .kind = .marker, .detail = "capture_truncated reason=max_events limit=5 dropped=1" },
        // Non-loss markers must not move the counters.
        .{ .kind = .marker, .detail = "capture_owner" },
        .{ .kind = .marker, .detail = "capture_start" },
        .{ .kind = .marker, .detail = "capture_interrupted previous_session=abc" },
    };
    try index.append(&events);
    const metrics = try index.snapshot(allocator);
    try std.testing.expectEqual(@as(u64, 9), metrics.lost);
    try std.testing.expectEqual(@as(u64, 5), metrics.loss_by_kind.get(.sample_loss));
    try std.testing.expectEqual(@as(u64, 1), metrics.loss_by_kind.get(.retention_loss));
    try std.testing.expectEqual(@as(u64, 1), metrics.loss_by_kind.get(.capture_corrupt_segment));
    try std.testing.expectEqual(@as(u64, 1), metrics.loss_by_kind.get(.capture_truncated_tail));
    try std.testing.expectEqual(@as(u64, 1), metrics.loss_by_kind.get(.capture_truncated));
    try std.testing.expectEqual(@as(u64, 0), metrics.loss_by_kind.get(.capture_missing_segment));
}

// Checks the additive causal fields are populated from the incremental pass:
// a blocked sleep is attributed to its prev_state cause, and a runnable
// switch-out followed by a switch-in without a wakeup is a preemption.
test "metrics attribute offcpu causes and preemptions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var index = Index.init(arena.allocator());
    defer index.deinit();
    const events = [_]event.RawEvent{
        .{ .kind = .sched_switch, .ts_ns = 1_000_000, .a = 2, .b = 1, .c = 0, .comm = "b" },
        .{ .kind = .sched_switch, .ts_ns = 2_000_000, .a = 1, .b = 2, .c = 1, .comm = "a" },
        .{ .kind = .sched_wakeup, .ts_ns = 2_500_000, .pid = 1, .a = 2, .comm = "b" },
        .{ .kind = .sched_switch, .ts_ns = 3_000_000, .a = 2, .b = 1, .c = 0, .comm = "b" },
        .{ .kind = .sched_switch, .ts_ns = 3_500_000, .a = 1, .b = 2, .c = 0, .comm = "a" },
    };
    try index.append(&events);
    const metrics = try index.snapshot(arena.allocator());
    try std.testing.expectEqual(@as(u64, 1), metrics.offcpu_samples);
    try std.testing.expectEqual(@as(u64, 1), metrics.causes[@backingInt(sched_state.Cause.interruptible)].count);
    try std.testing.expectEqual(@as(u64, 1_000), metrics.causes[@backingInt(sched_state.Cause.interruptible)].total_us);
    try std.testing.expectEqual(@as(u64, 2), metrics.preemptions);
    try std.testing.expectEqual(@as(u64, 2), metrics.preempt.count);
    try std.testing.expectEqual(@as(u64, 1), metrics.preempt_unresolved);
    try std.testing.expectEqual(@as(u64, 1), metrics.chain_count);
    try std.testing.expectEqual(@as(i32, 1), metrics.chains[0].root_pid);
    try std.testing.expectEqual(@as(u8, 2), metrics.chains[0].depth);
    try std.testing.expectEqual(@as(u64, 500), metrics.chains[0].total_wait_us);
    try std.testing.expectEqual(@as(u64, 1), metrics.chain_roots);
    var b_found = false;
    for (metrics.tasks) |task| {
        if (std.mem.eql(u8, task.comm, "b")) {
            b_found = true;
            try std.testing.expectEqual(@as(u64, 1), task.offcpu_by_reason[@backingInt(sched_state.Cause.interruptible)].count);
            try std.testing.expectEqual(@as(u64, 1_000), task.offcpu_by_reason[@backingInt(sched_state.Cause.interruptible)].total_us);
        }
        if (std.mem.eql(u8, task.comm, "a")) {
            // Two runnable switch-outs of task 1 were resumed without a wakeup.
            try std.testing.expectEqual(@as(u64, 2), task.preemptions);
            try std.testing.expect(task.preempt_p95_us != 0);
        }
    }
    try std.testing.expect(b_found);
}

// The raw tracepoint preemption marker (TASK_REPORT_MAX) must count as an
// involuntary preemption, never as an "other" off-CPU cause.
test "metrics normalize the kernel preemption marker" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var index = Index.init(arena.allocator());
    defer index.deinit();
    const events = [_]event.RawEvent{
        .{ .kind = .sched_switch, .ts_ns = 1_000_000, .a = 2, .b = 1, .c = sched_state.preempt_marker, .comm = "b" },
        .{ .kind = .sched_switch, .ts_ns = 2_000_000, .a = 1, .b = 2, .c = 1, .comm = "a" },
    };
    try index.append(&events);
    const metrics = try index.snapshot(arena.allocator());
    try std.testing.expectEqual(@as(u64, 1), metrics.preemptions);
    try std.testing.expectEqual(@as(u64, 0), metrics.causes[@backingInt(sched_state.Cause.other)].count);
    try std.testing.expectEqual(@as(u64, 0), metrics.offcpu_samples);
    var a_found = false;
    for (metrics.tasks) |task| {
        if (std.mem.eql(u8, task.comm, "a")) {
            a_found = true;
            try std.testing.expectEqual(@as(u64, 1), task.preemptions);
        }
    }
    try std.testing.expect(a_found);
}

// The incremental pass and the bounded second pass must agree on the same
// synthetic window; drift here would make `why` and `incident` disagree.
test "incremental metrics agree with the second-pass latency analysis" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var index = Index.init(allocator);
    defer index.deinit();
    const events = [_]event.RawEvent{
        .{ .kind = .sched_switch, .ts_ns = 1_000_000, .a = 2, .b = 1, .c = 0, .comm = "b" },
        .{ .kind = .sched_switch, .ts_ns = 2_000_000, .a = 1, .b = 2, .c = 1, .comm = "a" },
        .{ .kind = .sched_wakeup, .ts_ns = 2_500_000, .pid = 1, .a = 2, .comm = "b" },
        .{ .kind = .sched_switch, .ts_ns = 3_000_000, .a = 2, .b = 1, .c = 0, .comm = "b" },
        .{ .kind = .sched_switch, .ts_ns = 3_500_000, .a = 1, .b = 2, .c = 0, .comm = "a" },
    };
    try index.append(&events);
    const metrics = try index.snapshot(allocator);
    const analysis = try latency.analyze(allocator, &events);
    try std.testing.expectEqual(metrics.offcpu_samples, analysis.offcpu_samples);
    try std.testing.expectEqual(metrics.preemptions, analysis.preemptions);
    try std.testing.expectEqual(metrics.offcpu_unresolved, analysis.offcpu_unresolved);
    try std.testing.expectEqual(metrics.preempt_unresolved, analysis.preempt_unresolved);
    for (analysis.causes, metrics.causes) |left, right| {
        try std.testing.expectEqual(right.count, left.count);
        try std.testing.expectEqual(right.total_us, left.total_us);
    }
    try std.testing.expectEqual(metrics.chain_count, @as(u8, @intCast(analysis.chains.len)));
}

// A sleep that never resolves is counted as unresolved: its duration is
// unknown and must not be rendered as a zero-length off-CPU sample.
test "metrics count unresolved sleeps without inventing a duration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var index = Index.init(arena.allocator());
    defer index.deinit();
    const events = [_]event.RawEvent{
        .{ .kind = .sched_switch, .ts_ns = 1_000, .a = 1, .b = 7, .c = 1, .comm = "a" },
    };
    try index.append(&events);
    const metrics = try index.snapshot(arena.allocator());
    try std.testing.expectEqual(@as(u64, 0), metrics.offcpu_samples);
    try std.testing.expectEqual(@as(u64, 1), metrics.offcpu_unresolved);
}

// Pull the causal modules' unit tests into the test graph: root.zig only
// references `metrics`, so the imported modules must be reachable from here.
test {
    _ = sched_state;
    _ = latency;
}
