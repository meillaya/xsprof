//! Data model shared by the console shell and screens. The demo model is
//! parsed from the prototype's extracted session; production models are built
//! from Session/Metrics/Advisor by derive.zig.

const std = @import("std");

pub const Mode = enum { intervals, ticks };

pub const Meta = struct {
    host: []const u8 = "",
    kernel: []const u8 = "",
    arch: []const u8 = "",
    source: []const u8 = "REPLAY",
    fixture: []const u8 = "",
    startedAt: i64 = 0,
    excerpt: []const u8 = "",
    captureWindow: []const u8 = "",
    sessionLabel: []const u8 = "",
    captureStart: []const u8 = "",
    captureEnd: []const u8 = "",
    manifest: []const u8 = "",
};

pub const Summary = struct {
    events: u32 = 0,
    switches: u32 = 0,
    migrations: u32 = 0,
    wakeups: u32 = 0,
    faults: u32 = 0,
    lost: u32 = 0,
    cpus: u8 = 0,
    p95: ?f64 = null,
    p99: ?f64 = null,
    cpuBusy: ?u8 = null,
    runqueue: ?f64 = null,
    windowMs: f64 = 0,
    switchRate: f64 = 0,
};

pub const Capability = struct {
    name: []const u8,
    state: []const u8,
    detail: []const u8,
    glyph: []const u8 = "",
};

pub const CpuStat = struct {
    cpu: u8,
    busy: u8,
    switches: u32 = 0,
    migrations: u32 = 0,
    runqueue: ?f64 = null,
    p95: ?f64 = null,
    buckets: []const f64 = &.{},
};

pub const Slice = struct {
    id: u32 = 0,
    cpu: u8,
    comm: []const u8,
    pid: i32,
    lane: u8,
    start: f64,
    dur: f64,
    prev: []const u8 = "",
};

pub const Event = struct {
    id: u32 = 0,
    ts: f64,
    type: []const u8,
    cpu: i32,
    comm: []const u8,
    pid: i32,
    dur: ?f64 = null,
    sliceId: ?u32 = null,
    detail: []const u8 = "",
    fields: []const []const []const u8 = &.{},
    loss: bool = false,
};

pub const Thread = struct {
    comm: []const u8,
    pid: i32,
    switches: u32,
    migrations: u32,
    p95: ?f64,
    lane: u8,
    share: f64,
};

pub const Focus = struct {
    from: f64,
    to: f64,
    cpu: i32 = -1,
};

pub const AdvisorCard = struct {
    id: []const u8,
    severity: []const u8,
    confidence: ?f64 = null,
    summary: []const u8 = "",
    evidence: []const []const u8 = &.{},
    recommendation: []const u8 = "",
    focus: ?Focus = null,
};

pub const Memory = struct {
    pageFaults: u64 = 0,
    cacheMiss: f64 = 0,
    reclaims: u64 = 0,
    reclaimMax: f64 = 0,
    cross: f64 = 0,
    numa: []const u8 = "",
    has_llc: bool = true,
    has_reclaim: bool = true,
    has_cross: bool = true,
};

pub const TypeCount = struct {
    kind: []const u8,
    count: u32,
};

pub const Segment = struct {
    name: []const u8,
    bytes: []const u8,
    window: []const u8,
    open: bool = false,
    loss: u32 = 0,
};

pub const Retention = struct {
    budget: []const u8,
    used: []const u8,
    usedPct: u8,
    age: []const u8 = "",
    excerpt: []const u8 = "",
};

pub const Model = struct {
    schema: []const u8 = "xsprof/design-demo/v1",
    meta: Meta = .{},
    mode: Mode = .intervals,
    summary: Summary = .{},
    capabilities: []const Capability = &.{},
    cpuStats: []const CpuStat = &.{},
    threads: []const Thread = &.{},
    advisor: []const AdvisorCard = &.{},
    memory: ?Memory = null,
    typeCounts: []const TypeCount = &.{},
    lostAt: []const f64 = &.{},
    windowMs: f64 = 13970,
    segments: []const Segment = &.{},
    retention: ?Retention = null,
    slices: []const Slice = &.{},
    events: []const Event = &.{},
    demo: bool = true,

    pub fn eventCount(self: *const Model) usize {
        return self.events.len;
    }

    pub fn sliceCount(self: *const Model) usize {
        return self.slices.len;
    }
};

pub fn parse(allocator: std.mem.Allocator, data: []const u8) !Model {
    const model = try std.json.parseFromSliceLeaky(Model, allocator, data, .{
        .ignore_unknown_fields = true,
    });
    if (!std.mem.eql(u8, model.schema, "xsprof/design-demo/v1")) return error.InvalidDemoModel;
    if (model.events.len > 200_000 or model.slices.len > 200_000) return error.InvalidDemoModel;
    return model;
}

pub fn loadDemo(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !Model {
    const file = if (path.len != 0 and path[0] == '/')
        try std.Io.Dir.openFileAbsolute(io, path, .{})
    else
        try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    const data = try reader.interface.allocRemaining(allocator, .limited(8 * 1024 * 1024));
    return parse(allocator, data);
}

test "demo model parses with all screens populated" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const model = try loadDemo(std.testing.io, arena.allocator(), "fixtures/ui/design/demo.json");
    try std.testing.expect(model.events.len > 1000);
    try std.testing.expect(model.slices.len > 100);
    try std.testing.expectEqual(@as(usize, 7), model.capabilities.len);
    try std.testing.expectEqual(@as(usize, 4), model.cpuStats.len);
    try std.testing.expectEqual(@as(usize, 7), model.advisor.len);
    try std.testing.expect(model.segments.len == 6);
    try std.testing.expect(model.retention != null);
}
