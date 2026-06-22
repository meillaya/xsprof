const std = @import("std");
const errors = @import("errors.zig");
const summary_mod = @import("summary.zig");
const daemon_support = @import("../daemon_support.zig");
const protocol = @import("../protocol.zig");
const lifecycle_stream = @import("lifecycle_stream.zig");

pub const readGitSha = daemon_support.readGitSha;
pub const RunnerLifecycleKind = lifecycle_stream.RunnerLifecycleKind;
pub const RunnerLifecycleLine = lifecycle_stream.RunnerLifecycleLine;
pub const appendRunnerLifecycleLine = lifecycle_stream.appendRunnerLifecycleLine;

const line_trim_chars = [_]u8{ ' ', 9, 13 };
const CleanupSummary = struct {
    qemu_leftovers: bool = true,
    tmux_leftovers: bool = true,
    process_group_reaped: bool = false,
    temp_dirs_removed: bool = false,
    timeout_rc: ?i64 = null,
};

const LiveSummary = struct {
    schema: []const u8,
    status: []const u8,
    evidence_mode: []const u8,
    git_sha: ?[]const u8 = null,
    git_dirty: ?bool = null,
    dirty_tree_snapshot_sha256: ?[]const u8 = null,
    bpf_object_sha256: ?[]const u8 = null,
    output_dir: ?[]const u8 = null,
    output_dir_created_fresh: ?bool = null,
    host_mutation: bool,
    vm_kind: ?[]const u8 = null,
    vm_marker_present: ?bool = null,
    vm_marker_path: ?[]const u8 = null,
    rollback_result: ?[]const u8 = null,
    artifact_paths: []const []const u8 = &.{},
    cleanup: ?CleanupSummary = null,
    stages: []summary_mod.RawStage = &.{},
};

const RuntimeFact = struct {
    status: []const u8,
    value: []const u8,
};

const RuntimeSample = struct {
    schema: []const u8,
    sequence: usize,
    ops: RuntimeFact,
    private_command_lines_sampled: bool,
    workload_alive: bool,
};

const DaemonRuntimeEvent = struct {
    schema: []const u8,
    event: []const u8,
    ops: ?[]const u8 = null,
    host_mutation: bool,
};

pub fn validateLiveBundle(
    allocator: std.mem.Allocator,
    io: std.Io,
    summary_path: []const u8,
    current_git_sha: []const u8,
) errors.RunError!void {
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, summary_path, allocator, .limited(1024 * 1024));
    defer allocator.free(raw);
    var parsed = std.json.parseFromSlice(LiveSummary, allocator, raw, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return error.InvalidSummary;
    defer parsed.deinit();
    try validateLiveSummary(parsed.value, current_git_sha);
    try validateLiveArtifacts(allocator, io, parsed.value);
    try validateLiveStages(parsed.value);
}

fn validateLiveStages(summary: LiveSummary) errors.RunError!void {
    for (summary.stages) |stage| {
        if (!summary_mod.validStageStatus(stage.status)) return error.InvalidSummary;
    }
}

fn validateLiveSummary(summary: LiveSummary, current_git_sha: []const u8) errors.RunError!void {
    if (!std.mem.eql(u8, summary.schema, "zig-scheduler/run-all-lab/v1")) return error.InvalidSummary;
    if (!std.mem.eql(u8, summary.status, "PASS")) return error.InvalidSummary;
    if (!std.mem.eql(u8, summary.evidence_mode, "vm-live")) return error.InvalidSummary;
    if (summary.host_mutation) return error.InvalidSummary;
    if (summary.git_sha) |git_sha| {
        if (!std.mem.eql(u8, git_sha, current_git_sha)) return error.InvalidSummary;
    } else return error.InvalidSummary;
    if (summary.git_dirty orelse true) {
        if (!validSha256(summary.dirty_tree_snapshot_sha256 orelse "")) return error.InvalidSummary;
    }
    if (!validSha256(summary.bpf_object_sha256 orelse "")) return error.InvalidSummary;
    if (!(summary.output_dir_created_fresh orelse false)) return error.InvalidSummary;
    if (!(summary.vm_marker_present orelse false)) return error.InvalidSummary;
    if (!std.mem.eql(u8, summary.vm_marker_path orelse "", "/run/zig-scheduler-vm-lab.marker")) return error.InvalidSummary;
    if (!std.mem.eql(u8, summary.rollback_result orelse "", "PASS")) return error.InvalidSummary;
    if (summary.cleanup) |cleanup| {
        if (cleanup.qemu_leftovers or cleanup.tmux_leftovers) return error.InvalidSummary;
        if (!cleanup.process_group_reaped or !cleanup.temp_dirs_removed) return error.InvalidSummary;
        if ((cleanup.timeout_rc orelse 0) == 124) return error.InvalidSummary;
    } else return error.InvalidSummary;
}

fn validateLiveArtifacts(allocator: std.mem.Allocator, io: std.Io, summary: LiveSummary) errors.RunError!void {
    const runtime_path = artifactContaining(summary, "runtime-samples") orelse return error.InvalidSummary;
    const daemon_path = artifactContaining(summary, "daemon-runtime-events") orelse return error.InvalidSummary;
    try validateRuntimeSamples(allocator, io, runtime_path);
    try validateDaemonRuntimeEvents(allocator, io, daemon_path);
}

fn validateRuntimeSamples(allocator: std.mem.Allocator, io: std.Io, path: []const u8) errors.RunError!void {
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(raw);
    var saw_before = false;
    var saw_during = false;
    var saw_after = false;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &line_trim_chars);
        if (trimmed.len == 0) continue;
        var parsed = std.json.parseFromSlice(RuntimeSample, allocator, trimmed, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        }) catch return error.InvalidSummary;
        defer parsed.deinit();
        if (!std.mem.eql(u8, parsed.value.schema, "zig-scheduler/runtime-sample/v1")) return error.InvalidSummary;
        if (parsed.value.private_command_lines_sampled or !parsed.value.workload_alive) return error.InvalidSummary;
        const ops = parsed.value.ops.value;
        if (std.mem.eql(u8, ops, "zigsched_minimal")) saw_during = true else if (!saw_during) saw_before = true else saw_after = true;
    }
    if (!saw_before or !saw_during or !saw_after) return error.InvalidSummary;
}

fn validateDaemonRuntimeEvents(allocator: std.mem.Allocator, io: std.Io, path: []const u8) errors.RunError!void {
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(raw);
    var saw_runtime = false;
    var saw_ops = false;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &line_trim_chars);
        if (trimmed.len == 0) continue;
        var parsed = std.json.parseFromSlice(DaemonRuntimeEvent, allocator, trimmed, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        }) catch return error.InvalidSummary;
        defer parsed.deinit();
        if (!std.mem.eql(u8, parsed.value.schema, protocol.event_schema)) return error.InvalidSummary;
        if (parsed.value.host_mutation) return error.InvalidSummary;
        if (std.mem.eql(u8, parsed.value.event, "runtime_sample")) {
            saw_runtime = true;
            if (std.mem.eql(u8, parsed.value.ops orelse "", "zigsched_minimal")) saw_ops = true;
        }
    }
    if (!saw_runtime or !saw_ops) return error.InvalidSummary;
}

fn artifactContaining(summary: LiveSummary, needle: []const u8) ?[]const u8 {
    for (summary.artifact_paths) |path| {
        if (std.mem.indexOf(u8, path, needle) != null) return path;
    }
    return null;
}

fn validSha256(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |byte| {
        if (!std.ascii.isHex(byte)) return false;
    }
    return true;
}

test "lifecycle stream split remains linked through live summary" {
    std.testing.refAllDecls(lifecycle_stream);
}
