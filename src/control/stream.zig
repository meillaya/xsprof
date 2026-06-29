const std = @import("std");
const daemon = @import("daemon.zig");
const protocol = @import("protocol.zig");

pub const StreamError = error{ InvalidRuntimeSample, PrivacyUnsafe, OutOfMemory } || std.Io.Writer.Error;

pub const max_stream_events: usize = 64;
const sample_schema = "zig-scheduler/runtime-sample/v1";

const Fact = struct {
    status: []const u8,
    value: []const u8,
};

const RawSample = struct {
    schema: []const u8,
    sequence: usize,
    git_sha: ?[]const u8 = null,
    state: Fact,
    ops: Fact,
    enable_seq: Fact,
    events: Fact,
    events_hash: []const u8,
    nr_rejected: Fact,
    debug_dump: Fact,
    cgroup_membership_digest: []const u8,
    workload_alive: bool,
    private_command_lines_sampled: bool,
    command_line: ?[]const u8 = null,
    cmdline: ?[]const u8 = null,
    argv: ?[]const []const u8 = null,
    env: ?[]const u8 = null,
    environment: ?[]const u8 = null,
    secret: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
};

pub fn appendRuntimeFile(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    file_bytes: []const u8,
    next_seq: *usize,
    replay_from: usize,
    current_git_sha: []const u8,
) !void {
    var emitted: usize = 0;
    var lines = std.mem.splitScalar(u8, file_bytes, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (emitted >= max_stream_events) {
            try appendDropped(allocator, output, next_seq.*);
            next_seq.* += 1;
            return;
        }
        try appendRuntimeLine(allocator, output, trimmed, next_seq, replay_from, current_git_sha);
        emitted += 1;
    }
}

pub fn appendRuntimeLine(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    line: []const u8,
    next_seq: *usize,
    replay_from: usize,
    current_git_sha: []const u8,
) !void {
    const parsed = parseSample(allocator, line) catch |err| {
        const reason = if (err == error.PrivacyUnsafe) "private_fields_rejected" else "malformed_runtime_sample";
        try appendIncident(allocator, output, next_seq.*, reason);
        next_seq.* += 1;
        return;
    };
    defer parsed.deinit();
    if (parsed.value.sequence < replay_from) return;
    if (parsed.value.git_sha) |seen| {
        if (!std.mem.eql(u8, seen, current_git_sha)) {
            try appendIncident(allocator, output, next_seq.*, "stale_git_sha");
            next_seq.* += 1;
            return;
        }
    }
    try appendSample(allocator, output, next_seq.*, parsed.value);
    next_seq.* += 1;
    if (sampleHasRejectedDispatches(parsed.value)) {
        try appendIncident(allocator, output, next_seq.*, "runtime_nr_rejected_nonzero");
        next_seq.* += 1;
    }
    if (!parsed.value.workload_alive) {
        try appendIncident(allocator, output, next_seq.*, "runtime_workload_dead");
        next_seq.* += 1;
    }
}

fn parseSample(allocator: std.mem.Allocator, line: []const u8) StreamError!std.json.Parsed(RawSample) {
    const parsed = std.json.parseFromSlice(RawSample, allocator, line, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
    }) catch return error.InvalidRuntimeSample;
    errdefer parsed.deinit();
    const raw = parsed.value;
    if (!std.mem.eql(u8, raw.schema, sample_schema)) return error.InvalidRuntimeSample;
    if (raw.private_command_lines_sampled) return error.PrivacyUnsafe;
    if (raw.command_line != null or raw.cmdline != null or raw.argv != null) return error.PrivacyUnsafe;
    if (raw.env != null or raw.environment != null or raw.secret != null or raw.api_key != null) return error.PrivacyUnsafe;
    try requireSafeFact(raw.state);
    try requireSafeFact(raw.ops);
    try requireSafeFact(raw.enable_seq);
    try requireSafeFact(raw.events);
    try requireSafeFact(raw.nr_rejected);
    try requireSafeFact(raw.debug_dump);
    return parsed;
}

fn requireSafeFact(fact: Fact) StreamError!void {
    if (fact.status.len == 0) return error.InvalidRuntimeSample;
    if (hasPrivateNeedle(fact.value)) return error.PrivacyUnsafe;
}

fn hasPrivateNeedle(value: []const u8) bool {
    const needles = [_][]const u8{ "cmdline", "command_line", "argv", "environment", "\"env\"", "secret", "api_key", "--token", "password=" };
    for (needles) |needle| {
        if (std.ascii.indexOfIgnoreCase(value, needle) != null) return true;
    }
    return false;
}

fn sampleHasRejectedDispatches(sample: RawSample) bool {
    if (!std.mem.eql(u8, sample.nr_rejected.status, "present")) return false;
    const value = std.mem.trim(u8, sample.nr_rejected.value, " \t\r\n");
    if (value.len == 0) return false;
    const parsed = std.fmt.parseUnsigned(u64, value, 10) catch return !std.mem.eql(u8, value, "0");
    return parsed != 0;
}

fn appendSample(allocator: std.mem.Allocator, output: *std.ArrayList(u8), seq: usize, sample: RawSample) !void {
    var event: std.ArrayList(u8) = .empty;
    defer event.deinit(allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(allocator, &event);
    try writer.writer.print(
        "{{\"schema\":\"{s}\",\"seq\":{d},\"event\":\"runtime_sample\",\"state\":\"observing\",\"status\":\"accepted\",\"sample_sequence\":{d},\"scheduler_state\":",
        .{ protocol.event_schema, seq, sample.sequence },
    );
    try writeJsonString(&writer.writer, sample.state.value);
    try writer.writer.writeAll(",\"ops\":");
    try writeJsonString(&writer.writer, sample.ops.value);
    try writer.writer.writeAll(",\"enable_seq\":");
    try writeJsonString(&writer.writer, sample.enable_seq.value);
    try writer.writer.writeAll(",\"events_hash\":");
    try writeJsonString(&writer.writer, sample.events_hash);
    try writer.writer.writeAll(",\"nr_rejected\":");
    try writeJsonString(&writer.writer, sample.nr_rejected.value);
    try writer.writer.writeAll(",\"cgroup_membership_digest\":");
    try writeJsonString(&writer.writer, sample.cgroup_membership_digest);
    try writer.writer.print(",\"workload_alive\":{},\"host_mutation\":false}}\n", .{sample.workload_alive});
    event = writer.toArrayList();
    try daemon.ensureCanWriteEvent(output.items.len, event.items);
    try output.appendSlice(allocator, event.items);
}

fn appendIncident(allocator: std.mem.Allocator, output: *std.ArrayList(u8), seq: usize, reason: []const u8) !void {
    var event: std.ArrayList(u8) = .empty;
    defer event.deinit(allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(allocator, &event);
    try writer.writer.print(
        "{{\"schema\":\"{s}\",\"seq\":{d},\"event\":\"incident\",\"state\":\"unsafe_to_assume\",\"status\":\"unsafe_to_assume\",\"reason\":\"{s}\",\"host_mutation\":false}}\n",
        .{ protocol.event_schema, seq, reason },
    );
    event = writer.toArrayList();
    try daemon.ensureCanWriteEvent(output.items.len, event.items);
    try output.appendSlice(allocator, event.items);
}

fn appendDropped(allocator: std.mem.Allocator, output: *std.ArrayList(u8), seq: usize) !void {
    try appendIncident(allocator, output, seq, "stream_backpressure_dropped");
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

test "runtime stream accepts good samples and sanitizes private failures" {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    var seq: usize = 1;
    try appendRuntimeLine(std.testing.allocator, &output, goodSample(0), &seq, 0, "sha");
    try appendRuntimeLine(std.testing.allocator, &output, "{malformed", &seq, 0, "sha");
    try appendRuntimeLine(std.testing.allocator, &output, goodSampleWithPrivate(), &seq, 0, "sha");
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"event\":\"runtime_sample\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "unsafe_to_assume") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "cmdline") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"env\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "host_mutation\":false") != null);
}

test "runtime stream supports replay offsets stale git and bounded drops" {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    var seq: usize = 1;
    try appendRuntimeLine(std.testing.allocator, &output, goodSample(1), &seq, 2, "sha");
    try std.testing.expectEqual(@as(usize, 1), seq);
    try appendRuntimeLine(std.testing.allocator, &output, goodSampleWithGit("old"), &seq, 0, "sha");
    try std.testing.expect(std.mem.indexOf(u8, output.items, "stale_git_sha") != null);
    var file: std.ArrayList(u8) = .empty;
    defer file.deinit(std.testing.allocator);
    for (0..max_stream_events + 2) |i| {
        try file.appendSlice(std.testing.allocator, goodSample(i));
        try file.append(std.testing.allocator, '\n');
    }
    try appendRuntimeFile(std.testing.allocator, &output, file.items, &seq, 0, "sha");
    try std.testing.expect(std.mem.indexOf(u8, output.items, "stream_backpressure_dropped") != null);
}

test "runtime stream emits ordered alerts after accepted samples" {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    var seq: usize = 1;
    try appendRuntimeLine(std.testing.allocator, &output, sampleWithRejectedDispatches(), &seq, 0, "sha");
    try appendRuntimeLine(std.testing.allocator, &output, sampleWithDeadWorkload(), &seq, 0, "sha");
    const rejected_sample = std.mem.indexOf(u8, output.items, "\"sample_sequence\":3") orelse return error.TestExpectedRuntimeAlertSample;
    const rejected_incident = std.mem.indexOf(u8, output.items, "runtime_nr_rejected_nonzero") orelse return error.TestExpectedRuntimeAlertIncident;
    const dead_sample = std.mem.indexOf(u8, output.items, "\"sample_sequence\":4") orelse return error.TestExpectedRuntimeAlertSample;
    const dead_incident = std.mem.indexOf(u8, output.items, "runtime_workload_dead") orelse return error.TestExpectedRuntimeAlertIncident;
    try std.testing.expect(rejected_sample < rejected_incident);
    try std.testing.expect(dead_sample < dead_incident);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "host_mutation\":false") != null);
}

fn goodSample(sequence: usize) []const u8 {
    return switch (sequence) {
        1 => "{\"schema\":\"zig-scheduler/runtime-sample/v1\",\"sequence\":1,\"state\":{\"status\":\"present\",\"value\":\"enabled\"},\"ops\":{\"status\":\"present\",\"value\":\"zigsched_minimal\"},\"enable_seq\":{\"status\":\"present\",\"value\":\"42\"},\"events\":{\"status\":\"present\",\"value\":\"nr_rejected: 0\"},\"events_hash\":\"ab12\",\"nr_rejected\":{\"status\":\"present\",\"value\":\"0\"},\"debug_dump\":{\"status\":\"missing\",\"value\":\"\"},\"cgroup_membership_digest\":\"digest\",\"workload_alive\":true,\"private_command_lines_sampled\":false}",
        else => "{\"schema\":\"zig-scheduler/runtime-sample/v1\",\"sequence\":0,\"state\":{\"status\":\"present\",\"value\":\"enabled\"},\"ops\":{\"status\":\"present\",\"value\":\"zigsched_minimal\"},\"enable_seq\":{\"status\":\"present\",\"value\":\"42\"},\"events\":{\"status\":\"present\",\"value\":\"nr_rejected: 0\"},\"events_hash\":\"ab12\",\"nr_rejected\":{\"status\":\"present\",\"value\":\"0\"},\"debug_dump\":{\"status\":\"missing\",\"value\":\"\"},\"cgroup_membership_digest\":\"digest\",\"workload_alive\":true,\"private_command_lines_sampled\":false}",
    };
}

fn goodSampleWithPrivate() []const u8 {
    return "{\"schema\":\"zig-scheduler/runtime-sample/v1\",\"sequence\":1,\"cmdline\":\"demo\",\"state\":{\"status\":\"present\",\"value\":\"enabled\"},\"ops\":{\"status\":\"present\",\"value\":\"zigsched_minimal\"},\"enable_seq\":{\"status\":\"present\",\"value\":\"42\"},\"events\":{\"status\":\"present\",\"value\":\"nr_rejected: 0\"},\"events_hash\":\"ab12\",\"nr_rejected\":{\"status\":\"present\",\"value\":\"0\"},\"debug_dump\":{\"status\":\"missing\",\"value\":\"\"},\"cgroup_membership_digest\":\"digest\",\"workload_alive\":true,\"private_command_lines_sampled\":false}";
}

fn goodSampleWithUppercasePrivateValue() []const u8 {
    return "{\"schema\":\"zig-scheduler/runtime-sample/v1\",\"sequence\":1,\"state\":{\"status\":\"present\",\"value\":\"PASSWORD=secret\"},\"ops\":{\"status\":\"present\",\"value\":\"zigsched_minimal\"},\"enable_seq\":{\"status\":\"present\",\"value\":\"42\"},\"events\":{\"status\":\"present\",\"value\":\"nr_rejected: 0\"},\"events_hash\":\"ab12\",\"nr_rejected\":{\"status\":\"present\",\"value\":\"0\"},\"debug_dump\":{\"status\":\"missing\",\"value\":\"\"},\"cgroup_membership_digest\":\"digest\",\"workload_alive\":true,\"private_command_lines_sampled\":false}";
}

fn goodSampleWithGit(git_sha: []const u8) []const u8 {
    _ = git_sha;
    return "{\"schema\":\"zig-scheduler/runtime-sample/v1\",\"sequence\":2,\"git_sha\":\"old\",\"state\":{\"status\":\"present\",\"value\":\"enabled\"},\"ops\":{\"status\":\"present\",\"value\":\"zigsched_minimal\"},\"enable_seq\":{\"status\":\"present\",\"value\":\"42\"},\"events\":{\"status\":\"present\",\"value\":\"nr_rejected: 0\"},\"events_hash\":\"ab12\",\"nr_rejected\":{\"status\":\"present\",\"value\":\"0\"},\"debug_dump\":{\"status\":\"missing\",\"value\":\"\"},\"cgroup_membership_digest\":\"digest\",\"workload_alive\":true,\"private_command_lines_sampled\":false}";
}

fn sampleWithRejectedDispatches() []const u8 {
    return "{\"schema\":\"zig-scheduler/runtime-sample/v1\",\"sequence\":3,\"state\":{\"status\":\"present\",\"value\":\"enabled\"},\"ops\":{\"status\":\"present\",\"value\":\"zigsched_minimal\"},\"enable_seq\":{\"status\":\"present\",\"value\":\"42\"},\"events\":{\"status\":\"present\",\"value\":\"nr_rejected: 3\"},\"events_hash\":\"reject33\",\"nr_rejected\":{\"status\":\"present\",\"value\":\"3\"},\"debug_dump\":{\"status\":\"missing\",\"value\":\"\"},\"cgroup_membership_digest\":\"digest-reject\",\"workload_alive\":true,\"private_command_lines_sampled\":false}";
}

fn sampleWithDeadWorkload() []const u8 {
    return "{\"schema\":\"zig-scheduler/runtime-sample/v1\",\"sequence\":4,\"state\":{\"status\":\"present\",\"value\":\"enabled\"},\"ops\":{\"status\":\"present\",\"value\":\"zigsched_minimal\"},\"enable_seq\":{\"status\":\"present\",\"value\":\"42\"},\"events\":{\"status\":\"present\",\"value\":\"nr_rejected: 0\"},\"events_hash\":\"dead44\",\"nr_rejected\":{\"status\":\"present\",\"value\":\"0\"},\"debug_dump\":{\"status\":\"missing\",\"value\":\"\"},\"cgroup_membership_digest\":\"digest-dead\",\"workload_alive\":false,\"private_command_lines_sampled\":false}";
}
