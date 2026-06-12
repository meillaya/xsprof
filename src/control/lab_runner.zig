const std = @import("std");
const commands = @import("commands.zig");
const protocol = @import("protocol.zig");

pub const RunError = error{
    InvalidAction,
    InvalidField,
    InvalidSummary,
    OutOfMemory,
    StreamTooLong,
} || std.process.SpawnError || std.Io.File.MultiReader.UnendingError || std.Io.Timeout.Error || std.Io.Dir.ReadFileAllocError || std.Io.Writer.Error;

const RawStage = struct {
    stage: []const u8,
    status: []const u8,
    reason: []const u8,
    artifact: []const u8,
};

const RawSummary = struct {
    stages: []RawStage,
};

pub fn runHostSafe(
    allocator: std.mem.Allocator,
    io: std.Io,
    output: *std.ArrayList(u8),
    action: protocol.OperatorAction,
    seq: *usize,
) RunError!void {
    var plan = try commands.buildLabCommand(allocator, action);
    defer plan.deinit(allocator);
    try appendEvent(allocator, output, seq, "stage_started", @tagName(action.kind), "queued", "read_only", "", "");

    var env_map = try buildEnv(allocator, plan.env);
    defer env_map.deinit();
    const result = try std.process.run(allocator, io, .{
        .argv = plan.args(),
        .environ_map = &env_map,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(256 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const summary_path = try std.fmt.allocPrint(allocator, "{s}/summary.json", .{plan.out_dir});
    defer allocator.free(summary_path);
    if (result.term != .exited or result.term.exited != 0) {
        try appendEvent(allocator, output, seq, "incident", @tagName(action.kind), "REFUSE", "incident", "lab harness returned nonzero", summary_path);
        return;
    }
    try appendSummaryStages(allocator, io, output, seq, summary_path);
    try appendEvent(allocator, output, seq, "stage_finished", @tagName(action.kind), "PASS", "read_only", "host-safe lab summary captured", summary_path);
}

pub fn runVmFixture(
    allocator: std.mem.Allocator,
    io: std.Io,
    output: *std.ArrayList(u8),
    action: protocol.OperatorAction,
    seq: *usize,
) RunError![]u8 {
    var plan = try commands.buildLabCommand(allocator, action);
    defer plan.deinit(allocator);
    try appendEvent(allocator, output, seq, "stage_started", @tagName(action.kind), "queued", "verifier_only", "", "");
    var env_map = try buildEnv(allocator, plan.env);
    defer env_map.deinit();
    const result = try std.process.run(allocator, io, .{
        .argv = plan.args(),
        .environ_map = &env_map,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(256 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const summary_path = try std.fmt.allocPrint(allocator, "{s}/summary.json", .{plan.out_dir});
    errdefer allocator.free(summary_path);
    if (result.term != .exited or result.term.exited != 0) {
        try appendEvent(allocator, output, seq, "incident", @tagName(action.kind), "REFUSE", "incident", "VM lab harness refused", summary_path);
        return error.InvalidSummary;
    }
    try appendSummaryStages(allocator, io, output, seq, summary_path);
    try appendEvent(allocator, output, seq, "stage_finished", @tagName(action.kind), "PASS", "partial_switch_lab", "fixture VM lab summary captured", summary_path);
    return summary_path;
}

pub fn runRollbackDrill(
    allocator: std.mem.Allocator,
    io: std.Io,
    output: *std.ArrayList(u8),
    action: protocol.OperatorAction,
    seq: *usize,
) RunError![]u8 {
    var plan = try commands.buildLabCommand(allocator, action);
    defer plan.deinit(allocator);
    try appendEvent(allocator, output, seq, "stage_started", @tagName(action.kind), "queued", "rollback_pending", "", "");
    var env_map = try buildEnv(allocator, plan.env);
    defer env_map.deinit();
    const result = try std.process.run(allocator, io, .{
        .argv = plan.args(),
        .environ_map = &env_map,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(256 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const summary_path = try std.fmt.allocPrint(allocator, "{s}/summary.json", .{plan.out_dir});
    errdefer allocator.free(summary_path);
    if (result.term != .exited or result.term.exited != 0) {
        try appendEvent(allocator, output, seq, "incident", @tagName(action.kind), "unsafe_to_assume", "incident", "rollback drill failed", summary_path);
        return error.InvalidSummary;
    }
    try appendEvent(allocator, output, seq, "stage_finished", @tagName(action.kind), "PASS", "rolled_back", "rollback drill summary captured", summary_path);
    return summary_path;
}

pub fn runIncidentDrill(
    allocator: std.mem.Allocator,
    io: std.Io,
    output: *std.ArrayList(u8),
    action: protocol.OperatorAction,
    seq: *usize,
) RunError![]u8 {
    var plan = try commands.buildLabCommand(allocator, action);
    defer plan.deinit(allocator);
    try appendEvent(allocator, output, seq, "stage_started", @tagName(action.kind), "queued", "incident", "", "");
    var env_map = try buildEnv(allocator, plan.env);
    defer env_map.deinit();
    const result = try std.process.run(allocator, io, .{
        .argv = plan.args(),
        .environ_map = &env_map,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(256 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const summary_path = try std.fmt.allocPrint(allocator, "{s}/summary.json", .{plan.out_dir});
    errdefer allocator.free(summary_path);
    if (result.term != .exited or result.term.exited != 0) {
        try appendEvent(allocator, output, seq, "incident", @tagName(action.kind), "unsafe_to_assume", "incident", "incident drill failed", summary_path);
        return error.InvalidSummary;
    }
    try appendEvent(allocator, output, seq, "incident", @tagName(action.kind), "INCIDENT", "incident", "verifier_rejection scheduler_exit lost_stream", summary_path);
    try appendEvent(allocator, output, seq, "stage_finished", @tagName(action.kind), "PASS", "rolled_back", "incident rollback/fallback summary captured", summary_path);
    return summary_path;
}

fn buildEnv(allocator: std.mem.Allocator, vars: []const commands.EnvVar) !std.process.Environ.Map {
    var map = std.process.Environ.Map.init(allocator);
    errdefer map.deinit();
    for (vars) |env_var| try map.put(env_var.name, env_var.value);
    return map;
}

fn appendSummaryStages(
    allocator: std.mem.Allocator,
    io: std.Io,
    output: *std.ArrayList(u8),
    seq: *usize,
    summary_path: []const u8,
) RunError!void {
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, summary_path, allocator, .limited(1024 * 1024));
    defer allocator.free(raw);
    var parsed = std.json.parseFromSlice(RawSummary, allocator, raw, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return error.InvalidSummary;
    defer parsed.deinit();
    for (parsed.value.stages) |stage| {
        if (!validStageStatus(stage.status)) return error.InvalidSummary;
        try appendEvent(allocator, output, seq, "stage_finished", stage.stage, stage.status, "read_only", stage.reason, stage.artifact);
    }
}

fn validStageStatus(status: []const u8) bool {
    return std.mem.eql(u8, status, "PASS") or std.mem.eql(u8, status, "SKIP") or std.mem.eql(u8, status, "REFUSE");
}

fn appendEvent(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    seq: *usize,
    event: []const u8,
    action: []const u8,
    status: []const u8,
    state: []const u8,
    reason: []const u8,
    artifact: []const u8,
) !void {
    var event_bytes: std.ArrayList(u8) = .empty;
    defer event_bytes.deinit(allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(allocator, &event_bytes);
    try writer.writer.print(
        "{{\"schema\":\"{s}\",\"seq\":{d},\"event\":\"{s}\",\"action\":\"{s}\",\"state\":\"{s}\",\"status\":\"{s}\",\"reason\":",
        .{ protocol.event_schema, seq.*, event, action, state, status },
    );
    try writeJsonString(&writer.writer, reason);
    try writer.writer.writeAll(",\"artifact\":");
    try writeJsonString(&writer.writer, artifact);
    try writer.writer.writeAll(",\"host_mutation\":false}\n");
    event_bytes = writer.toArrayList();
    try output.appendSlice(allocator, event_bytes.items);
    seq.* += 1;
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

test "lab runner validates accepted stage statuses" {
    try std.testing.expect(validStageStatus("PASS"));
    try std.testing.expect(validStageStatus("SKIP"));
    try std.testing.expect(validStageStatus("REFUSE"));
    try std.testing.expect(!validStageStatus("completed"));
}
