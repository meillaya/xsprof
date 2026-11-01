//! Replay session model: bounded event list, per-CPU switch slices, capability
//! rows, top tasks, and fail-closed counters for the profiler UI.

const std = @import("std");
const event = @import("../core/event.zig");
const journal = @import("journal.zig");
const session_meta = @import("../core/session_meta.zig");
const aggregates = @import("../analyze/aggregates.zig");
const metrics_mod = @import("../analyze/metrics.zig");

pub const Slice = struct {
    start_us: u64,
    end_us: u64,
    cpu: u8,
    pid: i32,
    comm: []const u8,
};

pub const Capability = struct {
    name: []const u8,
    state: []const u8,
    reason: []const u8,
};

pub const CommCount = struct {
    comm: []const u8,
    count: u32,
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    events: []const event.RawEvent,
    slices: []const Slice,
    capabilities: []const Capability,
    top_comms: []const CommCount,
    first_us: u64 = 0,
    last_us: u64 = 0,
    switches: u32 = 0,
    wakeups: u32 = 0,
    migrations: u32 = 0,
    faults: u32 = 0,
    lost: u32 = 0,
    refusals: u32 = 0,
    cpu_count: u8 = 1,
    metrics: metrics_mod.Metrics = .{},
    meta: session_meta.Meta = .{},
    self_switches: u32 = 0,
    self_migrations: u32 = 0,
    cross_llc_migrations: u32 = 0,

    pub fn load(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !Session {
        const events = try journal.read(io, allocator, path);
        return build(allocator, path, events);
    }

    pub fn fromData(allocator: std.mem.Allocator, source: []const u8, data: []const u8) !Session {
        const events = try journal.parseData(allocator, data);
        return build(allocator, source, events);
    }

    fn parseCapability(detail: []const u8) ?Capability {
        const first = std.mem.indexOfScalar(u8, detail, ':') orelse return null;
        const second_rel = std.mem.indexOfScalar(u8, detail[first + 1 ..], ':') orelse return null;
        const second = first + 1 + second_rel;
        return .{
            .name = detail[0..first],
            .state = detail[first + 1 .. second],
            .reason = detail[second + 1 ..],
        };
    }

    fn build(
        allocator: std.mem.Allocator,
        source: []const u8,
        events: []const event.RawEvent,
    ) !Session {
        var session: Session = .{
            .allocator = allocator,
            .source = source,
            .events = events,
            .slices = &.{},
            .capabilities = &.{},
            .top_comms = &.{},
        };
        if (events.len == 0) return session;
        for (events) |e| session.meta.apply(e);
        session.first_us = std.math.maxInt(u64);
        session.last_us = 0;
        var timed_events: usize = 0;

        var comm_counts = std.StringHashMap(u32).init(allocator);
        defer comm_counts.deinit();
        var cap_names = std.StringHashMap(usize).init(allocator);
        defer cap_names.deinit();
        var caps: std.ArrayList(Capability) = .empty;

        for (events) |e| {
            if (!session_meta.isMetadata(e)) {
                const us = e.ts_ns / 1000;
                session.last_us = @max(session.last_us, us);
                session.first_us = @min(session.first_us, us);
                timed_events += 1;
            }
            switch (e.kind) {
                .sched_switch => {
                    session.switches += 1;
                    const incoming: i32 = @intCast(@min(e.a, std.math.maxInt(i32)));
                    const is_self = session.meta.isSelf(incoming, e.comm);
                    if (is_self) session.self_switches += 1;
                    if (e.cpu >= 0) {
                        const cpu: u8 = @intCast(@min(e.cpu, 255));
                        session.cpu_count = @max(session.cpu_count, cpu + 1);
                    }
                    if (e.comm.len != 0 and !is_self) {
                        const entry = try comm_counts.getOrPut(e.comm);
                        if (!entry.found_existing) entry.value_ptr.* = 0;
                        entry.value_ptr.* += 1;
                    }
                },
                .sched_wakeup => session.wakeups += 1,
                .sched_migrate => {
                    session.migrations += 1;
                    const migrating: i32 = e.pid;
                    if (session.meta.isSelf(migrating, e.comm)) {
                        session.self_migrations += 1;
                    } else if (session.meta.llcOf(@intCast(@min(e.a, std.math.maxInt(i32))))) |orig| {
                        if (session.meta.llcOf(@intCast(@min(e.b, std.math.maxInt(i32))))) |dest| {
                            if (orig != dest) session.cross_llc_migrations += 1;
                        }
                    }
                },
                .page_fault => session.faults += 1,
                .marker => {
                    if (std.mem.indexOf(u8, e.detail, "sample_loss") != null or
                        std.mem.indexOf(u8, e.detail, "lost") != null)
                    {
                        session.lost += event.lossMagnitude(e.detail);
                    }
                },
                .refusal, .incident => session.refusals += 1,
                .capability => {
                    if (parseCapability(e.detail)) |cap| {
                        if (cap_names.get(cap.name)) |index| {
                            caps.items[index] = cap;
                        } else {
                            try cap_names.put(cap.name, caps.items.len);
                            try caps.append(allocator, cap);
                        }
                    }
                },
                else => {},
            }
        }
        if (timed_events == 0) {
            session.first_us = 0;
            session.last_us = 0;
        }
        session.capabilities = try caps.toOwnedSlice(allocator);

        var top: std.ArrayList(CommCount) = .empty;
        var it = comm_counts.iterator();
        while (it.next()) |entry| {
            try top.append(allocator, .{
                .comm = entry.key_ptr.*,
                .count = entry.value_ptr.*,
            });
        }
        std.mem.sortUnstable(CommCount, top.items, {}, struct {
            fn less(_: void, a: CommCount, b: CommCount) bool {
                if (a.count != b.count) return a.count > b.count;
                return std.mem.order(u8, a.comm, b.comm) == .lt;
            }
        }.less);
        session.top_comms = try top.toOwnedSlice(allocator);

        var slices: std.ArrayList(Slice) = .empty;
        var next_switch = std.AutoHashMap(i32, u64).init(allocator);
        defer next_switch.deinit();
        var i = events.len;
        while (i > 0) {
            i -= 1;
            const e = events[i];
            if (e.kind != .sched_switch) continue;
            if (next_switch.get(e.cpu)) |end_ns| {
                if (end_ns > e.ts_ns) {
                    try slices.append(allocator, .{
                        .start_us = e.ts_ns / 1000,
                        .end_us = end_ns / 1000,
                        .cpu = @intCast(@min(@max(e.cpu, 0), 255)),
                        .pid = @intCast(@min(e.a, std.math.maxInt(i32))),
                        .comm = e.comm,
                    });
                }
            }
            try next_switch.put(e.cpu, e.ts_ns);
        }
        std.mem.sortUnstable(Slice, slices.items, {}, struct {
            fn less(_: void, a: Slice, b: Slice) bool {
                if (a.start_us != b.start_us) return a.start_us < b.start_us;
                return a.cpu < b.cpu;
            }
        }.less);
        session.slices = try slices.toOwnedSlice(allocator);

        var metrics_index = metrics_mod.Index.init(allocator);
        defer metrics_index.deinit();
        metrics_index.setSelf(&session.meta);
        try metrics_index.append(events);
        session.metrics = try metrics_index.snapshot(allocator);
        return session;
    }

    pub fn durationUs(self: Session) u64 {
        return self.last_us -| self.first_us;
    }

    pub fn aggregate(self: Session) aggregates.Aggregates {
        const switches = self.switches -| self.self_switches;
        const wakeups = self.metrics.wakeups -| self.metrics.self_wakeups;
        const migrations = self.migrations -| self.self_migrations;
        const topology = self.meta.topologyComplete(self.cpu_count);
        return .{
            .migrations = @intCast(migrations),
            .wakeups = @intCast(wakeups),
            .self_wakeups = @intCast(self.metrics.self_wakeups),
            .unnecessary_wakeups = @intCast(self.metrics.unnecessary_wakeups),
            .unresolved_wakeups = @intCast(self.metrics.unresolved_wakeups),
            .page_faults = self.faults,
            .cross_llc_migration = self.cross_llc_migrations > 0,
            .llc_domains = if (topology) self.meta.llcDomainCount() else 1,
            .buddy_fragmentation = self.meta.buddy_fragmentation,
            .sched_collected = switches > 0,
            .pmu_collected = false,
            .signals = .{
                .sched_switch = switches > 0,
                .sched_wakeup = wakeups > 0,
                .sched_migrate = migrations > 0,
                .page_fault = self.faults > 0,
                .cpu_topology = topology,
                .allocator = self.meta.buddy_sampled,
            },
        };
    }
};

test "healthy fixture builds slices, capabilities, and loss" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const session = try Session.load(
        std.testing.io,
        arena.allocator(),
        "fixtures/ui/healthy.ndjson",
    );
    try std.testing.expect(session.events.len > 1000);
    try std.testing.expect(session.switches > 100);
    try std.testing.expect(session.slices.len > 100);
    try std.testing.expect(session.capabilities.len == 3);
    try std.testing.expectEqualStrings("SKIP", session.capabilities[2].state);
    try std.testing.expect(session.lost == 3);
    try std.testing.expect(session.refusals == 0);
    try std.testing.expect(session.cpu_count == 4);
    try std.testing.expect(session.top_comms.len > 0);
    const agg = session.aggregate();
    try std.testing.expect(agg.sched_collected);
    try std.testing.expectEqual(@as(i64, 329), agg.wakeups);
    try std.testing.expectEqual(@as(i64, 0), agg.self_wakeups);
    try std.testing.expectEqual(@as(i64, 329), agg.unnecessary_wakeups);
    try std.testing.expect(agg.signals.sched_wakeup);
    try std.testing.expect(!agg.signals.cpu_topology);
    try std.testing.expect(!agg.signals.allocator);
}

test "empty fixture stays empty and fail-closed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const session = try Session.load(
        std.testing.io,
        arena.allocator(),
        "fixtures/ui/empty.ndjson",
    );
    try std.testing.expectEqual(@as(usize, 1), session.events.len);
    try std.testing.expectEqual(@as(usize, 0), session.slices.len);
    try std.testing.expectEqual(@as(usize, 0), session.capabilities.len);
    try std.testing.expect(!session.aggregate().sched_collected);
}

test "fromData matches file load counts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const file = try std.Io.Dir.cwd().openFile(
        std.testing.io,
        "fixtures/ui/healthy.ndjson",
        .{},
    );
    defer file.close(std.testing.io);
    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.readerStreaming(std.testing.io, &buffer);
    const data = try reader.interface.allocRemaining(arena.allocator(), .limited(2 * 1024 * 1024));
    const session = try Session.fromData(arena.allocator(), "web replay", data);
    try std.testing.expectEqual(@as(usize, 1444), session.events.len);
    try std.testing.expectEqual(@as(u32, 0), session.refusals);
    try std.testing.expectEqual(@as(u32, 3), session.lost);
}

test "real workload fixture builds multi-CPU slices" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const session = try Session.load(
        std.testing.io,
        arena.allocator(),
        "fixtures/real/scheduler-mix.ndjson",
    );
    try std.testing.expectEqual(@as(usize, 12000), session.events.len);
    try std.testing.expectEqual(@as(u8, 4), session.cpu_count);
    try std.testing.expectEqual(@as(u32, 4574), session.switches);
    try std.testing.expectEqual(@as(u32, 40), session.migrations);
    try std.testing.expectEqual(@as(u32, 0), session.lost);
    try std.testing.expect(session.slices.len > 1000);
    try std.testing.expect(session.metrics.tasks.len > 8);
    try std.testing.expectEqual(@as(u32, 2153), session.self_switches);
    const agg = session.aggregate();
    try std.testing.expectEqual(@as(i64, 133), agg.wakeups);
    try std.testing.expectEqual(@as(i64, 73), agg.self_wakeups);
    try std.testing.expectEqual(@as(i64, 40), agg.unnecessary_wakeups);
    try std.testing.expectEqual(@as(i64, 7), agg.unresolved_wakeups);
}

test "real metadata fixture records buddyinfo and the recorder pid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const session = try Session.load(
        std.testing.io,
        arena.allocator(),
        "fixtures/real/vm-fragmented.ndjson",
    );
    try std.testing.expectEqual(@as(usize, 12000), session.events.len);
    try std.testing.expect(session.meta.self_seen);
    try std.testing.expect(session.meta.self_pid > 0);
    try std.testing.expect(session.self_switches > 0);
    try std.testing.expect(session.meta.buddy_sampled);
    const agg = session.aggregate();
    try std.testing.expect(agg.signals.allocator);
    try std.testing.expectApproxEqAbs(@as(f64, 0.614654), agg.buddy_fragmentation, 0.000001);
}
