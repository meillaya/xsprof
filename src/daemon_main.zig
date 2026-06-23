const std = @import("std");
const linux = @import("linux_scheduler");
const net = std.Io.net;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const options = linux.control.daemon.parseArgs(argv[1..]) catch {
        try writeStderr("usage: zig-scheduler-daemon --foreground [--follow] --state-dir <relative-dir> [--stream-runtime|--replay-runtime <relative-jsonl>] [--stream-from|--from-sample-seq <sequence>] [--replay-events <relative-jsonl>] [--from-event-seq <sequence>] [--socket <relative-sock>]\n");
        std.process.exit(2);
    };
    if (options.socket_path != null) {
        try runSocket(allocator, init.io, init.minimal.environ, options);
    } else {
        try runForeground(allocator, init.io, init.minimal.environ, options);
    }
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
    if (options.replay_events_path) |path| {
        output.clearRetainingCapacity();
        const raw = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(linux.control.daemon.max_journal_bytes));
        defer allocator.free(raw);
        try appendReplayEventsFile(allocator, &output, raw, options.from_event_seq);
        if (options.follow) try follow_flush.flush(output.items) else try writeStdout(output.items);
        try dir.writeFile(io, .{ .sub_path = "events.jsonl", .data = output.items });
        return;
    }
    const git_sha = try linux.control.daemon_dispatch.readGitSha(allocator, io);
    defer allocator.free(git_sha);
    try linux.control.daemon_dispatch.appendReady(allocator, &output, seq);
    seq += 1;
    try follow_flush.flush(output.items);

    if (options.runtime_stream_path) |path| {
        const raw = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(linux.control.daemon.max_journal_bytes));
        defer allocator.free(raw);
        try linux.control.stream.appendRuntimeFile(allocator, &output, raw, &seq, options.from_sample_seq, git_sha);
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

fn runSocket(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, options: linux.control.daemon.Options) !void {
    const socket_path = options.socket_path orelse return error.InvalidArgs;
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, options.state_dir, .{});
    defer dir.close(io);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    var tracker = linux.control.journal.Tracker{};
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
    }
    const git_sha = try linux.control.daemon_dispatch.readGitSha(allocator, io);
    defer allocator.free(git_sha);
    try linux.control.daemon_dispatch.appendReady(allocator, &output, seq);
    seq += 1;
    try dir.writeFile(io, .{ .sub_path = "events.jsonl", .data = output.items });

    try removeSocketPathIfPresent(io, socket_path);
    errdefer removeSocketPathIfPresent(io, socket_path) catch {};
    const address = try net.UnixAddress.init(socket_path);
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    var client = try server.accept(io);
    defer client.close(io);

    var read_buffer: [8192]u8 = undefined;
    var reader = client.reader(io, &read_buffer);
    var write_buffer: [8192]u8 = undefined;
    var socket_writer = client.writer(io, &write_buffer);
    var flushed_bytes: usize = 0;
    var follow_flush = linux.control.daemon_dispatch.FollowFlush{ .enabled = false, .flushed_bytes = &flushed_bytes };

    while (try reader.interface.takeDelimiter('\n')) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        var response: std.ArrayList(u8) = .empty;
        defer response.deinit(allocator);
        try handleRpcLine(allocator, io, environ, &output, &tracker, &dir, git_sha, trimmed, &seq, &follow_flush, &response);
        try socket_writer.interface.writeAll(response.items);
        try socket_writer.interface.writeByte('\n');
        try socket_writer.interface.flush();
    }
    try removeSocketPathIfPresent(io, socket_path);
}

fn removeSocketPathIfPresent(io: std.Io, socket_path: []const u8) !void {
    const stat = std.Io.Dir.cwd().statFile(io, socket_path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |e| return e,
    };
    if (stat.kind != .unix_domain_socket) return error.InvalidSocketPath;
    try std.Io.Dir.cwd().deleteFile(io, socket_path);
}

fn appendReplayEventsFile(allocator: std.mem.Allocator, output: *std.ArrayList(u8), file_bytes: []const u8, from_event_seq: usize) !void {
    var previous_seq: usize = 0;
    var lines = std.mem.splitScalar(u8, file_bytes, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const seq = try validateReplayEventRow(allocator, trimmed);
        if (seq <= previous_seq) return error.InvalidJson;
        previous_seq = seq;
        if (seq < from_event_seq) continue;
        try linux.control.daemon.ensureCanWriteEvent(output.items.len, trimmed);
        try output.appendSlice(allocator, trimmed);
        try output.append(allocator, '\n');
    }
}

fn validateReplayEventRow(allocator: std.mem.Allocator, line: []const u8) !usize {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{
        .allocate = .alloc_always,
    }) catch return error.InvalidJson;
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidJson,
    };
    var it = object.iterator();
    while (it.next()) |entry| {
        if (!isReplayEventSchemaField(entry.key_ptr.*)) return error.InvalidJson;
        try validateReplayEventField(entry.key_ptr.*, entry.value_ptr.*);
    }
    const schema = stringField(object.get("schema") orelse return error.InvalidJson) orelse return error.InvalidJson;
    const event = stringField(object.get("event") orelse return error.InvalidJson) orelse return error.InvalidJson;
    _ = stringField(object.get("status") orelse return error.InvalidJson) orelse return error.InvalidJson;
    const host_mutation = boolField(object.get("host_mutation") orelse return error.InvalidJson) orelse return error.InvalidJson;
    const seq = usizeField(object.get("seq") orelse return error.InvalidJson) orelse return error.InvalidJson;
    if (!std.mem.eql(u8, schema, linux.control.protocol.event_schema)) return error.InvalidJson;
    if (!isReplayEventKind(event)) return error.InvalidJson;
    if (host_mutation) return error.InvalidJson;
    if (seq == 0) return error.InvalidJson;
    return seq;
}

fn validateReplayEventField(name: []const u8, value: std.json.Value) !void {
    if (std.mem.eql(u8, name, "seq") or std.mem.eql(u8, name, "sample_sequence")) {
        _ = usizeField(value) orelse return error.InvalidJson;
    } else if (std.mem.eql(u8, name, "host_mutation") or std.mem.eql(u8, name, "workload_alive")) {
        _ = boolField(value) orelse return error.InvalidJson;
    } else if (std.mem.eql(u8, name, "artifact_paths")) {
        const array = switch (value) {
            .array => |array| array,
            else => return error.InvalidJson,
        };
        for (array.items) |item| {
            _ = stringField(item) orelse return error.InvalidJson;
        }
    } else if (std.mem.eql(u8, name, "action_id") or std.mem.eql(u8, name, "target_id") or std.mem.eql(u8, name, "rollback_id") or std.mem.eql(u8, name, "target_action_id")) {
        const text = stringField(value) orelse return error.InvalidJson;
        if (!isOptionalIdentifier(text)) return error.InvalidJson;
    } else if (std.mem.eql(u8, name, "run_id")) {
        const text = stringField(value) orelse return error.InvalidJson;
        if (text.len > 96) return error.InvalidJson;
    } else if (std.mem.eql(u8, name, "audit_id")) {
        const text = stringField(value) orelse return error.InvalidJson;
        if (!isAuditId(text)) return error.InvalidJson;
    } else if (std.mem.eql(u8, name, "replay_cursor")) {
        const text = stringField(value) orelse return error.InvalidJson;
        if (!std.mem.eql(u8, text, "event_seq") and !std.mem.eql(u8, text, "runtime_sample_sequence")) return error.InvalidJson;
    } else if (std.mem.eql(u8, name, "lifecycle_source")) {
        const text = stringField(value) orelse return error.InvalidJson;
        if (!std.mem.eql(u8, text, "runner_stream")) return error.InvalidJson;
    } else {
        _ = stringField(value) orelse return error.InvalidJson;
    }
}

fn isOptionalIdentifier(text: []const u8) bool {
    if (text.len > 96) return false;
    for (text) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and byte != '.') return false;
    }
    return true;
}

fn isAuditId(text: []const u8) bool {
    if (text.len == 0) return true;
    if (text.len < "AUD-YYYYMMDDTHHMMSSZ-a".len or !std.mem.startsWith(u8, text, "AUD-")) return false;
    if (text[12] != 'T' or text[19] != 'Z' or text[20] != '-') return false;
    for (text[4..12]) |byte| {
        if (!std.ascii.isDigit(byte)) return false;
    }
    for (text[13..19]) |byte| {
        if (!std.ascii.isDigit(byte)) return false;
    }
    for (text[21..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and byte != '.') return false;
    }
    return true;
}

fn isReplayEventSchemaField(name: []const u8) bool {
    const fields = .{
        "schema",
        "seq",
        "event",
        "action",
        "action_id",
        "status",
        "state",
        "run_id",
        "target_id",
        "audit_id",
        "rollback_id",
        "reason",
        "live_bundle_path",
        "sample_sequence",
        "scheduler_state",
        "ops",
        "enable_seq",
        "events_hash",
        "nr_rejected",
        "cgroup_membership_digest",
        "workload_alive",
        "host_mutation",
        "git_sha",
        "command_argv_hash",
        "artifact_paths",
        "cleanup",
        "artifact",
        "target_action_id",
        "replay_cursor",
        "lifecycle_source",
    };
    inline for (fields) |field| {
        if (std.mem.eql(u8, name, field)) return true;
    }
    return false;
}

fn isReplayEventKind(event: []const u8) bool {
    inline for (std.meta.fields(linux.control.protocol.EventKind)) |field| {
        if (std.mem.eql(u8, event, field.name)) return true;
    }
    return false;
}

fn stringField(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn boolField(value: std.json.Value) ?bool {
    return switch (value) {
        .bool => |flag| flag,
        else => null,
    };
}

fn usizeField(value: std.json.Value) ?usize {
    const raw = switch (value) {
        .integer => |number| number,
        else => return null,
    };
    if (raw < 0) return null;
    return @intCast(raw);
}

const RpcParams = struct {
    action_json: ?[]const u8 = null,
    from_event_seq: ?usize = null,
};

const RpcRequest = struct {
    jsonrpc: []const u8,
    id: ?[]const u8 = null,
    method: []const u8,
    params: ?RpcParams = null,
};

fn handleRpcLine(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    output: *std.ArrayList(u8),
    tracker: *linux.control.journal.Tracker,
    state_dir: *std.Io.Dir,
    git_sha: []const u8,
    line: []const u8,
    seq: *usize,
    follow_flush: *linux.control.daemon_dispatch.FollowFlush,
    response: *std.ArrayList(u8),
) !void {
    var parsed = std.json.parseFromSlice(RpcRequest, allocator, line, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
    }) catch {
        try writeRpcError(allocator, response, null, -32700, "parse_error", "malformed_rpc");
        return;
    };
    defer parsed.deinit();
    const request = parsed.value;
    if (!std.mem.eql(u8, request.jsonrpc, "2.0")) {
        try writeRpcError(allocator, response, request.id, -32600, "invalid_request", "invalid_rpc_version");
        return;
    }
    if (std.mem.eql(u8, request.method, "daemon.version")) {
        try writeRpcResultRaw(allocator, response, request.id, "{\"daemon\":\"zig-scheduler-daemon\",\"jsonrpc\":\"2.0\",\"event_schema\":\"zig-scheduler/daemon-event/v1\",\"action_schema\":\"zig-scheduler/operator-action/v1\",\"runtime_sample_schema\":\"zig-scheduler/runtime-sample/v1\",\"host_mutation\":false}");
    } else if (std.mem.eql(u8, request.method, "targets.list")) {
        try writeTargetsResult(allocator, response, request.id, tracker);
    } else if (std.mem.eql(u8, request.method, "events.replay") or std.mem.eql(u8, request.method, "events.follow")) {
        const from_event_seq = if (request.params) |params| params.from_event_seq orelse 1 else 1;
        const events = try filterEventsFromSeq(allocator, output.items, from_event_seq);
        defer allocator.free(events);
        try writeEventsResult(allocator, response, request.id, events);
    } else if (std.mem.eql(u8, request.method, "actions.submit") or std.mem.eql(u8, request.method, "actions.rollback") or std.mem.eql(u8, request.method, "actions.stop")) {
        const action_json = if (request.params) |params| params.action_json orelse "" else "";
        if (action_json.len == 0) {
            try writeRpcError(allocator, response, request.id, -32602, "invalid_params", "action_json_required");
            return;
        }
        if (!try rpcMethodAcceptsAction(allocator, request.method, action_json)) {
            try writeRpcError(allocator, response, request.id, -32602, "invalid_params", "rpc_action_mismatch");
            return;
        }
        const before = output.items.len;
        try linux.control.daemon_dispatch.appendAction(allocator, io, environ, output, tracker, state_dir, git_sha, action_json, seq, follow_flush);
        try state_dir.writeFile(io, .{ .sub_path = "events.jsonl", .data = output.items });
        try writeEventsResult(allocator, response, request.id, output.items[before..]);
    } else {
        try writeRpcError(allocator, response, request.id, -32601, "method_not_found", "unknown_rpc_method");
    }
}

fn rpcMethodAcceptsAction(allocator: std.mem.Allocator, method: []const u8, action_json: []const u8) !bool {
    if (std.mem.eql(u8, method, "actions.submit")) return true;
    var parsed = linux.control.protocol.parseActionJson(allocator, action_json) catch return true;
    defer parsed.deinit();
    if (std.mem.eql(u8, method, "actions.rollback")) return parsed.value.kind == .rollback or parsed.value.kind == .rollback_lab_run;
    if (std.mem.eql(u8, method, "actions.stop")) return parsed.value.kind == .stop or parsed.value.kind == .stop_lab_run;
    return false;
}

fn filterEventsFromSeq(allocator: std.mem.Allocator, events: []const u8, from_event_seq: usize) ![]u8 {
    var filtered: std.ArrayList(u8) = .empty;
    errdefer filtered.deinit(allocator);
    try appendReplayEventsFile(allocator, &filtered, events, from_event_seq);
    return filtered.toOwnedSlice(allocator);
}

fn writeTargetsResult(allocator: std.mem.Allocator, response: *std.ArrayList(u8), id: ?[]const u8, tracker: *const linux.control.journal.Tracker) !void {
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(allocator, &result);
    try writer.writer.writeAll("{\"active_targets\":[");
    var first = true;
    for (tracker.labs.items) |lab| {
        if (lab.status != .active) continue;
        if (!first) try writer.writer.writeByte(',');
        first = false;
        try writer.writer.writeAll("{\"action_id\":");
        try writeJsonString(&writer.writer, lab.action_id);
        try writer.writer.writeAll(",\"target_id\":");
        try writeJsonString(&writer.writer, lab.target_id);
        try writer.writer.writeAll(",\"rollback_id\":");
        try writeJsonString(&writer.writer, lab.rollback_id);
        try writer.writer.writeByte('}');
    }
    try writer.writer.writeAll("],\"host_mutation\":false}");
    result = writer.toArrayList();
    try writeRpcResultRaw(allocator, response, id, result.items);
}

fn writeEventsResult(allocator: std.mem.Allocator, response: *std.ArrayList(u8), id: ?[]const u8, events: []const u8) !void {
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(allocator, &result);
    try writer.writer.writeAll("{\"events_jsonl\":");
    try writeJsonString(&writer.writer, events);
    try writer.writer.writeAll(",\"host_mutation\":false}");
    result = writer.toArrayList();
    try writeRpcResultRaw(allocator, response, id, result.items);
}

fn writeRpcResultRaw(allocator: std.mem.Allocator, response: *std.ArrayList(u8), id: ?[]const u8, result_json: []const u8) !void {
    var writer = std.Io.Writer.Allocating.fromArrayList(allocator, response);
    try writer.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeRpcId(&writer.writer, id);
    try writer.writer.writeAll(",\"result\":");
    try writer.writer.writeAll(result_json);
    try writer.writer.writeByte('}');
    response.* = writer.toArrayList();
}

fn writeRpcError(allocator: std.mem.Allocator, response: *std.ArrayList(u8), id: ?[]const u8, code: i32, message: []const u8, incident_code: []const u8) !void {
    var writer = std.Io.Writer.Allocating.fromArrayList(allocator, response);
    try writer.writer.print("{{\"jsonrpc\":\"2.0\",\"id\":", .{});
    try writeRpcId(&writer.writer, id);
    try writer.writer.print(",\"error\":{{\"code\":{d},\"message\":", .{code});
    try writeJsonString(&writer.writer, message);
    try writer.writer.writeAll(",\"data\":{\"incident_code\":");
    try writeJsonString(&writer.writer, incident_code);
    try writer.writer.writeAll(",\"host_mutation\":false}}}");
    response.* = writer.toArrayList();
}

fn writeRpcId(writer: anytype, id: ?[]const u8) !void {
    if (id) |value| {
        try writeJsonString(writer, value);
    } else {
        try writer.writeAll("null");
    }
}

fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |byte| switch (byte) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => if (byte < 0x20) try writer.print("\\u{x:0>4}", .{byte}) else try writer.writeByte(byte),
    };
    try writer.writeByte('"');
}

fn writeStdout(bytes: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), bytes);
}

fn writeStderr(bytes: []const u8) !void {
    try std.Io.File.stderr().writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), bytes);
}

test "daemon executable links control module" {
    _ = try linux.control.daemon.parseArgs(&.{ "--foreground", "--state-dir", ".omo/evidence/task-T08-state" });
    _ = try linux.control.daemon.parseArgs(&.{ "--foreground", "--state-dir", ".zig-cache/tmp/socket-state", "--socket", ".zig-cache/tmp/socket-state/daemon.sock" });
    try std.testing.expectError(error.InvalidSocketPath, linux.control.daemon.parseArgs(&.{ "--foreground", "--state-dir", ".zig-cache/tmp/socket-state", "--socket", ".zig-cache/tmp/not-in-state.sock" }));
}
