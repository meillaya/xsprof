const std = @import("std");
const linux = @import("linux_scheduler");

const protocol = linux.control.protocol;

pub fn statusForAction(action: protocol.OperatorAction) []const u8 {
    return switch (action.kind) {
        .verifier_only => "verifier queued local-daemon",
        .run_lab_host_safe => "host-safe lab queued local-daemon",
        .partial_attach => "partial attach queued local-daemon",
        .observe => "observe queued local-daemon",
        .stop, .stop_lab_run => "stop queued local-daemon",
        .rollback, .rollback_lab_run => "rollback queued local-daemon",
        .preflight => "preflight queued local-daemon",
        .run_lab_vm => "vm lab queued local-daemon",
        .run_lab_microvm_live => "live microvm queued local-daemon",
        .incident_drill => "incident drill queued local-daemon",
    };
}

pub fn statusFromDaemonOutput(allocator: std.mem.Allocator, raw: []const u8, action: protocol.OperatorAction) []const u8 {
    var found: []const u8 = "";
    var terminal_failure = false;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const parsed = parseDaemonEvent(allocator, trimmed) catch return "daemon unsafe_to_assume";
        defer parsed.deinit();

        const event = parsed.value;
        if (!std.mem.eql(u8, event.schema, protocol.event_schema) or event.host_mutation) return "daemon unsafe_to_assume";
        if (isUnsafeIncident(event)) return "daemon unsafe_to_assume";
        const event_action = event.action orelse continue;
        if (!std.mem.eql(u8, event_action, @tagName(action.kind))) continue;
        if (terminal_failure) continue;
        if (isRefusal(event)) {
            found = refusalStatus(action, event.reason.?);
            terminal_failure = true;
            continue;
        }
        if (isStatus(event, "REFUSE")) {
            found = terminalRefuseStatus(action, event.reason orelse "refused");
            terminal_failure = true;
            continue;
        }
        if (isStatus(event, "SKIP")) {
            found = terminalSkipStatus(action, event.reason orelse "skipped");
            terminal_failure = true;
            continue;
        }
        if (std.mem.eql(u8, event.event, "incident") and isStatus(event, "INCIDENT")) {
            found = "INCIDENT rollback/fallback drill";
            terminal_failure = true;
            continue;
        }
        if (isStatus(event, "queued") and found.len == 0) found = statusForAction(action);
        if (isStatus(event, "active")) found = activeStatus(action);
        if (isStatus(event, "PASS")) found = passStatus(action);
        if (isStatus(event, "already_rolled_back")) found = idempotentStatus(action);
        if (isStatus(event, "completed")) found = "daemon completed read-only action";
    }
    if (found.len != 0) return found;
    return "daemon unsafe_to_assume";
}

const RawDaemonEvent = struct {
    schema: []const u8,
    event: []const u8,
    action: ?[]const u8 = null,
    status: ?[]const u8 = null,
    reason: ?[]const u8 = null,
    host_mutation: bool,
};

fn isUnsafeIncident(event: RawDaemonEvent) bool {
    if (!std.mem.eql(u8, event.event, "incident")) return false;
    if (isStatus(event, "unsafe_to_assume")) return true;
    const reason = event.reason orelse return false;
    return std.mem.eql(u8, reason, "private_fields_rejected") or
        std.mem.eql(u8, reason, "malformed_runtime_sample") or
        std.mem.eql(u8, reason, "stream_backpressure_dropped");
}

fn parseDaemonEvent(allocator: std.mem.Allocator, raw: []const u8) !std.json.Parsed(RawDaemonEvent) {
    return std.json.parseFromSlice(RawDaemonEvent, allocator, raw, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
}

fn isRefusal(event: RawDaemonEvent) bool {
    return std.mem.eql(u8, event.event, "refusal") and
        isStatus(event, "refused") and
        event.reason != null;
}

fn isStatus(event: RawDaemonEvent, expected: []const u8) bool {
    return event.status != null and std.mem.eql(u8, event.status.?, expected);
}

fn activeStatus(action: protocol.OperatorAction) []const u8 {
    return switch (action.kind) {
        .run_lab_vm => "vm lab active rollback ready",
        .run_lab_microvm_live => "live microvm active rollback ready",
        .incident_drill => "INCIDENT rollback/fallback drill",
        else => statusForAction(action),
    };
}

fn passStatus(action: protocol.OperatorAction) []const u8 {
    return switch (action.kind) {
        .rollback, .rollback_lab_run => "rollback completed PASS",
        .stop, .stop_lab_run => "stop completed PASS",
        .incident_drill => "INCIDENT rollback/fallback drill",
        else => "daemon completed read-only action",
    };
}

fn idempotentStatus(action: protocol.OperatorAction) []const u8 {
    return switch (action.kind) {
        .rollback, .rollback_lab_run => "rollback already_rolled_back",
        .stop, .stop_lab_run => "stop completed already_rolled_back",
        else => "daemon completed idempotent",
    };
}

fn refusalStatus(action: protocol.OperatorAction, reason: []const u8) []const u8 {
    if (std.mem.eql(u8, reason, "host_mutation_refused")) {
        return switch (action.kind) {
            .verifier_only => "verifier queued/refused host-safe",
            .partial_attach => "partial attach queued/refused host-safe",
            .stop, .rollback, .stop_lab_run, .rollback_lab_run => "rollback queued/refused host-safe",
            .incident_drill => "incident drill refused host-safe",
            .run_lab_microvm_live => "live microvm queued/refused host-safe",
            else => "daemon refused host-safe",
        };
    }
    if (std.mem.eql(u8, reason, "target_action_id_and_rollback_id_required")) return "rollback refused missing target/rollback id";
    if (std.mem.eql(u8, reason, "stale_or_unknown_target_action_id")) return "rollback refused stale target";
    if (std.mem.eql(u8, reason, "stale_rollback_id")) return "rollback refused stale rollback id";
    return "daemon refused host-safe";
}

fn terminalRefuseStatus(action: protocol.OperatorAction, reason: []const u8) []const u8 {
    if (action.kind == .run_lab_microvm_live) {
        if (std.mem.eql(u8, reason, "qemu_not_found")) return "live microvm REFUSE qemu_not_found";
        if (std.mem.eql(u8, reason, "kvm_unavailable")) return "live microvm REFUSE kvm_unavailable";
        if (std.mem.eql(u8, reason, "kernel_unavailable")) return "live microvm REFUSE kernel_unavailable";
        if (std.mem.eql(u8, reason, "nix_busybox_unavailable")) return "live microvm REFUSE nix_busybox_unavailable";
        return "live microvm REFUSE runner";
    }
    return refusalStatus(action, reason);
}

fn terminalSkipStatus(action: protocol.OperatorAction, reason: []const u8) []const u8 {
    if (action.kind == .run_lab_microvm_live) {
        if (std.mem.eql(u8, reason, "qemu_not_found")) return "live microvm SKIP qemu_not_found";
        if (std.mem.eql(u8, reason, "kvm_unavailable")) return "live microvm SKIP kvm_unavailable";
        return "live microvm SKIP host prerequisite";
    }
    return "daemon skipped host-safe";
}

test "daemon output parser treats private and dropped stream incidents as unsafe" {
    const private = "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"event\":\"incident\",\"status\":\"unsafe_to_assume\",\"reason\":\"private_fields_rejected\",\"host_mutation\":false}\n";
    try std.testing.expectEqualStrings("daemon unsafe_to_assume", statusFromDaemonOutput(std.testing.allocator, private, .{ .kind = .run_lab_microvm_live }));

    const dropped = "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"event\":\"incident\",\"status\":\"unsafe_to_assume\",\"reason\":\"stream_backpressure_dropped\",\"host_mutation\":false}\n";
    try std.testing.expectEqualStrings("daemon unsafe_to_assume", statusFromDaemonOutput(std.testing.allocator, dropped, .{ .kind = .run_lab_microvm_live }));
}

test "daemon output parser reports live microvm host-safe refusal" {
    const raw =
        "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"event\":\"stage_started\",\"action\":\"run_lab_microvm_live\",\"status\":\"queued\",\"host_mutation\":false}\n" ++
        "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"event\":\"refusal\",\"action\":\"run_lab_microvm_live\",\"status\":\"refused\",\"reason\":\"host_mutation_refused\",\"host_mutation\":false}\n";
    try std.testing.expectEqualStrings("live microvm queued/refused host-safe", statusFromDaemonOutput(std.testing.allocator, raw, .{ .kind = .run_lab_microvm_live }));
}

test "daemon output parser reports live microvm terminal runner refusal" {
    const raw =
        "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"event\":\"stage_started\",\"action\":\"run_lab_microvm_live\",\"status\":\"active\",\"host_mutation\":false}\n" ++
        "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"event\":\"stage_finished\",\"action\":\"run_lab_microvm_live\",\"status\":\"REFUSE\",\"reason\":\"qemu_not_found\",\"host_mutation\":false}\n";
    try std.testing.expectEqualStrings("live microvm REFUSE qemu_not_found", statusFromDaemonOutput(std.testing.allocator, raw, .{ .kind = .run_lab_microvm_live }));
}

test "daemon output parser marks malformed event unsafe" {
    try std.testing.expectEqualStrings("daemon unsafe_to_assume", statusFromDaemonOutput(std.testing.allocator, "not-json", .{ .kind = .verifier_only }));
}

test "daemon output parser reports verifier host-safe refusal" {
    const raw = "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"event\":\"refusal\",\"action\":\"verifier_only\",\"status\":\"refused\",\"reason\":\"host_mutation_refused\",\"host_mutation\":false}\n";
    try std.testing.expectEqualStrings("verifier queued/refused host-safe", statusFromDaemonOutput(std.testing.allocator, raw, .{ .kind = .verifier_only }));
}

test "daemon output parser skips replayed actions and rejects host mutation" {
    const replay_then_match =
        "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"event\":\"refusal\",\"action\":\"partial_attach\",\"status\":\"refused\",\"reason\":\"host_mutation_refused\",\"host_mutation\":false}\n" ++
        "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"event\":\"rollback_completed\",\"action\":\"rollback_lab_run\",\"status\":\"already_rolled_back\",\"host_mutation\":false}\n";
    try std.testing.expectEqualStrings("rollback already_rolled_back", statusFromDaemonOutput(std.testing.allocator, replay_then_match, .{ .kind = .rollback_lab_run }));

    const mutation = "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"event\":\"refusal\",\"action\":\"verifier_only\",\"status\":\"refused\",\"reason\":\"host_mutation_refused\",\"host_mutation\":true}\n";
    try std.testing.expectEqualStrings("daemon unsafe_to_assume", statusFromDaemonOutput(std.testing.allocator, mutation, .{ .kind = .verifier_only }));
}

test "daemon output parser reports rollback target refusals and PASS" {
    const missing = "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"event\":\"refusal\",\"action\":\"rollback_lab_run\",\"status\":\"refused\",\"reason\":\"target_action_id_and_rollback_id_required\",\"host_mutation\":false}\n";
    try std.testing.expectEqualStrings("rollback refused missing target/rollback id", statusFromDaemonOutput(std.testing.allocator, missing, .{ .kind = .rollback_lab_run }));

    const pass = "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"event\":\"rollback_completed\",\"action\":\"rollback_lab_run\",\"status\":\"PASS\",\"host_mutation\":false}\n";
    try std.testing.expectEqualStrings("rollback completed PASS", statusFromDaemonOutput(std.testing.allocator, pass, .{ .kind = .rollback_lab_run }));
}

test "daemon output parser preserves incident status after PASS event" {
    const raw =
        "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"event\":\"incident\",\"action\":\"incident_drill\",\"status\":\"INCIDENT\",\"host_mutation\":false}\n" ++
        "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"event\":\"stage_finished\",\"action\":\"incident_drill\",\"status\":\"PASS\",\"host_mutation\":false}\n";
    try std.testing.expectEqualStrings("INCIDENT rollback/fallback drill", statusFromDaemonOutput(std.testing.allocator, raw, .{ .kind = .incident_drill }));
}

test "daemon output parser preserves live microvm refusal after cleanup and validation" {
    const raw =
        "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"event\":\"stage_finished\",\"action\":\"run_lab_microvm_live\",\"status\":\"REFUSE\",\"reason\":\"qemu_not_found\",\"host_mutation\":false}\n" ++
        "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"event\":\"cleanup\",\"action\":\"run_lab_microvm_live\",\"status\":\"PASS\",\"reason\":\"process scan clean\",\"host_mutation\":false}\n" ++
        "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"event\":\"validation\",\"action\":\"run_lab_microvm_live\",\"status\":\"PASS\",\"reason\":\"live bundle freshness accepted\",\"host_mutation\":false}\n";
    try std.testing.expectEqualStrings("live microvm REFUSE qemu_not_found", statusFromDaemonOutput(std.testing.allocator, raw, .{ .kind = .run_lab_microvm_live }));
}
