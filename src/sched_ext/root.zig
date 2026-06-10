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
    enable_seq: TextFact,
    switch_all: TextFact,
    nr_rejected: TextFact,
};

pub fn collect(allocator: std.mem.Allocator) !SchedExtFacts {
    return .{
        .state = try readSmallFact(allocator, "/sys/kernel/sched_ext/state"),
        .enable_seq = try readSmallFact(allocator, "/sys/kernel/sched_ext/enable_seq"),
        .switch_all = try readSmallFact(allocator, "/sys/kernel/sched_ext/switch_all"),
        .nr_rejected = try readSmallFact(allocator, "/sys/kernel/sched_ext/nr_rejected"),
    };
}

pub fn deinit(facts: *SchedExtFacts, allocator: std.mem.Allocator) void {
    freeFact(allocator, facts.state);
    freeFact(allocator, facts.enable_seq);
    freeFact(allocator, facts.switch_all);
    freeFact(allocator, facts.nr_rejected);
}

pub fn readSmallFact(allocator: std.mem.Allocator, absolute_path: []const u8) !TextFact {
    return readLimitedTextFact(allocator, absolute_path, 4096);
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
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "long.txt");
    defer std.testing.allocator.free(path);
    const fact = try readLimitedTextFact(std.testing.allocator, path, 3);
    try std.testing.expectEqual(FactStatus.unsafe_to_assume, fact.status);
    try std.testing.expectEqual(@as(usize, 0), fact.value.len);
}
