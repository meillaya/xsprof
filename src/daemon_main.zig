const std = @import("std");
const linux = @import("linux_scheduler");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const options = linux.control.daemon.parseArgs(argv[1..]) catch {
        try writeStderr("usage: zig-scheduler-daemon --foreground [--follow] --state-dir <relative-dir> [--stream-runtime <relative-jsonl>] [--stream-from <sequence>]\n");
        std.process.exit(2);
    };
    try runForeground(allocator, init.io, init.minimal.environ, options);
}

fn runForeground(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, options: linux.control.daemon.Options) !void {
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, options.state_dir, .{});
    defer dir.close(io);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    var tracker = linux.control.journal.Tracker{};
    var flushed_bytes: usize = 0;
    var follow_flush = linux.control.daemon_dispatch.FollowFlush{ .enabled = options.follow, .flushed_bytes = &flushed_bytes };
    defer tracker.deinit(allocator);
    const existing = dir.readFileAlloc(io, "events.jsonl", allocator, .limited(linux.control.daemon.max_journal_bytes)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => |e| return e,
    };
    var seq: usize = 1;
    if (existing) |raw| {
        defer allocator.free(raw);
        try output.appendSlice(allocator, raw);
        if (raw.len != 0 and raw[raw.len - 1] != '\n') try output.append(allocator, '\n');
        seq = (try tracker.loadExisting(allocator, raw)).next_seq;
        if (options.follow) flushed_bytes = output.items.len;
    }
    const git_sha = try linux.control.daemon_dispatch.readGitSha(allocator, io);
    defer allocator.free(git_sha);
    try linux.control.daemon_dispatch.appendReady(allocator, &output, seq);
    seq += 1;
    try follow_flush.flush(output.items);

    if (options.runtime_stream_path) |path| {
        const raw = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(linux.control.daemon.max_journal_bytes));
        defer allocator.free(raw);
        try linux.control.stream.appendRuntimeFile(allocator, &output, raw, &seq, options.stream_from, git_sha);
        if (options.follow) try follow_flush.flush(output.items) else try writeStdout(output.items);
        try dir.writeFile(io, .{ .sub_path = "events.jsonl", .data = output.items });
        return;
    }

    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().readerStreaming(io, &stdin_buffer);
    while (try stdin_reader.interface.takeDelimiter('\n')) |line| {
        if (std.mem.trim(u8, line, " \t\r\n").len == 0) continue;
        if (seq > linux.control.daemon.max_events_per_run) {
            try linux.control.daemon_dispatch.appendOverflow(allocator, &output, seq);
            try follow_flush.flush(output.items);
            break;
        }
        try linux.control.daemon_dispatch.appendAction(allocator, io, environ, &output, &tracker, &dir, git_sha, line, &seq, &follow_flush);
        try follow_flush.flush(output.items);
    }

    if (options.follow) try follow_flush.flush(output.items) else try writeStdout(output.items);
    try dir.writeFile(io, .{ .sub_path = "events.jsonl", .data = output.items });
}

fn writeStdout(bytes: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), bytes);
}

fn writeStderr(bytes: []const u8) !void {
    try std.Io.File.stderr().writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), bytes);
}

test "daemon executable links control module" {
    _ = try linux.control.daemon.parseArgs(&.{ "--foreground", "--state-dir", ".omo/evidence/task-T08-state" });
}
