const std = @import("std");
const errors = @import("errors.zig");
const events = @import("events.zig");
const protocol = @import("../protocol.zig");

const line_trim_chars = [_]u8{ ' ', 9, 13 };
const runner_event_prefix = "ZIGSCHED_DAEMON_EVENT ";

const RunnerLifecycleEvent = struct {
    event: []const u8,
    status: []const u8,
    state: []const u8,
    reason: ?[]const u8 = null,
    artifact: ?[]const u8 = null,
    ops: ?[]const u8 = null,
    live_bundle_path: ?[]const u8 = null,
};

pub const RunnerLifecycleKind = enum {
    ignored,
    boot,
    marker,
    verifier,
    attach,
    runtime_sample,
    rollback,
    cleanup,
    validation,
    incident,
    other,
};

pub const RunnerLifecycleLine = struct {
    kind: RunnerLifecycleKind,
    clears_active: bool = false,
    incident_terminal: bool = false,
};

pub fn appendRunnerLifecycleLine(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    seq: *usize,
    action: protocol.OperatorAction,
    raw_line: []const u8,
) errors.RunError!RunnerLifecycleLine {
    const line = std.mem.trim(u8, raw_line, &line_trim_chars);
    if (!std.mem.startsWith(u8, line, runner_event_prefix)) return .{ .kind = .ignored };
    const payload = line[runner_event_prefix.len..];
    var parsed = std.json.parseFromSlice(RunnerLifecycleEvent, allocator, payload, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
    }) catch return error.InvalidSummary;
    defer parsed.deinit();
    try events.appendActionEvent(
        allocator,
        output,
        seq,
        action,
        parsed.value.event,
        parsed.value.status,
        parsed.value.state,
        parsed.value.reason orelse "",
        parsed.value.artifact orelse "",
        parsed.value.ops orelse "",
        parsed.value.live_bundle_path orelse "",
    );
    return .{
        .kind = lifecycleKind(parsed.value.event),
        .clears_active = clearsActiveState(parsed.value.event, parsed.value.status, parsed.value.state),
        .incident_terminal = incidentTerminal(parsed.value.event, parsed.value.status, parsed.value.state),
    };
}

fn lifecycleKind(event: []const u8) RunnerLifecycleKind {
    if (std.mem.eql(u8, event, "boot")) return .boot;
    if (std.mem.eql(u8, event, "marker")) return .marker;
    if (std.mem.eql(u8, event, "verifier")) return .verifier;
    if (std.mem.eql(u8, event, "attach")) return .attach;
    if (std.mem.eql(u8, event, "runtime_sample")) return .runtime_sample;
    if (std.mem.eql(u8, event, "rollback")) return .rollback;
    if (std.mem.eql(u8, event, "cleanup")) return .cleanup;
    if (std.mem.eql(u8, event, "validation")) return .validation;
    if (std.mem.eql(u8, event, "incident")) return .incident;
    return .other;
}

fn clearsActiveState(event: []const u8, status: []const u8, state: []const u8) bool {
    if (std.mem.eql(u8, event, "rollback")) {
        return successfulRollbackStatus(status) and std.mem.eql(u8, state, "rolled_back");
    }
    if (std.mem.eql(u8, event, "cleanup")) {
        return successfulCleanupStatus(status) and std.mem.eql(u8, state, "clean");
    }
    return false;
}

fn successfulRollbackStatus(status: []const u8) bool {
    return std.mem.eql(u8, status, "PASS") or std.mem.eql(u8, status, "already_rolled_back");
}

fn successfulCleanupStatus(status: []const u8) bool {
    return std.mem.eql(u8, status, "PASS") or std.mem.eql(u8, status, "already_clean");
}

fn incidentTerminal(event: []const u8, status: []const u8, state: []const u8) bool {
    return std.mem.eql(u8, event, "incident") or
        std.mem.eql(u8, status, "FAIL") or
        std.mem.eql(u8, status, "REFUSE") or
        std.mem.eql(u8, status, "INCIDENT") or
        std.mem.eql(u8, status, "unsafe_to_assume") or
        std.mem.eql(u8, state, "incident") or
        std.mem.eql(u8, state, "unsafe_to_assume");
}

test "lifecycle stream behavior tests are linked" {
    std.testing.refAllDecls(@import("lifecycle_stream_tests.zig"));
}
