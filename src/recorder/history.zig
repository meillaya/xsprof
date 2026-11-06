//! Sidecar history: query the per-segment metrics documents that survive raw
//! retention. Entries are ordered by the wall-clock prefix in the sidecar name.

const std = @import("std");
const json = @import("../core/json.zig");
const aggregates = @import("../analyze/aggregates.zig");
const metrics_mod = @import("../analyze/metrics.zig");
const metrics_json = @import("../analyze/metrics_json.zig");

const Writer = std.Io.Writer;

pub const Entry = struct {
    start_wall_ns: u64,
    events: u64,
    switches: u64,
    wakeups: u64,
    self_wakeups: u64,
    unnecessary_wakeups: u64,
    unresolved_wakeups: u64,
    migrations: u64,
    faults: u64,
    lost: u64,
    cpu_busy_us: u64,
};

pub const Totals = struct {
    events: u64 = 0,
    switches: u64 = 0,
    wakeups: u64 = 0,
    self_wakeups: u64 = 0,
    unnecessary_wakeups: u64 = 0,
    unresolved_wakeups: u64 = 0,
    migrations: u64 = 0,
    faults: u64 = 0,
    lost: u64 = 0,
    cpu_busy_us: u64 = 0,
};

pub const Report = struct {
    entries: []const Entry,
    totals: Totals,
    first_wall_ns: u64 = 0,
    last_wall_ns: u64 = 0,
    sidecars: usize = 0,
};

fn openDir(io: std.Io, path: []const u8) !std.Io.Dir {
    if (path.len != 0 and path[0] == '/') {
        return std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true });
    }
    return std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
}

fn readFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = if (path.len != 0 and path[0] == '/')
        try std.Io.Dir.openFileAbsolute(io, path, .{})
    else
        try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buffer: [16 * 1024]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    return reader.interface.allocRemaining(allocator, .limited(4 * 1024 * 1024));
}

fn parseStartWall(name: []const u8) ?u64 {
    if (!std.mem.endsWith(u8, name, ".json")) return null;
    const stem = name[0 .. name.len - ".json".len];
    const dash = std.mem.indexOfScalar(u8, stem, '-') orelse return null;
    return std.fmt.parseInt(u64, stem[0..dash], 10) catch null;
}

pub fn scan(
    io: std.Io,
    allocator: std.mem.Allocator,
    dir: []const u8,
    last_ms: u64,
) !Report {
    const metrics_path = try std.fmt.allocPrint(allocator, "{s}/metrics", .{dir});
    var metrics_dir = openDir(io, metrics_path) catch return .{
        .entries = &.{},
        .totals = .{},
    };
    defer metrics_dir.close(io);

    const now_wall = @as(u64, @intCast(@max(0, std.Io.Clock.now(.real, io).nanoseconds)));
    const window_ns = std.math.mul(u64, last_ms, std.time.ns_per_ms) catch std.math.maxInt(u64);
    const cutoff = if (last_ms == 0) 0 else now_wall -| window_ns;

    var entries: std.ArrayList(Entry) = .empty;
    errdefer entries.deinit(allocator);
    var iterator = metrics_dir.iterate();
    while (iterator.next(io) catch null) |item| {
        if (item.kind != .file) continue;
        const start_wall = parseStartWall(item.name) orelse continue;
        if (start_wall < cutoff) continue;
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ metrics_path, item.name });
        const data = readFile(io, allocator, path) catch continue;
        if (!json.depthOk(data, 64)) continue;
        const envelope = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch continue;
        defer envelope.deinit();
        const object = switch (envelope.value) {
            .object => |value| value,
            else => continue,
        };
        const schema_value = object.get("schema") orelse continue;
        const schema_text = switch (schema_value) {
            .string => |value| value,
            else => continue,
        };
        if (!std.mem.eql(u8, schema_text, "xsprof/metrics/v1")) continue;
        if (object.get("host_mutation")) |mutation| {
            switch (mutation) {
                .bool => |value| if (value) continue,
                else => continue,
            }
        } else continue;
        const parsed = std.json.parseFromSlice(metrics_mod.Metrics, allocator, data, .{
            .ignore_unknown_fields = true,
        }) catch continue;
        defer parsed.deinit();
        const metrics = parsed.value;
        var cpu_busy: u64 = 0;
        for (metrics.cpus) |cpu| cpu_busy +|= cpu.busy_us;
        try entries.append(allocator, .{
            .start_wall_ns = start_wall,
            .events = metrics.events,
            .switches = metrics.switches,
            .wakeups = metrics.wakeups,
            .self_wakeups = metrics.self_wakeups,
            .unnecessary_wakeups = metrics.unnecessary_wakeups,
            .unresolved_wakeups = metrics.unresolved_wakeups,
            .migrations = metrics.migrations,
            .faults = metrics.faults_minor +| metrics.faults_major,
            .lost = metrics.lost,
            .cpu_busy_us = cpu_busy,
        });
    }
    std.mem.sortUnstable(Entry, entries.items, {}, struct {
        fn less(_: void, a: Entry, b: Entry) bool {
            return a.start_wall_ns < b.start_wall_ns;
        }
    }.less);

    var totals: Totals = .{};
    var first: u64 = 0;
    var last: u64 = 0;
    for (entries.items, 0..) |entry, index| {
        totals.events +|= entry.events;
        totals.switches +|= entry.switches;
        totals.wakeups +|= entry.wakeups;
        totals.self_wakeups +|= entry.self_wakeups;
        totals.unnecessary_wakeups +|= entry.unnecessary_wakeups;
        totals.unresolved_wakeups +|= entry.unresolved_wakeups;
        totals.migrations +|= entry.migrations;
        totals.faults +|= entry.faults;
        totals.lost +|= entry.lost;
        totals.cpu_busy_us +|= entry.cpu_busy_us;
        if (index == 0) first = entry.start_wall_ns;
        last = entry.start_wall_ns;
    }
    const sidecar_count = entries.items.len;
    return .{
        .entries = try entries.toOwnedSlice(allocator),
        .totals = totals,
        .first_wall_ns = first,
        .last_wall_ns = last,
        .sidecars = sidecar_count,
    };
}

pub fn aggregate(report: Report) aggregates.Aggregates {
    const non_self_wakeups = report.totals.wakeups -| report.totals.self_wakeups;
    return .{
        .migrations = @intCast(report.totals.migrations),
        .wakeups = @intCast(non_self_wakeups),
        .self_wakeups = @intCast(report.totals.self_wakeups),
        .unnecessary_wakeups = @intCast(report.totals.unnecessary_wakeups),
        .unresolved_wakeups = @intCast(report.totals.unresolved_wakeups),
        .page_faults = @intCast(report.totals.faults),
        .sched_collected = report.totals.switches > 0,
        .pmu_collected = false,
        .signals = .{
            .sched_switch = report.totals.switches > 0,
            .sched_wakeup = non_self_wakeups > 0,
            .sched_migrate = report.totals.migrations > 0,
            .page_fault = report.totals.faults > 0,
        },
    };
}

pub fn writeJson(w: *Writer, report: Report) !void {
    try w.writeAll("{\"entries\":[");
    for (report.entries, 0..) |entry, index| {
        if (index != 0) try w.writeByte(',');
        try w.print(
            "{{\"cpu_busy_us\":{d},\"events\":{d},\"faults\":{d},\"lost\":{d},\"migrations\":{d},\"start_wall_ns\":{d},\"switches\":{d},\"unnecessary_wakeups\":{d},\"unresolved_wakeups\":{d},\"wakeups\":{d}}}",
            .{
                entry.cpu_busy_us,
                entry.events,
                entry.faults,
                entry.lost,
                entry.migrations,
                entry.start_wall_ns,
                entry.switches,
                entry.unnecessary_wakeups,
                entry.unresolved_wakeups,
                entry.wakeups,
            },
        );
    }
    try w.print("],\"first_wall_ns\":{d},\"host_mutation\":false,\"last_wall_ns\":{d},\"schema\":\"xsprof/history/v1\",\"sidecars\":{d},\"totals\":{{\"cpu_busy_us\":{d},\"events\":{d},\"faults\":{d},\"lost\":{d},\"migrations\":{d},\"switches\":{d},\"unnecessary_wakeups\":{d},\"unresolved_wakeups\":{d},\"wakeups\":{d}}},\"window_ms\":{d}}}\n", .{
        report.first_wall_ns,
        report.last_wall_ns,
        report.sidecars,
        report.totals.cpu_busy_us,
        report.totals.events,
        report.totals.faults,
        report.totals.lost,
        report.totals.migrations,
        report.totals.switches,
        report.totals.unnecessary_wakeups,
        report.totals.unresolved_wakeups,
        report.totals.wakeups,
        if (report.last_wall_ns > report.first_wall_ns)
            (report.last_wall_ns - report.first_wall_ns) / std.time.ns_per_ms
        else
            0,
    });
}

pub fn writeMarkdown(w: *Writer, report: Report) !void {
    try w.writeAll("# xsprof sidecar history\n\n");
    try w.print(
        "- sidecars: {d}\n- events: {d}\n- switches: {d}\n- wakeups: {d}\n- unnecessary wakeups: {d}\n- migrations: {d}\n- faults: {d}\n- lost: {d}\n\n",
        .{
            report.sidecars,
            report.totals.events,
            report.totals.switches,
            report.totals.wakeups,
            report.totals.unnecessary_wakeups,
            report.totals.migrations,
            report.totals.faults,
            report.totals.lost,
        },
    );
    try w.writeAll("| start wall ns | events | switches | wakeups | unnecessary | faults |\n|---|---:|---:|---:|---:|---:|\n");
    for (report.entries) |entry| {
        try w.print("| {d} | {d} | {d} | {d} | {d} | {d} |\n", .{
            entry.start_wall_ns,
            entry.events,
            entry.switches,
            entry.wakeups,
            entry.unnecessary_wakeups,
            entry.faults,
        });
    }
}

fn writeHistorySidecar(
    io: std.Io,
    path: []const u8,
    switches: u64,
    unnecessary: u64,
) !void {
    const file = try std.Io.Dir.createFileAbsolute(io, path, .{});
    defer file.close(io);
    var buffer: [16 * 1024]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try metrics_json.writeJson(&writer.interface, .{
        .events = switches + 1,
        .switches = switches,
        .wakeups = 2,
        .unnecessary_wakeups = unnecessary,
    }, 4);
    try writer.interface.flush();
}

test "sidecar history aggregates and filters by start wall" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try std.fmt.allocPrint(allocator, "/tmp/xsprof-history-{d}", .{std.testing.random_seed});
    const metrics_dir = try std.fmt.allocPrint(allocator, "{s}/metrics", .{root});
    std.Io.Dir.createDirAbsolute(std.testing.io, root, .default_dir) catch {};
    std.Io.Dir.createDirAbsolute(std.testing.io, metrics_dir, .default_dir) catch {};

    const now = @as(u64, @intCast(@max(0, std.Io.Clock.now(.real, std.testing.io).nanoseconds)));
    const first_path = try std.fmt.allocPrint(allocator, "{s}/{d}-0.json", .{ metrics_dir, now - 20 * std.time.ns_per_s });
    const second_path = try std.fmt.allocPrint(allocator, "{s}/{d}-1.json", .{ metrics_dir, now - 10 * std.time.ns_per_s });
    try writeHistorySidecar(std.testing.io, first_path, 10, 1);
    try writeHistorySidecar(std.testing.io, second_path, 20, 2);

    const report = try scan(std.testing.io, allocator, root, 60_000);
    try std.testing.expectEqual(@as(usize, 2), report.sidecars);
    try std.testing.expectEqual(@as(u64, 30), report.totals.switches);
    try std.testing.expectEqual(@as(u64, 3), report.totals.unnecessary_wakeups);
    try std.testing.expectEqual(@as(usize, 2), report.entries.len);

    std.Io.Dir.deleteFileAbsolute(std.testing.io, first_path) catch {};
    std.Io.Dir.deleteFileAbsolute(std.testing.io, second_path) catch {};
    std.Io.Dir.deleteDirAbsolute(std.testing.io, metrics_dir) catch {};
    std.Io.Dir.deleteDirAbsolute(std.testing.io, root) catch {};
}
