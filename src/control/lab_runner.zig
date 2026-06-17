const std = @import("std");
const commands = @import("commands.zig");
const env_builder = @import("env_builder.zig");
const protocol = @import("protocol.zig");

const line_trim_chars = [_]u8{ ' ', 9, 13 };
const git_trim_chars = [_]u8{ ' ', 9, 10, 13 };

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

const CleanupSummary = struct {
    qemu_leftovers: bool = true,
    tmux_leftovers: bool = true,
    process_group_reaped: bool = false,
    temp_dirs_removed: bool = false,
};

const LiveSummary = struct {
    schema: []const u8,
    status: []const u8,
    evidence_mode: []const u8,
    git_sha: ?[]const u8 = null,
    git_dirty: ?bool = null,
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
    stages: []RawStage = &.{},
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

    var env_map = try env_builder.build(allocator, plan.env, false, null);
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
    var env_map = try env_builder.build(allocator, plan.env, false, null);
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

pub fn runMicrovmLive(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    output: *std.ArrayList(u8),
    action: protocol.OperatorAction,
    seq: *usize,
    start_events_already_emitted: bool,
) RunError!void {
    var plan = try commands.buildLabCommand(allocator, action);
    defer plan.deinit(allocator);
    if (!start_events_already_emitted) {
        try appendMicrovmLiveStartEventsForPlan(allocator, output, action, seq, plan.out_dir);
    }

    var env_map = try env_builder.build(allocator, plan.env, true, environ);
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
        try appendEvent(allocator, output, seq, "stage_finished", @tagName(action.kind), "REFUSE", "refused_host", runnerFailureReason(result.stderr), plan.out_dir);
        return;
    }

    const git_sha = try readGitSha(allocator, io);
    defer allocator.free(git_sha);
    appendLiveSummaryEvents(allocator, io, output, seq, summary_path, git_sha) catch {
        try appendEvent(allocator, output, seq, "incident", @tagName(action.kind), "unsafe_to_assume", "unsafe_to_assume", "live_bundle_rejected", summary_path);
        return;
    };
    try appendEvent(allocator, output, seq, "stage_finished", @tagName(action.kind), "PASS", "vm_live_complete", "microvm live bundle accepted", summary_path);
}

pub fn appendMicrovmLiveStartEvents(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    action: protocol.OperatorAction,
    seq: *usize,
) RunError!void {
    var plan = try commands.buildLabCommand(allocator, action);
    defer plan.deinit(allocator);
    try appendMicrovmLiveStartEventsForPlan(allocator, output, action, seq, plan.out_dir);
}

fn appendMicrovmLiveStartEventsForPlan(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    action: protocol.OperatorAction,
    seq: *usize,
    out_dir: []const u8,
) RunError!void {
    try appendEvent(allocator, output, seq, "stage_started", @tagName(action.kind), "queued", "vm_only_pending", "microvm_live_runner_start", out_dir);
    try appendEvent(allocator, output, seq, "stage_started", @tagName(action.kind), "active", "microvm_runner_subprocess", "microvm runner subprocess active", out_dir);
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
    var env_map = try env_builder.build(allocator, plan.env, false, null);
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
    var env_map = try env_builder.build(allocator, plan.env, false, null);
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

fn appendLiveSummaryEvents(
    allocator: std.mem.Allocator,
    io: std.Io,
    output: *std.ArrayList(u8),
    seq: *usize,
    summary_path: []const u8,
    current_git_sha: []const u8,
) RunError!void {
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, summary_path, allocator, .limited(1024 * 1024));
    defer allocator.free(raw);
    var parsed = std.json.parseFromSlice(LiveSummary, allocator, raw, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return error.InvalidSummary;
    defer parsed.deinit();
    const summary = parsed.value;
    try validateLiveSummary(summary, current_git_sha);
    try validateLiveArtifacts(allocator, io, summary);
    for (summary.stages) |stage| {
        if (!validStageStatus(stage.status)) return error.InvalidSummary;
    }

    try appendEvent(allocator, output, seq, "microvm_boot", "run_lab_microvm_live", "PASS", "vm_live", "vm marker present", summary_path);
    try appendEvent(allocator, output, seq, "vm_marker", "run_lab_microvm_live", "PASS", "vm_live", summary.vm_marker_path orelse "/run/zig-scheduler-vm-lab.marker", summary_path);
    for (summary.stages) |stage| {
        try appendEvent(allocator, output, seq, "stage_finished", stage.stage, stage.status, "vm_live", stage.reason, stage.artifact);
    }
    try appendEvent(allocator, output, seq, "bpf_register", "run_lab_microvm_live", "PASS", "zigsched_minimal", "runtime ops observed", artifactContaining(summary, "partial-attach") orelse summary_path);
    try appendEvent(allocator, output, seq, "runtime_sample", "run_lab_microvm_live", "PASS", "observing", "runtime samples accepted", artifactContaining(summary, "runtime-samples") orelse summary_path);
    try appendEvent(allocator, output, seq, "rollback", "run_lab_microvm_live", "PASS", "rolled_back", summary.rollback_result orelse "PASS", artifactContaining(summary, "audit-ledger") orelse summary_path);
    try appendEvent(allocator, output, seq, "cleanup", "run_lab_microvm_live", "PASS", "clean", "process scan clean", summary_path);
    try appendEvent(allocator, output, seq, "validation", "run_lab_microvm_live", "PASS", "vm_live_validated", "live bundle freshness accepted", summary_path);
}

fn validateLiveSummary(summary: LiveSummary, current_git_sha: []const u8) RunError!void {
    if (!std.mem.eql(u8, summary.schema, "zig-scheduler/run-all-lab/v1")) return error.InvalidSummary;
    if (!std.mem.eql(u8, summary.status, "PASS")) return error.InvalidSummary;
    if (!std.mem.eql(u8, summary.evidence_mode, "vm-live")) return error.InvalidSummary;
    if (summary.host_mutation) return error.InvalidSummary;
    if (summary.git_sha) |git_sha| {
        if (!std.mem.eql(u8, git_sha, current_git_sha)) return error.InvalidSummary;
    } else return error.InvalidSummary;
    if (summary.git_dirty orelse true) return error.InvalidSummary;
    if (!validSha256(summary.bpf_object_sha256 orelse "")) return error.InvalidSummary;
    if (!(summary.output_dir_created_fresh orelse false)) return error.InvalidSummary;
    if (!(summary.vm_marker_present orelse false)) return error.InvalidSummary;
    if (!std.mem.eql(u8, summary.vm_marker_path orelse "", "/run/zig-scheduler-vm-lab.marker")) return error.InvalidSummary;
    if (!std.mem.eql(u8, summary.rollback_result orelse "", "PASS")) return error.InvalidSummary;
    if (summary.cleanup) |cleanup| {
        if (cleanup.qemu_leftovers or cleanup.tmux_leftovers) return error.InvalidSummary;
        if (!cleanup.process_group_reaped or !cleanup.temp_dirs_removed) return error.InvalidSummary;
    } else return error.InvalidSummary;
}

fn validateLiveArtifacts(allocator: std.mem.Allocator, io: std.Io, summary: LiveSummary) RunError!void {
    const runtime_path = artifactContaining(summary, "runtime-samples") orelse return error.InvalidSummary;
    const daemon_path = artifactContaining(summary, "daemon-runtime-events") orelse return error.InvalidSummary;
    try validateRuntimeSamples(allocator, io, runtime_path);
    try validateDaemonRuntimeEvents(allocator, io, daemon_path);
}

fn validateRuntimeSamples(allocator: std.mem.Allocator, io: std.Io, path: []const u8) RunError!void {
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

fn validateDaemonRuntimeEvents(allocator: std.mem.Allocator, io: std.Io, path: []const u8) RunError!void {
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

fn runnerFailureReason(stderr: []const u8) []const u8 {
    if (std.mem.indexOf(u8, stderr, "qemu-system-x86_64 not found") != null) return "qemu_not_found";
    if (std.mem.indexOf(u8, stderr, "/dev/kvm") != null) return "kvm_unavailable";
    if (std.mem.indexOf(u8, stderr, "kernel image") != null) return "kernel_unavailable";
    if (std.mem.indexOf(u8, stderr, "busybox") != null or std.mem.indexOf(u8, stderr, "nix") != null) return "nix_busybox_unavailable";
    return "microvm_runner_refused";
}

fn readGitSha(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const head = std.Io.Dir.cwd().readFileAlloc(io, ".git/HEAD", allocator, .limited(1024)) catch {
        return allocator.dupe(u8, "unknown");
    };
    defer allocator.free(head);
    const trimmed = std.mem.trim(u8, head, &git_trim_chars);
    if (std.mem.startsWith(u8, trimmed, "ref: ")) {
        const ref_path = try std.fmt.allocPrint(allocator, ".git/{s}", .{std.mem.trim(u8, trimmed[5..], &git_trim_chars)});
        defer allocator.free(ref_path);
        const ref_value = std.Io.Dir.cwd().readFileAlloc(io, ref_path, allocator, .limited(128)) catch {
            return allocator.dupe(u8, "unknown");
        };
        defer allocator.free(ref_value);
        return allocator.dupe(u8, std.mem.trim(u8, ref_value, &git_trim_chars));
    }
    return allocator.dupe(u8, trimmed);
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

test "live microvm summary emits UI lifecycle events from accepted bundle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    const root = try testingTmpRelPath(std.testing.allocator, tmp, ".");
    defer std.testing.allocator.free(root);
    const summary_path = try writeTestingLiveBundle(std.testing.allocator, &tmp.dir, root, .{});
    defer std.testing.allocator.free(summary_path);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    var seq: usize = 1;
    try appendLiveSummaryEvents(std.testing.allocator, io, &output, &seq, summary_path, "git-ok");

    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"event\":\"microvm_boot\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"event\":\"vm_marker\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"event\":\"bpf_register\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"event\":\"runtime_sample\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"event\":\"rollback\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"event\":\"cleanup\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"event\":\"validation\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"host_mutation\":false") != null);
}

test "live microvm summary rejects stale and malformed bundles" {
    var stale_tmp = std.testing.tmpDir(.{});
    defer stale_tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    const stale_root = try testingTmpRelPath(std.testing.allocator, stale_tmp, ".");
    defer std.testing.allocator.free(stale_root);
    const stale_summary_path = try writeTestingLiveBundle(std.testing.allocator, &stale_tmp.dir, stale_root, .{ .git_sha = "old-git" });
    defer std.testing.allocator.free(stale_summary_path);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    var seq: usize = 1;
    try std.testing.expectError(error.InvalidSummary, appendLiveSummaryEvents(std.testing.allocator, io, &output, &seq, stale_summary_path, "git-ok"));

    var malformed_tmp = std.testing.tmpDir(.{});
    defer malformed_tmp.cleanup();
    try malformed_tmp.dir.writeFile(io, .{ .sub_path = "summary.json", .data = "{not-json" });
    const malformed_path = try testingTmpRelPath(std.testing.allocator, malformed_tmp, "summary.json");
    defer std.testing.allocator.free(malformed_path);
    try std.testing.expectError(error.InvalidSummary, appendLiveSummaryEvents(std.testing.allocator, io, &output, &seq, malformed_path, "git-ok"));
}

test "live microvm malformed stage emits no PASS lifecycle events" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    const root = try testingTmpRelPath(std.testing.allocator, tmp, ".");
    defer std.testing.allocator.free(root);
    const summary_path = try writeTestingLiveBundle(std.testing.allocator, &tmp.dir, root, .{ .stage_status = "completed" });
    defer std.testing.allocator.free(summary_path);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    var seq: usize = 1;
    try std.testing.expectError(error.InvalidSummary, appendLiveSummaryEvents(std.testing.allocator, io, &output, &seq, summary_path, "git-ok"));
    try std.testing.expectEqual(@as(usize, 0), output.items.len);
    try std.testing.expectEqual(@as(usize, 1), seq);
}

test "live microvm runner failure classification is explicit" {
    try std.testing.expectEqualStrings("qemu_not_found", runnerFailureReason("FAIL: qemu-system-x86_64 not found; install qemu"));
    try std.testing.expectEqualStrings("kvm_unavailable", runnerFailureReason("FAIL: /dev/kvm is required for the microVM live lab"));
    try std.testing.expectEqualStrings("kernel_unavailable", runnerFailureReason("FAIL: readable kernel image not found"));
    try std.testing.expectEqualStrings("nix_busybox_unavailable", runnerFailureReason("FAIL: could not build/fetch pkgsStatic.busybox through nix"));
    try std.testing.expectEqualStrings("microvm_runner_refused", runnerFailureReason("FAIL: unexpected"));
}

const TestingBundleOptions = struct {
    git_sha: []const u8 = "git-ok",
    stage_status: []const u8 = "PASS",
};

fn writeTestingLiveBundle(
    allocator: std.mem.Allocator,
    dir: *std.Io.Dir,
    root: []const u8,
    options: TestingBundleOptions,
) ![]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const runtime_path = try std.fmt.allocPrint(allocator, "{s}/runtime-samples.jsonl", .{root});
    defer allocator.free(runtime_path);
    const daemon_path = try std.fmt.allocPrint(allocator, "{s}/daemon-runtime-events.jsonl", .{root});
    defer allocator.free(daemon_path);
    const partial_path = try std.fmt.allocPrint(allocator, "{s}/partial-attach-evidence.json", .{root});
    defer allocator.free(partial_path);
    try dir.writeFile(io, .{ .sub_path = "runtime-samples.jsonl", .data =
        \\{"schema":"zig-scheduler/runtime-sample/v1","sequence":0,"ops":{"status":"present","value":"none"},"private_command_lines_sampled":false,"workload_alive":true}
        \\{"schema":"zig-scheduler/runtime-sample/v1","sequence":1,"ops":{"status":"present","value":"zigsched_minimal"},"private_command_lines_sampled":false,"workload_alive":true}
        \\{"schema":"zig-scheduler/runtime-sample/v1","sequence":2,"ops":{"status":"present","value":"none"},"private_command_lines_sampled":false,"workload_alive":true}
        \\
    });
    try dir.writeFile(io, .{ .sub_path = "daemon-runtime-events.jsonl", .data =
        \\{"schema":"zig-scheduler/daemon-event/v1","event":"runtime_sample","ops":"zigsched_minimal","host_mutation":false}
        \\
    });
    try dir.writeFile(io, .{ .sub_path = "partial-attach-evidence.json", .data = "{}\n" });

    const summary = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "schema": "zig-scheduler/run-all-lab/v1",
        \\  "status": "PASS",
        \\  "evidence_mode": "vm-live",
        \\  "git_sha": "{s}",
        \\  "git_dirty": false,
        \\  "bpf_object_sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        \\  "output_dir": "{s}",
        \\  "output_dir_created_fresh": true,
        \\  "host_mutation": false,
        \\  "vm_kind": "qemu-vm",
        \\  "vm_marker_present": true,
        \\  "vm_marker_path": "/run/zig-scheduler-vm-lab.marker",
        \\  "rollback_result": "PASS",
        \\  "artifact_paths": ["{s}", "{s}", "{s}"],
        \\  "cleanup": {{
        \\    "qemu_leftovers": false,
        \\    "tmux_leftovers": false,
        \\    "process_group_reaped": true,
        \\    "temp_dirs_removed": true
        \\  }},
        \\  "stages": [
        \\    {{"stage":"partial_attach","status":"{s}","reason":"attached in VM guest","artifact":"{s}"}}
        \\  ]
        \\}}
        \\
    , .{ options.git_sha, root, runtime_path, daemon_path, partial_path, options.stage_status, partial_path });
    defer allocator.free(summary);
    try dir.writeFile(io, .{ .sub_path = "summary.json", .data = summary });
    return std.fmt.allocPrint(allocator, "{s}/summary.json", .{root});
}

fn testingTmpRelPath(allocator: std.mem.Allocator, tmp: std.testing.TmpDir, sub_path: []const u8) ![]u8 {
    if (std.mem.eql(u8, sub_path, "."))
        return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/{s}", .{ &tmp.sub_path, sub_path });
}
