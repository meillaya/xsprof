pub const loader = @import("loader/root.zig");
const std = @import("std");

pub const FactStatus = enum {
    present,
    missing,
    unreadable,
    unknown,
    unsafe_to_assume,
};

pub const TextFact = struct {
    status: FactStatus,
    value: []const u8,
};

pub const SchedExtFacts = struct {
    state: TextFact,
    root_ops: TextFact,
    enable_seq: TextFact,
    events: TextFact,
    policy_metadata: TextFact,
    rollback_state: TextFact,
    switch_all: TextFact,
    nr_rejected: TextFact,
};

pub fn collect(allocator: std.mem.Allocator) !SchedExtFacts {
    return collectFromRoot(allocator, "");
}

pub fn collectFromRoot(allocator: std.mem.Allocator, root_path: []const u8) !SchedExtFacts {
    return .{
        .state = try readSmallFactFromRoot(allocator, root_path, "/sys/kernel/sched_ext/state"),
        .root_ops = try readSmallFactFromRoot(allocator, root_path, "/sys/kernel/sched_ext/root/ops"),
        .enable_seq = try readSmallFactFromRoot(allocator, root_path, "/sys/kernel/sched_ext/enable_seq"),
        .events = try readSmallFactFromRoot(allocator, root_path, "/sys/kernel/sched_ext/events"),
        .policy_metadata = try readSmallFactFromRoot(allocator, root_path, "/run/zig-scheduler/policy-metadata.json"),
        .rollback_state = try readSmallFactFromRoot(allocator, root_path, "/run/zig-scheduler/rollback-state.json"),
        .switch_all = try readSmallFactFromRoot(allocator, root_path, "/sys/kernel/sched_ext/switch_all"),
        .nr_rejected = try readSmallFactFromRoot(allocator, root_path, "/sys/kernel/sched_ext/nr_rejected"),
    };
}

pub fn deinit(facts: *SchedExtFacts, allocator: std.mem.Allocator) void {
    freeFact(allocator, facts.state);
    freeFact(allocator, facts.root_ops);
    freeFact(allocator, facts.enable_seq);
    freeFact(allocator, facts.events);
    freeFact(allocator, facts.policy_metadata);
    freeFact(allocator, facts.rollback_state);
    freeFact(allocator, facts.switch_all);
    freeFact(allocator, facts.nr_rejected);
}

pub fn readSmallFact(allocator: std.mem.Allocator, absolute_path: []const u8) !TextFact {
    return readLimitedTextFact(allocator, absolute_path, 4096);
}

pub fn readSmallFactFromRoot(allocator: std.mem.Allocator, root_path: []const u8, absolute_path: []const u8) !TextFact {
    return readLimitedTextFactFromRoot(allocator, root_path, absolute_path, 4096);
}

pub fn readLimitedTextFactFromRoot(allocator: std.mem.Allocator, root_path: []const u8, absolute_path: []const u8, limit: usize) !TextFact {
    const rooted_path = try rootedAbsolutePath(allocator, root_path, absolute_path);
    defer allocator.free(rooted_path);
    return readLimitedTextFact(allocator, rooted_path, limit);
}

pub fn readLimitedTextFact(allocator: std.mem.Allocator, absolute_path: []const u8, limit: usize) !TextFact {
    const io = std.Io.Threaded.global_single_threaded.io();
    var file = std.Io.Dir.openFileAbsolute(io, absolute_path, .{}) catch |err| return .{
        .status = statusFromOpenError(err),
        .value = "",
    };
    defer file.close(io);

    var buffer: [1024]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    reader.interface.appendRemaining(allocator, &list, .limited(limit)) catch |err| switch (err) {
        error.StreamTooLong => {
            list.deinit(allocator);
            return .{ .status = .unsafe_to_assume, .value = "" };
        },
        else => return err,
    };
    const raw = try list.toOwnedSlice(allocator);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == raw.len) return .{ .status = .present, .value = raw };
    const copy = try allocator.dupe(u8, trimmed);
    allocator.free(raw);
    return .{ .status = .present, .value = copy };
}

pub fn presenceFactFromRoot(allocator: std.mem.Allocator, root_path: []const u8, absolute_path: []const u8, label: []const u8) !TextFact {
    const rooted_path = try rootedAbsolutePath(allocator, root_path, absolute_path);
    defer allocator.free(rooted_path);
    return presenceFact(allocator, rooted_path, label);
}

pub fn presenceFact(allocator: std.mem.Allocator, absolute_path: []const u8, label: []const u8) !TextFact {
    const io = std.Io.Threaded.global_single_threaded.io();
    var file = std.Io.Dir.openFileAbsolute(io, absolute_path, .{}) catch |err| return .{
        .status = statusFromOpenError(err),
        .value = "",
    };
    file.close(io);
    return .{ .status = .present, .value = try allocator.dupe(u8, label) };
}

pub fn freeFact(allocator: std.mem.Allocator, fact: TextFact) void {
    if (fact.value.len != 0) allocator.free(fact.value);
}

fn rootedAbsolutePath(allocator: std.mem.Allocator, root_path: []const u8, absolute_path: []const u8) ![]u8 {
    if (root_path.len == 0) return allocator.dupe(u8, absolute_path);
    const relative = if (std.mem.startsWith(u8, absolute_path, "/")) absolute_path[1..] else absolute_path;
    return std.fs.path.join(allocator, &.{ root_path, relative });
}

fn statusFromOpenError(err: anyerror) FactStatus {
    return switch (err) {
        error.FileNotFound => .missing,
        error.AccessDenied, error.PermissionDenied => .unreadable,
        else => .unknown,
    };
}

test "status vocabulary includes unsafe_to_assume" {
    try std.testing.expectEqualStrings("unsafe_to_assume", @tagName(FactStatus.unsafe_to_assume));
}

test "limited text facts refuse over-limit files without assuming" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "long.txt", .data = "abcdef" });
    const path = try testingTmpPath(std.testing.allocator, tmp, "long.txt");
    defer std.testing.allocator.free(path);
    const fact = try readLimitedTextFact(std.testing.allocator, path, 3);
    try std.testing.expectEqual(FactStatus.unsafe_to_assume, fact.status);
    try std.testing.expectEqual(@as(usize, 0), fact.value.len);
}

test "injected sched_ext root reports missing and over-limit facts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    try testingMakePath(&tmp.dir, "sys/kernel/sched_ext");
    try testingMakePath(&tmp.dir, "sys/kernel/sched_ext/root");
    try testingMakePath(&tmp.dir, "run/zig-scheduler");
    try tmp.dir.writeFile(io, .{ .sub_path = "sys/kernel/sched_ext/state", .data = "abcdef" });
    try tmp.dir.writeFile(io, .{ .sub_path = "sys/kernel/sched_ext/root/ops", .data = "zigsched_minimal\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "sys/kernel/sched_ext/events", .data = "nr_rejected: 0\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "run/zig-scheduler/policy-metadata.json", .data = "{\"policy\":\"minimal\"}\n" });
    const root_path = try testingTmpPath(std.testing.allocator, tmp, ".");
    defer std.testing.allocator.free(root_path);

    const long_state = try readLimitedTextFactFromRoot(std.testing.allocator, root_path, "/sys/kernel/sched_ext/state", 3);
    defer freeFact(std.testing.allocator, long_state);
    try std.testing.expectEqual(FactStatus.unsafe_to_assume, long_state.status);

    var facts = try collectFromRoot(std.testing.allocator, root_path);
    defer deinit(&facts, std.testing.allocator);
    try std.testing.expectEqual(FactStatus.present, facts.state.status);
    try std.testing.expectEqualStrings("zigsched_minimal", facts.root_ops.value);
    try std.testing.expectEqual(FactStatus.present, facts.events.status);
    try std.testing.expectEqual(FactStatus.present, facts.policy_metadata.status);
    try std.testing.expectEqual(FactStatus.missing, facts.rollback_state.status);
    try std.testing.expectEqual(FactStatus.missing, facts.enable_seq.status);
}

test "open error mapping treats access denied as unreadable" {
    try std.testing.expectEqual(FactStatus.unreadable, statusFromOpenError(error.AccessDenied));
    try std.testing.expectEqual(FactStatus.unreadable, statusFromOpenError(error.PermissionDenied));
}

fn testingMakePath(dir: *std.Io.Dir, sub_path: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var child = try dir.createDirPathOpen(io, sub_path, .{});
    child.close(io);
}

fn testingTmpPath(allocator: std.mem.Allocator, tmp: std.testing.TmpDir, sub_path: []const u8) ![:0]u8 {
    const relative = if (std.mem.eql(u8, sub_path, "."))
        try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path})
    else
        try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/{s}", .{ &tmp.sub_path, sub_path });
    defer allocator.free(relative);
    return std.Io.Dir.cwd().realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), relative, allocator);
}
