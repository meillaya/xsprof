//! Safe path handling for state, journal, and daemon outputs.

const std = @import("std");

pub const unsafe_verbs = [_][]const u8{
    "load",
    "attach",
    "enable",
    "mutate",
    "apply",
    "sched-ext-attach",
    "setaffinity",
    "setpriority",
    "bind",
};

pub fn isUnsafeVerb(cmd: []const u8) bool {
    for (unsafe_verbs) |verb| {
        if (std.mem.eql(u8, cmd, verb)) return true;
    }
    return false;
}

/// True when `path` is a non-empty relative path with no `..` component and
/// no absolute prefix. `.` components are allowed.
pub fn isSafeRelative(path: []const u8) bool {
    if (path.len == 0) return false;
    if (path[0] == '/' or path[0] == '\\') return false;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        if (std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

/// Resolve a safe relative path under `base`, normalizing `.` components.
/// Returns error.UnsafePath for absolute paths, traversal, or empty input.
pub fn resolveUnder(base: []const u8, path: []const u8, out: []u8) ![]const u8 {
    if (!isSafeRelative(path)) return error.UnsafePath;
    var used: usize = 0;
    if (base.len > out.len) return error.NameTooLong;
    @memcpy(out[0..base.len], base);
    used = base.len;
    while (used > 0 and out[used - 1] == '/') used -= 1;
    if (used < out.len) {
        out[used] = '/';
        used += 1;
    }
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (used + part.len + 1 > out.len) return error.NameTooLong;
        if (used > 0 and out[used - 1] != '/') {
            out[used] = '/';
            used += 1;
        }
        @memcpy(out[used .. used + part.len], part);
        used += part.len;
    }
    return out[0..used];
}

test "safe relative paths reject traversal and absolute paths" {
    try std.testing.expect(isSafeRelative("events.jsonl"));
    try std.testing.expect(isSafeRelative("state/session.jsonl"));
    try std.testing.expect(!isSafeRelative(""));
    try std.testing.expect(!isSafeRelative("/etc/passwd"));
    try std.testing.expect(!isSafeRelative("../escape"));
    try std.testing.expect(!isSafeRelative("a/../../b"));
    try std.testing.expect(!isUnsafeVerb("preflight"));
    try std.testing.expect(isUnsafeVerb("setaffinity"));
}

test "resolveUnder normalizes dots" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "state/session/events.jsonl",
        try resolveUnder("state", "./session//events.jsonl", &buf),
    );
    try std.testing.expectError(error.UnsafePath, resolveUnder("state", "../x", &buf));
}
