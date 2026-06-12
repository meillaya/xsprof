const std = @import("std");
const linux = @import("linux_scheduler");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const options = linux.control.daemon.parseArgs(argv[1..]) catch {
        try writeStderr("usage: zig-scheduler-daemon --foreground --state-dir <relative-dir>\n");
        std.process.exit(2);
    };
    try runForeground(allocator, init.io, options.state_dir);
}

fn runForeground(allocator: std.mem.Allocator, io: std.Io, state_dir: []const u8) !void {
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, state_dir, .{});
    defer dir.close(io);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try appendReady(allocator, &output);

    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().readerStreaming(io, &stdin_buffer);
    var seq: usize = 2;
    while (try stdin_reader.interface.takeDelimiter('\n')) |line| {
        if (std.mem.trim(u8, line, " \t\r\n").len == 0) continue;
        if (seq > linux.control.daemon.max_events_per_run) {
            try appendOverflow(allocator, &output, seq);
            break;
        }
        try appendAction(allocator, io, &output, line, &seq);
    }

    try writeStdout(output.items);
    try dir.writeFile(io, .{ .sub_path = "events.jsonl", .data = output.items });
}

fn appendReady(allocator: std.mem.Allocator, output: *std.ArrayList(u8)) !void {
    var event: std.ArrayList(u8) = .empty;
    defer event.deinit(allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(allocator, &event);
    try linux.control.daemon.writeReady(&writer.writer);
    event = writer.toArrayList();
    try appendEvent(allocator, output, event.items);
}

fn appendAction(allocator: std.mem.Allocator, io: std.Io, output: *std.ArrayList(u8), line: []const u8, seq: *usize) !void {
    var parsed = linux.control.protocol.parseActionJson(allocator, std.mem.trim(u8, line, " \t\r\n")) catch {
        try appendMalformed(allocator, output, seq.*);
        seq.* += 1;
        return;
    };
    defer parsed.deinit();
    if (parsed.value.kind == .run_lab_host_safe) {
        try linux.control.lab_runner.runHostSafe(allocator, io, output, parsed.value, seq);
        return;
    }

    var event: std.ArrayList(u8) = .empty;
    defer event.deinit(allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(allocator, &event);
    try linux.control.daemon.writeActionResult(&writer.writer, allocator, line, seq.*);
    event = writer.toArrayList();
    try appendEvent(allocator, output, event.items);
    seq.* += 1;
}

fn appendMalformed(allocator: std.mem.Allocator, output: *std.ArrayList(u8), seq: usize) !void {
    var event: std.ArrayList(u8) = .empty;
    defer event.deinit(allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(allocator, &event);
    try linux.control.daemon.writeActionResult(&writer.writer, allocator, "{not-json", seq);
    event = writer.toArrayList();
    try appendEvent(allocator, output, event.items);
}

fn appendOverflow(allocator: std.mem.Allocator, output: *std.ArrayList(u8), seq: usize) !void {
    var event: std.ArrayList(u8) = .empty;
    defer event.deinit(allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(allocator, &event);
    try writer.writer.print(
        "{{\"schema\":\"zig-scheduler/daemon-event/v1\",\"seq\":{d},\"event\":\"refusal\",\"state\":\"incident\",\"status\":\"refused\",\"reason\":\"journal_limit_exceeded\",\"host_mutation\":false}}\n",
        .{seq},
    );
    event = writer.toArrayList();
    try appendEvent(allocator, output, event.items);
}

fn appendEvent(allocator: std.mem.Allocator, output: *std.ArrayList(u8), event: []const u8) !void {
    try linux.control.daemon.ensureCanWriteEvent(output.items.len, event);
    try output.appendSlice(allocator, event);
}

fn writeStdout(bytes: []const u8) !void {
    var buffer: [8192]u8 = undefined;
    var writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

fn writeStderr(bytes: []const u8) !void {
    try std.Io.File.stderr().writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), bytes);
}

test "daemon executable links control module" {
    _ = try linux.control.daemon.parseArgs(&.{ "--foreground", "--state-dir", ".omo/evidence/task-T08-state" });
}
