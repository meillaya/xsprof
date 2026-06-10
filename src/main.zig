const std = @import("std");
const linux = @import("linux_scheduler");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const args = argv[1..];

    if (args.len == 0 or std.mem.eql(u8, args[0], "help") or std.mem.eql(u8, args[0], "--help")) {
        var stdout_buffer: [2048]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &stdout_buffer);
        try linux.writeHelp(&stdout_writer.interface, "zig-scheduler");
        try stdout_writer.interface.flush();
        return;
    }

    if (linux.isUnsafeCommand(args[0])) {
        try writeRefusal(args[0]);
        std.process.exit(1);
    }

    if (std.mem.eql(u8, args[0], "preflight")) {
        try runPreflight(allocator, args[1..]);
        return;
    }

    if (std.mem.eql(u8, args[0], "sched-ext")) {
        if (args.len == 3 and std.mem.eql(u8, args[1], "preflight") and std.mem.eql(u8, args[2], "--json")) {
            try runPreflight(allocator, args[2..]);
            return;
        }
        try writeRefusal("sched-ext mutation");
        std.process.exit(1);
    }

    if (std.mem.eql(u8, args[0], "controller")) {
        try writeControllerDryRun(args[1..]);
        return;
    }

    try writeRefusal(args[0]);
    std.process.exit(1);
}

fn runPreflight(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len != 1 or !std.mem.eql(u8, args[0], "--json")) {
        try writeRefusal("preflight expects --json and remains read-only");
        std.process.exit(2);
    }
    var report = try linux.collectPreflight(allocator);
    defer report.deinit();

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &stdout_buffer);
    try linux.writePreflightJson(&stdout_writer.interface, report);
    try stdout_writer.interface.writeByte('\n');
    try stdout_writer.interface.flush();
}

fn writeControllerDryRun(args: []const []const u8) !void {
    if (args.len != 2 or !std.mem.eql(u8, args[0], "plan") or !std.mem.eql(u8, args[1], "--dry-run")) {
        try writeRefusal("controller supports dry-run plan only");
        std.process.exit(2);
    }
    try writeRefusal("controller dry-run requires explicit lab gate, allowlist, rollback id, audit id, and operator confirmation; no mutation performed");
    std.process.exit(1);
}

fn writeRefusal(command: []const u8) !void {
    var message_buffer: [1024]u8 = undefined;
    const message = try std.fmt.bufPrint(
        &message_buffer,
        "refused unsafe or unsupported command '{s}': root is read-only/preflight-first; no mutation, attach, enable, load, cgroup write, affinity write, or BPF load path exists\n",
        .{command},
    );
    try std.Io.File.stderr().writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), message);
}

test "help identifies Linux scheduler operator surface" {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(std.testing.allocator, &buffer);
    try linux.writeHelp(&writer.writer, "zig-scheduler");
    buffer = writer.toArrayList();
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "Linux scheduler") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "simulator/") != null);
}
