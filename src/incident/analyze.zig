//! Bounded-memory analysis of an extracted window. The window file is read
//! line by line; only per-task metrics, capabilities, and a trace prefix stay
//! resident.

const std = @import("std");
const event = @import("../core/event.zig");
const session_meta = @import("../core/session_meta.zig");
const session_mod = @import("../stream/session.zig");
const metrics_mod = @import("../analyze/metrics.zig");

pub const Options = struct {
    max_trace_events: usize = 200_000,
};

pub const Result = struct {
    session: session_mod.Session,
    event_count: usize,
    trace_events: []const event.RawEvent,
    trace_truncated: bool,
    retention_trimmed: bool,
};

fn openFile(io: std.Io, path: []const u8) !std.Io.File {
    if (path.len != 0 and path[0] == '/') {
        return std.Io.Dir.openFileAbsolute(io, path, .{});
    }
    return std.Io.Dir.cwd().openFile(io, path, .{});
}

fn copyEvent(allocator: std.mem.Allocator, source: event.RawEvent) !event.RawEvent {
    var copy = source;
    if (source.comm.len != 0) copy.comm = try allocator.dupe(u8, source.comm);
    if (source.detail.len != 0) copy.detail = try allocator.dupe(u8, source.detail);
    return copy;
}

fn parseCapability(detail: []const u8) ?session_mod.Capability {
    const first = std.mem.indexOfScalar(u8, detail, ':') orelse return null;
    const second_rel = std.mem.indexOfScalar(u8, detail[first + 1 ..], ':') orelse return null;
    const second = first + 1 + second_rel;
    return .{
        .name = detail[0..first],
        .state = detail[first + 1 .. second],
        .reason = detail[second + 1 ..],
    };
}

pub fn analyzeFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    opts: Options,
) !Result {
    const file = try openFile(io, path);
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);

    var meta: session_meta.Meta = .{};
    var metrics_index = metrics_mod.Index.init(allocator);
    defer metrics_index.deinit();

    var capabilities: std.ArrayList(session_mod.Capability) = .empty;
    var trace: std.ArrayList(event.RawEvent) = .empty;
    var line_arena = std.heap.ArenaAllocator.init(allocator);
    defer line_arena.deinit();

    var event_count: usize = 0;
    var switches: u32 = 0;
    var wakeups: u32 = 0;
    var migrations: u32 = 0;
    var faults: u32 = 0;
    var lost: u32 = 0;
    var refusals: u32 = 0;
    var cpu_count: u8 = 1;
    var self_switches: u32 = 0;
    var self_migrations: u32 = 0;
    var cross_llc: u32 = 0;
    var first_us: ?u64 = null;
    var last_us: u64 = 0;
    var retention_trimmed = false;

    while (try reader.interface.takeDelimiter('\n')) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        _ = line_arena.reset(.retain_capacity);
        const entry = event.parseJson(line_arena.allocator(), line) catch continue;
        event_count += 1;
        if (trace.items.len < opts.max_trace_events) {
            try trace.append(allocator, try copyEvent(allocator, entry));
        }

        meta.apply(entry);
        try metrics_index.append(&.{entry});

        if (!session_meta.isMetadata(entry)) {
            const us = entry.ts_ns / 1000;
            if (first_us == null or us < first_us.?) first_us = us;
            last_us = @max(last_us, us);
        }
        switch (entry.kind) {
            .sched_switch => {
                switches += 1;
                if (entry.cpu >= 0) {
                    const cpu: u8 = @intCast(@min(entry.cpu, 255));
                    cpu_count = @max(cpu_count, cpu + 1);
                }
                const incoming: i32 = @intCast(@min(entry.a, std.math.maxInt(i32)));
                if (meta.isSelf(incoming, entry.comm)) self_switches += 1;
            },
            .sched_wakeup => wakeups += 1,
            .sched_migrate => {
                migrations += 1;
                const migrating: i32 = entry.pid;
                if (meta.isSelf(migrating, entry.comm)) {
                    self_migrations += 1;
                } else if (meta.llcOf(@intCast(@min(entry.a, std.math.maxInt(i32))))) |orig| {
                    if (meta.llcOf(@intCast(@min(entry.b, std.math.maxInt(i32))))) |dest| {
                        if (orig != dest) cross_llc += 1;
                    }
                }
            },
            .page_fault => faults += 1,
            .refusal, .incident => refusals += 1,
            .capability => {
                const cap = parseCapability(entry.detail) orelse continue;
                try capabilities.append(allocator, .{
                    .name = try allocator.dupe(u8, cap.name),
                    .state = try allocator.dupe(u8, cap.state),
                    .reason = try allocator.dupe(u8, cap.reason),
                });
            },
            .marker => {
                if (std.mem.indexOf(u8, entry.detail, "retention_loss") != null) {
                    retention_trimmed = true;
                }
                if (std.mem.indexOf(u8, entry.detail, "sample_loss") != null or
                    std.mem.indexOf(u8, entry.detail, "lost") != null)
                {
                    lost += event.lossMagnitude(entry.detail);
                }
            },
            else => {},
        }
    }

    const metrics = try metrics_index.snapshot(allocator);
    const session = session_mod.Session{
        .allocator = allocator,
        .source = "incident window",
        .events = &.{},
        .slices = &.{},
        .capabilities = try capabilities.toOwnedSlice(allocator),
        .top_comms = &.{},
        .first_us = first_us orelse 0,
        .last_us = if (first_us == null) 0 else last_us,
        .switches = switches,
        .wakeups = wakeups,
        .migrations = migrations,
        .faults = faults,
        .lost = lost,
        .refusals = refusals,
        .cpu_count = cpu_count,
        .metrics = metrics,
        .meta = meta,
        .self_switches = self_switches,
        .self_migrations = self_migrations,
        .cross_llc_migrations = cross_llc,
    };
    const trace_count = trace.items.len;
    return .{
        .session = session,
        .event_count = event_count,
        .trace_events = try trace.toOwnedSlice(allocator),
        .trace_truncated = event_count > trace_count,
        .retention_trimmed = retention_trimmed,
    };
}

test "streamed analysis keeps counters and a trace prefix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const path = try std.fmt.allocPrint(allocator, "/tmp/xsprof-analyze-{d}.ndjson", .{std.testing.random_seed});
    const body =
        "{\"schema\":\"xsprof/event/v1\",\"event\":\"marker\",\"ts_ns\":0,\"cpu\":-1,\"pid\":7,\"tid\":7,\"comm\":\"xsprof\",\"detail\":\"capture_owner\",\"host_mutation\":false}\n" ++
        "{\"schema\":\"xsprof/event/v1\",\"event\":\"sched_switch\",\"ts_ns\":100,\"cpu\":0,\"pid\":7,\"tid\":7,\"a\":9,\"b\":0,\"c\":0,\"comm\":\"worker\",\"host_mutation\":false}\n" ++
        "{\"schema\":\"xsprof/event/v1\",\"event\":\"sched_wakeup\",\"ts_ns\":200,\"cpu\":0,\"pid\":7,\"tid\":7,\"a\":9,\"comm\":\"worker\",\"host_mutation\":false}\n";
    {
        const file = try std.Io.Dir.createFileAbsolute(std.testing.io, path, .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, body);
    }
    const result = try analyzeFile(std.testing.io, allocator, path, .{});
    try std.testing.expectEqual(@as(usize, 3), result.event_count);
    try std.testing.expectEqual(@as(usize, 3), result.trace_events.len);
    try std.testing.expect(!result.trace_truncated);
    const truncated = try analyzeFile(std.testing.io, allocator, path, .{ .max_trace_events = 1 });
    try std.testing.expectEqual(@as(usize, 3), truncated.event_count);
    try std.testing.expectEqual(@as(usize, 1), truncated.trace_events.len);
    try std.testing.expect(truncated.trace_truncated);
    try std.testing.expectEqual(@as(u32, 1), result.session.switches);
    try std.testing.expectEqual(@as(i32, 7), result.session.meta.self_pid);
    try std.testing.expectEqual(@as(usize, 0), result.session.capabilities.len);
    std.Io.Dir.deleteFileAbsolute(std.testing.io, path) catch {};
}
