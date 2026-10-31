//! Incremental session index. `append` is O(new events); `snapshot` returns
//! the existing immutable-style Session view without re-reading history.

const std = @import("std");
const event = @import("../core/event.zig");
const session = @import("session.zig");

const Slice = session.Slice;
const Capability = session.Capability;
const CommCount = session.CommCount;

const max_cpus = 256;

const Switch = struct {
    ts_ns: u64,
    pid: u64,
    comm: []const u8,
};

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

pub const Index = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayList(event.RawEvent) = .empty,
    slices: std.ArrayList(Slice) = .empty,
    capabilities: std.ArrayList(Capability) = .empty,
    cap_names: std.StringHashMap(usize),
    comm_counts: std.StringHashMap(u32),
    last_switch: [max_cpus]?Switch = @splat(null),
    first_us: u64 = std.math.maxInt(u64),
    last_us: u64 = 0,
    switches: u32 = 0,
    wakeups: u32 = 0,
    migrations: u32 = 0,
    faults: u32 = 0,
    lost: u32 = 0,
    refusals: u32 = 0,
    cpu_count: u8 = 1,
    out_of_order: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) Index {
        return .{
            .allocator = allocator,
            .cap_names = std.StringHashMap(usize).init(allocator),
            .comm_counts = std.StringHashMap(u32).init(allocator),
        };
    }

    pub fn deinit(self: *Index) void {
        self.events.deinit(self.allocator);
        self.slices.deinit(self.allocator);
        self.capabilities.deinit(self.allocator);
        self.cap_names.deinit();
        self.comm_counts.deinit();
    }

    pub fn append(self: *Index, new_events: []const event.RawEvent) !void {
        try self.events.appendSlice(self.allocator, new_events);
        for (new_events) |e| {
            const us = e.ts_ns / 1000;
            self.last_us = @max(self.last_us, us);
            self.first_us = @min(self.first_us, us);
            switch (e.kind) {
                .sched_switch => {
                    self.switches += 1;
                    if (e.cpu >= 0) {
                        const cpu: u8 = @intCast(@min(e.cpu, max_cpus - 1));
                        const next_cpu: u8 = @intCast(@min(e.cpu + 1, max_cpus - 1));
                        self.cpu_count = @max(self.cpu_count, next_cpu);
                        const index: usize = cpu;
                        if (self.last_switch[index]) |previous| {
                            if (e.ts_ns > previous.ts_ns) {
                                try self.slices.append(self.allocator, .{
                                    .start_us = previous.ts_ns / 1000,
                                    .end_us = e.ts_ns / 1000,
                                    .cpu = cpu,
                                    .pid = @intCast(@min(previous.pid, std.math.maxInt(i32))),
                                    .comm = previous.comm,
                                });
                            } else {
                                self.out_of_order += 1;
                            }
                        }
                        self.last_switch[index] = .{
                            .ts_ns = e.ts_ns,
                            .pid = e.a,
                            .comm = e.comm,
                        };
                    }
                    if (e.comm.len != 0) {
                        const entry = try self.comm_counts.getOrPut(e.comm);
                        if (!entry.found_existing) entry.value_ptr.* = 0;
                        entry.value_ptr.* += 1;
                    }
                },
                .sched_wakeup => self.wakeups += 1,
                .sched_migrate => self.migrations += 1,
                .page_fault => self.faults += 1,
                .marker => {
                    if (std.mem.indexOf(u8, e.detail, "sample_loss") != null or
                        std.mem.indexOf(u8, e.detail, "lost") != null)
                    {
                        self.lost += 1;
                    }
                },
                .refusal, .incident => self.refusals += 1,
                .capability => {
                    if (parseCapability(e.detail)) |cap| {
                        if (self.cap_names.get(cap.name)) |index| {
                            self.capabilities.items[index] = cap;
                        } else {
                            try self.cap_names.put(cap.name, self.capabilities.items.len);
                            try self.capabilities.append(self.allocator, cap);
                        }
                    }
                },
                else => {},
            }
        }
    }

    pub fn snapshot(self: *Index, allocator: std.mem.Allocator, source: []const u8) !session.Session {
        std.mem.sortUnstable(Slice, self.slices.items, {}, struct {
            fn less(_: void, a: Slice, b: Slice) bool {
                if (a.start_us != b.start_us) return a.start_us < b.start_us;
                return a.cpu < b.cpu;
            }
        }.less);
        var top: std.ArrayList(CommCount) = .empty;
        errdefer top.deinit(allocator);
        var it = self.comm_counts.iterator();
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
        const top_slice = try top.toOwnedSlice(allocator);
        return .{
            .allocator = allocator,
            .source = source,
            .events = self.events.items,
            .slices = self.slices.items,
            .capabilities = self.capabilities.items,
            .top_comms = top_slice,
            .first_us = if (self.events.items.len == 0) 0 else self.first_us,
            .last_us = if (self.events.items.len == 0) 0 else self.last_us,
            .switches = self.switches,
            .wakeups = self.wakeups,
            .migrations = self.migrations,
            .faults = self.faults,
            .lost = self.lost,
            .refusals = self.refusals,
            .cpu_count = self.cpu_count,
        };
    }
};

// Checks that incremental appends produce the same counters, slices, top
// tasks, and capabilities as a full Session build over the healthy fixture.
test "incremental index matches full build on the healthy fixture" {
    const journal = @import("journal.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const data = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "fixtures/ui/healthy.ndjson",
        arena.allocator(),
        .limited(32 * 1024 * 1024),
    );
    const expected = try session.Session.fromData(arena.allocator(), "fixture", data);
    const events = try journal.parseData(arena.allocator(), data);
    var index = Index.init(arena.allocator());
    defer index.deinit();
    try index.append(events);
    const actual = try index.snapshot(arena.allocator(), "fixture");

    try std.testing.expectEqual(expected.events.len, actual.events.len);
    try std.testing.expectEqual(expected.first_us, actual.first_us);
    try std.testing.expectEqual(expected.last_us, actual.last_us);
    try std.testing.expectEqual(expected.switches, actual.switches);
    try std.testing.expectEqual(expected.wakeups, actual.wakeups);
    try std.testing.expectEqual(expected.migrations, actual.migrations);
    try std.testing.expectEqual(expected.faults, actual.faults);
    try std.testing.expectEqual(expected.lost, actual.lost);
    try std.testing.expectEqual(expected.refusals, actual.refusals);
    try std.testing.expectEqual(expected.cpu_count, actual.cpu_count);
    try std.testing.expectEqual(expected.slices.len, actual.slices.len);
    for (expected.slices, actual.slices) |a, b| {
        try std.testing.expectEqual(a.start_us, b.start_us);
        try std.testing.expectEqual(a.end_us, b.end_us);
        try std.testing.expectEqual(a.cpu, b.cpu);
        try std.testing.expectEqual(a.pid, b.pid);
        try std.testing.expectEqualStrings(a.comm, b.comm);
    }
    try std.testing.expectEqual(expected.capabilities.len, actual.capabilities.len);
    try std.testing.expectEqual(expected.top_comms.len, actual.top_comms.len);
    for (expected.top_comms, actual.top_comms) |a, b| {
        try std.testing.expectEqualStrings(a.comm, b.comm);
        try std.testing.expectEqual(a.count, b.count);
    }
}
