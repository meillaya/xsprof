//! Read-only cgroup attribution. The snapshot joins `/proc/<pid>/cgroup` with
//! task names and reports bounded per-cgroup counts. Nothing here creates,
//! moves, or writes a cgroup.

const std = @import("std");
const builtin = @import("builtin");
const json = @import("../../core/json.zig");

const Writer = std.Io.Writer;
const max_groups = 512;
const max_samples = 3;
const max_tasks = 100_000;

pub const Reference = struct {
    version: u8,
    path: []const u8,
};

pub const Record = struct {
    path: []const u8,
    comm: []const u8,
};

pub const Group = struct {
    path: []const u8,
    tasks: u32 = 0,
    sample_comms: [max_samples][]const u8 = @splat(""),
    sample_count: usize = 0,
};

pub const Aggregate = struct {
    groups: []const Group,
    truncated: bool,
};

pub const Snapshot = struct {
    state: []const u8 = "SKIP",
    reason: []const u8 = "",
    version: u8 = 0,
    tasks: u32 = 0,
    truncated: bool = false,
    groups: []const Group = &.{},
};

pub fn parseProcCgroup(text: []const u8) ?Reference {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "0::")) {
            return .{ .version = 2, .path = line[3..] };
        }
        var fields = std.mem.splitScalar(u8, line, ':');
        _ = fields.next() orelse continue;
        const controllers = fields.next() orelse continue;
        const path = fields.next() orelse continue;
        if (controllers.len != 0) {
            return .{ .version = 1, .path = path };
        }
    }
    return null;
}

pub fn aggregate(
    allocator: std.mem.Allocator,
    records: []const Record,
    limit: usize,
) !Aggregate {
    var lookup = std.StringHashMap(usize).init(allocator);
    defer lookup.deinit();
    var groups: std.ArrayList(Group) = .empty;
    errdefer groups.deinit(allocator);
    var truncated = false;

    for (records) |record| {
        if (record.path.len == 0) continue;
        const slot = lookup.get(record.path) orelse blk: {
            if (groups.items.len >= limit) {
                truncated = true;
                continue;
            }
            groups.append(allocator, .{ .path = record.path }) catch |err| return err;
            lookup.put(record.path, groups.items.len - 1) catch |err| return err;
            break :blk groups.items.len - 1;
        };
        const group = &groups.items[slot];
        group.tasks += 1;
        if (group.sample_count < max_samples and record.comm.len != 0) {
            group.sample_comms[group.sample_count] = record.comm;
            group.sample_count += 1;
        }
    }
    std.mem.sortUnstable(Group, groups.items, {}, struct {
        fn less(_: void, a: Group, b: Group) bool {
            if (a.tasks != b.tasks) return a.tasks > b.tasks;
            return std.mem.order(u8, a.path, b.path) == .lt;
        }
    }.less);
    return .{
        .groups = try groups.toOwnedSlice(allocator),
        .truncated = truncated,
    };
}

fn readFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    return reader.interface.allocRemaining(allocator, .limited(64 * 1024)) catch null;
}

pub fn collect(io: std.Io, allocator: std.mem.Allocator) Snapshot {
    if (builtin.os.tag != .linux) {
        return .{ .state = "SKIP", .reason = "non-Linux host: /proc cgroup unavailable" };
    }
    const own = readFile(io, allocator, "/proc/self/cgroup") orelse
        return .{ .state = "SKIP", .reason = "/proc/self/cgroup unreadable" };
    const reference = parseProcCgroup(own) orelse
        return .{ .state = "SKIP", .reason = "no cgroup membership found" };
    if (reference.version != 2) {
        return .{ .state = "SKIP", .reason = "cgroup v1 unified attribution is not supported" };
    }

    var dir = std.Io.Dir.openDirAbsolute(io, "/proc", .{ .iterate = true }) catch
        return .{ .state = "REFUSE", .reason = "/proc unreadable" };
    defer dir.close(io);
    var records: std.ArrayList(Record) = .empty;
    defer records.deinit(allocator);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (records.items.len >= max_tasks) break;
        if (entry.name.len == 0 or entry.name[0] < '0' or entry.name[0] > '9') continue;
        var numeric = true;
        for (entry.name) |byte| {
            if (!std.ascii.isDigit(byte)) {
                numeric = false;
                break;
            }
        }
        if (!numeric) continue;
        var path_buffer: [64]u8 = undefined;
        const cgroup_path = std.fmt.bufPrint(&path_buffer, "/proc/{s}/cgroup", .{entry.name}) catch continue;
        const text = readFile(io, allocator, cgroup_path) orelse continue;
        const member = parseProcCgroup(text) orelse continue;
        if (member.version != 2) continue;
        var comm_path_buffer: [64]u8 = undefined;
        const comm_path = std.fmt.bufPrint(&comm_path_buffer, "/proc/{s}/comm", .{entry.name}) catch continue;
        const comm = readFile(io, allocator, comm_path) orelse continue;
        records.append(allocator, .{
            .path = member.path,
            .comm = std.mem.trim(u8, comm, " \t\r\n"),
        }) catch return .{ .state = "REFUSE", .reason = "out of memory while reading /proc" };
    }
    const result = aggregate(allocator, records.items, max_groups) catch
        return .{ .state = "REFUSE", .reason = "out of memory while grouping cgroups" };
    return .{
        .state = "READY",
        .version = 2,
        .tasks = @intCast(@min(records.items.len, std.math.maxInt(u32))),
        .truncated = result.truncated,
        .groups = result.groups,
    };
}

fn writeGroup(w: *Writer, group: Group) Writer.Error!void {
    try w.writeAll("{\"path\":");
    try json.write(w, .{ .string = group.path });
    try w.writeAll(",\"sample_comms\":[");
    for (group.sample_comms[0..group.sample_count], 0..) |comm, index| {
        if (index != 0) try w.writeByte(',');
        try json.write(w, .{ .string = comm });
    }
    try w.writeAll("],\"tasks\":");
    try json.write(w, .{ .unsigned = group.tasks });
    try w.writeByte('}');
}

pub fn writeJson(w: *Writer, snapshot: Snapshot) Writer.Error!void {
    try w.writeAll("{\"cgroup_version\":");
    try json.write(w, .{ .unsigned = snapshot.version });
    try w.writeAll(",\"groups\":[");
    for (snapshot.groups, 0..) |group, index| {
        if (index != 0) try w.writeByte(',');
        try writeGroup(w, group);
    }
    try w.writeAll("],\"host_mutation\":false,\"reason\":");
    try json.write(w, .{ .string = snapshot.reason });
    try w.writeAll(",\"schema\":\"xsprof/cgroup/v1\",\"source\":\"proc_cgroup\",\"state\":");
    try json.write(w, .{ .string = snapshot.state });
    try w.writeAll(",\"tasks\":");
    try json.write(w, .{ .unsigned = snapshot.tasks });
    try w.writeAll(",\"truncated\":");
    try json.write(w, .{ .boolean = snapshot.truncated });
    try w.writeByte('}');
}

test "parses cgroup v2 and v1 membership" {
    const v2 = parseProcCgroup("0::/user.slice/user-1000.slice/session-2.scope\n").?;
    try std.testing.expectEqual(@as(u8, 2), v2.version);
    try std.testing.expectEqualStrings("/user.slice/user-1000.slice/session-2.scope", v2.path);
    const v1 = parseProcCgroup("12:cpu,cpuacct:/docker/abc\n1:name=systemd:/init.scope\n").?;
    try std.testing.expectEqual(@as(u8, 1), v1.version);
    try std.testing.expectEqualStrings("/docker/abc", v1.path);
    try std.testing.expect(parseProcCgroup("garbage\n") == null);
}

test "aggregation counts, bounds samples, and sorts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const records = [_]Record{
        .{ .path = "/a", .comm = "one" },
        .{ .path = "/a", .comm = "two" },
        .{ .path = "/b", .comm = "three" },
        .{ .path = "/a", .comm = "four" },
        .{ .path = "/a", .comm = "five" },
    };
    const result = try aggregate(arena.allocator(), &records, 8);
    try std.testing.expectEqual(@as(usize, 2), result.groups.len);
    try std.testing.expectEqualStrings("/a", result.groups[0].path);
    try std.testing.expectEqual(@as(u32, 4), result.groups[0].tasks);
    try std.testing.expectEqual(@as(usize, 3), result.groups[0].sample_count);
    try std.testing.expectEqual(@as(u32, 1), result.groups[1].tasks);
    try std.testing.expect(!result.truncated);
    const bounded = try aggregate(arena.allocator(), &records, 1);
    try std.testing.expect(bounded.truncated);
}

test "cgroup JSON is canonical and read-only" {
    const groups = [_]Group{
        .{ .path = "/a", .tasks = 2, .sample_comms = .{ "one", "two", "" }, .sample_count = 2 },
    };
    const snapshot = Snapshot{
        .state = "READY",
        .version = 2,
        .tasks = 2,
        .groups = &groups,
    };
    var buffer: [1024]u8 = undefined;
    var writer = Writer.fixed(&buffer);
    try writeJson(&writer, snapshot);
    try std.testing.expectEqualStrings(
        "{\"cgroup_version\":2,\"groups\":[{\"path\":\"/a\",\"sample_comms\":" ++
            "[\"one\",\"two\"],\"tasks\":2}],\"host_mutation\":false,\"reason\":\"\"," ++
            "\"schema\":\"xsprof/cgroup/v1\",\"source\":\"proc_cgroup\"," ++
            "\"state\":\"READY\",\"tasks\":2,\"truncated\":false}",
        writer.buffered(),
    );
}
