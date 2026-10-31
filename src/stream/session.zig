//! Replay session model: bounded event list, per-CPU switch slices, capability
//! rows, top tasks, and fail-closed counters for the profiler UI.

const std = @import("std");
const event = @import("../core/event.zig");
const journal = @import("journal.zig");
const aggregates = @import("../analyze/aggregates.zig");

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
        session.first_us = events[0].ts_ns / 1000;
        session.last_us = session.first_us;

        var comm_counts = std.StringHashMap(u32).init(allocator);
        defer comm_counts.deinit();
        var cap_names = std.StringHashMap(usize).init(allocator);
        defer cap_names.deinit();
        var caps: std.ArrayList(Capability) = .empty;

        for (events) |e| {
            const us = e.ts_ns / 1000;
            session.last_us = @max(session.last_us, us);
            session.first_us = @min(session.first_us, us);
            switch (e.kind) {
                .sched_switch => {
                    session.switches += 1;
                    if (e.cpu >= 0) {
                        const cpu: u8 = @intCast(@min(e.cpu, 255));
                        session.cpu_count = @max(session.cpu_count, cpu + 1);
                    }
                    if (e.comm.len != 0) {
                        const entry = try comm_counts.getOrPut(e.comm);
                        if (!entry.found_existing) entry.value_ptr.* = 0;
                        entry.value_ptr.* += 1;
                    }
                },
                .sched_wakeup => session.wakeups += 1,
                .sched_migrate => session.migrations += 1,
                .page_fault => session.faults += 1,
                .marker => {
                    if (std.mem.indexOf(u8, e.detail, "sample_loss") != null or
                        std.mem.indexOf(u8, e.detail, "lost") != null)
                    {
                        session.lost += 1;
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
        return session;
    }

    pub fn durationUs(self: Session) u64 {
        return self.last_us -| self.first_us;
    }

    pub fn aggregate(self: Session) aggregates.Aggregates {
        return .{
            .migrations = self.migrations,
            .wakeups = self.wakeups,
            .page_faults = self.faults,
            .llc_domains = @max(1, @as(i32, self.cpu_count)),
            .sched_collected = self.switches > 0,
            .pmu_collected = false,
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
    try std.testing.expect(session.lost == 1);
    try std.testing.expect(session.refusals == 0);
    try std.testing.expect(session.cpu_count == 4);
    try std.testing.expect(session.top_comms.len > 0);
    try std.testing.expect(session.aggregate().sched_collected);
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
    var reader = file.reader(std.testing.io, &buffer);
    const data = try reader.interface.allocRemaining(arena.allocator(), .limited(2 * 1024 * 1024));
    const session = try Session.fromData(arena.allocator(), "web replay", data);
    try std.testing.expectEqual(@as(usize, 1444), session.events.len);
    try std.testing.expectEqual(@as(u32, 0), session.refusals);
    try std.testing.expectEqual(@as(u32, 1), session.lost);
}
