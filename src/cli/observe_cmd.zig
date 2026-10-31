const std = @import("std");
const pressure = @import("../os/linux/pressure.zig");
const cgroup = @import("../os/linux/cgroup.zig");

const Writer = std.Io.Writer;

fn hasJson(args: []const []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) return true;
    }
    return false;
}

pub fn cmdPressure(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    out: *Writer,
    err: *Writer,
) !u8 {
    if (!hasJson(args)) {
        try err.writeAll("pressure expects --json and remains read-only\n");
        return 2;
    }
    const snapshot = pressure.collect(io, allocator);
    try pressure.writeJson(out, snapshot);
    try out.writeByte('\n');
    return if (snapshot.available) 0 else 1;
}

pub fn cmdCgroup(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    out: *Writer,
    err: *Writer,
) !u8 {
    if (!hasJson(args)) {
        try err.writeAll("cgroup expects --json and remains read-only\n");
        return 2;
    }
    const snapshot = cgroup.collect(io, allocator);
    try cgroup.writeJson(out, snapshot);
    try out.writeByte('\n');
    return if (std.mem.eql(u8, snapshot.state, "READY")) 0 else 1;
}
