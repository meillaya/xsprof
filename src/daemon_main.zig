const std = @import("std");
const linux = @import("linux_scheduler");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const options = linux.control.daemon.parseArgs(argv[1..]) catch {
        try writeStderr("usage: zig-scheduler-daemon --foreground [--follow] --state-dir <relative-dir> [--stream-runtime <relative-jsonl>] [--stream-from <sequence>]\n");
        std.process.exit(2);
    };
    try runForeground(allocator, init.io, options);
}

fn runForeground(allocator: std.mem.Allocator, io: std.Io, options: linux.control.daemon.Options) !void {
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, options.state_dir, .{});
    defer dir.close(io);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    var tracker = linux.control.journal.Tracker{};
    var flushed_bytes: usize = 0;
    var follow_flush = FollowFlush{ .enabled = options.follow, .flushed_bytes = &flushed_bytes };
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
    const git_sha = try readGitSha(allocator, io);
    defer allocator.free(git_sha);
    try appendReady(allocator, &output, seq);
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
            try appendOverflow(allocator, &output, seq);
            try follow_flush.flush(output.items);
            break;
        }
        try appendAction(allocator, io, &output, &tracker, git_sha, line, &seq, &follow_flush);
        try follow_flush.flush(output.items);
    }

    if (options.follow) try follow_flush.flush(output.items) else try writeStdout(output.items);
    try dir.writeFile(io, .{ .sub_path = "events.jsonl", .data = output.items });
}

const FollowFlush = struct {
    enabled: bool,
    flushed_bytes: *usize,

    fn flush(self: *FollowFlush, bytes: []const u8) !void {
        if (!self.enabled) return;
        try flushNewOutput(bytes, self.flushed_bytes);
    }
};

fn appendReady(allocator: std.mem.Allocator, output: *std.ArrayList(u8), seq: usize) !void {
    var event: std.ArrayList(u8) = .empty;
    defer event.deinit(allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(allocator, &event);
    try writer.writer.print("{{\"schema\":\"zig-scheduler/daemon-event/v1\",\"seq\":{d},\"event\":\"state_changed\",\"state\":\"read_only\",\"status\":\"ready\",\"host_mutation\":false}}\n", .{seq});
    event = writer.toArrayList();
    try appendEvent(allocator, output, event.items);
}

fn appendAction(
    allocator: std.mem.Allocator,
    io: std.Io,
    output: *std.ArrayList(u8),
    tracker: *linux.control.journal.Tracker,
    git_sha: []const u8,
    line: []const u8,
    seq: *usize,
    follow_flush: *FollowFlush,
) !void {
    var parsed = linux.control.protocol.parseActionJson(allocator, std.mem.trim(u8, line, " \t\r\n")) catch {
        try appendMalformed(allocator, output, seq.*);
        seq.* += 1;
        return;
    };
    defer parsed.deinit();
    tracker.remember(allocator, parsed.value.action_id) catch |err| switch (err) {
        error.DuplicateActionId => {
            try appendDuplicate(allocator, output, parsed.value, seq.*);
            seq.* += 1;
            return;
        },
        error.InvalidActionId => {
            try appendInvalidActionId(allocator, output, parsed.value, seq.*);
            seq.* += 1;
            return;
        },
        else => |e| return e,
    };
    if (parsed.value.action_id.len != 0) {
        try appendJournalRecord(allocator, output, parsed.value, git_sha, seq.*);
        seq.* += 1;
    }
    if (parsed.value.kind == .run_lab_host_safe) {
        try linux.control.lab_runner.runHostSafe(allocator, io, output, parsed.value, seq);
        return;
    }
    if (parsed.value.kind == .run_lab_vm) {
        try linux.control.rollback.handleRunLabVm(allocator, io, output, tracker, parsed.value, seq);
        return;
    }
    if (parsed.value.kind == .run_lab_microvm_live) {
        try linux.control.lab_runner.appendMicrovmLiveStartEvents(allocator, output, parsed.value, seq);
        try follow_flush.flush(output.items);
        try linux.control.lab_runner.runMicrovmLive(allocator, io, output, parsed.value, seq, true);
        try follow_flush.flush(output.items);
        return;
    }
    if (linux.control.rollback.isRollbackAction(parsed.value.kind)) {
        try linux.control.rollback.handleRollback(allocator, io, output, tracker, parsed.value, seq);
        return;
    }
    if (parsed.value.kind == .incident_drill) {
        const summary_path = try linux.control.lab_runner.runIncidentDrill(allocator, io, output, parsed.value, seq);
        allocator.free(summary_path);
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

fn appendJournalRecord(allocator: std.mem.Allocator, output: *std.ArrayList(u8), action: linux.control.protocol.OperatorAction, git_sha: []const u8, seq: usize) !void {
    var event: std.ArrayList(u8) = .empty;
    defer event.deinit(allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(allocator, &event);
    try linux.control.journal.writeRecord(&writer.writer, seq, action, git_sha);
    event = writer.toArrayList();
    try appendEvent(allocator, output, event.items);
}

fn appendDuplicate(allocator: std.mem.Allocator, output: *std.ArrayList(u8), action: linux.control.protocol.OperatorAction, seq: usize) !void {
    var event: std.ArrayList(u8) = .empty;
    defer event.deinit(allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(allocator, &event);
    try linux.control.journal.writeDuplicateRefusal(&writer.writer, seq, action);
    event = writer.toArrayList();
    try appendEvent(allocator, output, event.items);
}

fn appendInvalidActionId(allocator: std.mem.Allocator, output: *std.ArrayList(u8), action: linux.control.protocol.OperatorAction, seq: usize) !void {
    var event: std.ArrayList(u8) = .empty;
    defer event.deinit(allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(allocator, &event);
    try linux.control.journal.writeInvalidActionIdRefusal(&writer.writer, seq, action);
    event = writer.toArrayList();
    try appendEvent(allocator, output, event.items);
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

fn readGitSha(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const head = std.Io.Dir.cwd().readFileAlloc(io, ".git/HEAD", allocator, .limited(1024)) catch {
        return allocator.dupe(u8, "unknown");
    };
    defer allocator.free(head);
    const trimmed = std.mem.trim(u8, head, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "ref: ")) {
        const ref_path = try std.fmt.allocPrint(allocator, ".git/{s}", .{std.mem.trim(u8, trimmed[5..], " \t\r\n")});
        defer allocator.free(ref_path);
        const ref_value = std.Io.Dir.cwd().readFileAlloc(io, ref_path, allocator, .limited(128)) catch {
            return allocator.dupe(u8, "unknown");
        };
        defer allocator.free(ref_value);
        return allocator.dupe(u8, std.mem.trim(u8, ref_value, " \t\r\n"));
    }
    return allocator.dupe(u8, trimmed);
}

fn flushNewOutput(bytes: []const u8, flushed_bytes: *usize) !void {
    if (flushed_bytes.* >= bytes.len) return;
    try writeStdout(bytes[flushed_bytes.*..]);
    flushed_bytes.* = bytes.len;
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
