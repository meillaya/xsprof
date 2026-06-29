const std = @import("std");
const daemon = @import("daemon.zig");
const protocol = @import("protocol.zig");

pub const StreamError = error{ InvalidRuntimeSample, PrivacyUnsafe, OutOfMemory } || std.Io.Writer.Error;

pub const max_stream_events: usize = 64;
const sample_schema = "zig-scheduler/runtime-sample/v1";
const sha256_hex_len: usize = 64;
const sha256_zero = "0" ** sha256_hex_len;

const Fact = struct {
    status: []const u8,
    value: []const u8,
};

const PolicyCounters = struct {
    nr_rejected: u64,
    dispatch_failed: u64,
    fallback: u64,
    fatal: u64,
};

const SampleLoss = struct {
    lost_samples: u64,
    backpressure_dropped: u64,
};

const PolicyAbi = struct {
    policy_name: []const u8,
    policy_version: []const u8,
    struct_ops: []const u8,
    object_sha256: []const u8,
    btf_required: bool,
};

const RawSample = struct {
    schema: []const u8,
    sequence: usize,
    git_sha: ?[]const u8 = null,
    sample_source_event: ?[]const u8 = null,
    observation_source: ?[]const u8 = null,
    state: Fact,
    ops: Fact,
    enable_seq: Fact,
    events: Fact,
    events_hash: []const u8,
    nr_rejected: Fact,
    debug_dump: Fact,
    root_ops: ?Fact = null,
    scheduler_events: ?Fact = null,
    policy_counters: ?PolicyCounters = null,
    sample_loss: ?SampleLoss = null,
    policy_abi: PolicyAbi,
    cgroup_membership_digest: []const u8,
    cgroup_membership_status: ?Fact = null,
    workload: ?Fact = null,
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
    if (sampleHasLoss(parsed.value)) {
        try appendIncident(allocator, output, next_seq.*, "runtime_sample_loss");
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
    if (!std.mem.eql(u8, raw.debug_dump.status, "missing") and !std.mem.eql(u8, raw.debug_dump.status, "unknown")) {
        if (!std.mem.startsWith(u8, raw.debug_dump.value, "sha256:") or std.mem.indexOf(u8, raw.debug_dump.value, ";bytes:") == null) return error.InvalidRuntimeSample;
    }
    if (raw.root_ops) |fact| try requireSafeFact(fact);
    if (raw.scheduler_events) |fact| try requireSafeFact(fact);
    if (raw.cgroup_membership_status) |fact| try requireSafeFact(fact);
    if (raw.workload) |fact| try requireSafeFact(fact);
    try requireSafePolicyAbi(raw.policy_abi);
    try requireSha256Digest(raw.cgroup_membership_digest);
    return parsed;
}

fn requireSafePolicyAbi(abi: PolicyAbi) StreamError!void {
    try requireSafeText(abi.policy_name);
    try requireSafeText(abi.policy_version);
    try requireSafeText(abi.struct_ops);
    try requireSafeText(abi.object_sha256);
    if (abi.policy_name.len == 0 or abi.policy_version.len == 0 or abi.struct_ops.len == 0 or abi.object_sha256.len == 0) return error.InvalidRuntimeSample;
}

fn requireSha256Digest(value: []const u8) StreamError!void {
    if (value.len != sha256_hex_len or std.mem.eql(u8, value, sha256_zero)) return error.InvalidRuntimeSample;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) return error.InvalidRuntimeSample;
    }
}

fn requireSafeFact(fact: Fact) StreamError!void {
    if (!validFactStatus(fact.status)) return error.InvalidRuntimeSample;
    if (std.mem.eql(u8, fact.status, "present") and fact.value.len == 0) return error.InvalidRuntimeSample;
    try requireSafeText(fact.value);
}

fn requireSafeText(value: []const u8) StreamError!void {
    if (hasPrivateNeedle(value)) return error.PrivacyUnsafe;
}

fn validFactStatus(status: []const u8) bool {
    return std.mem.eql(u8, status, "present") or
        std.mem.eql(u8, status, "missing") or
        std.mem.eql(u8, status, "unreadable") or
        std.mem.eql(u8, status, "unknown");
}

fn hasPrivateNeedle(value: []const u8) bool {
    const needles = [_][]const u8{ "cmdline", "command_line", "argv", "environment", "\"env\"", "secret", "api_key", "--token", "password=", "/proc/", "/sys/" };
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

fn sampleHasLoss(sample: RawSample) bool {
    if (sample.sample_loss) |loss| {
        return loss.lost_samples != 0 or loss.backpressure_dropped != 0;
    }
    return false;
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

test "runtime stream behavior tests are linked" {
    std.testing.refAllDecls(@import("stream_tests.zig"));
}
