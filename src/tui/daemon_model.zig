const std = @import("std");
const fixture = @import("fixture.zig");

const event_schema = "zig-scheduler/daemon-event/v1";
const live_action = "run_lab_microvm_live";

const RawDaemonEvent = struct {
    schema: []const u8,
    event: []const u8,
    action: ?[]const u8 = null,
    status: ?[]const u8 = null,
    reason: ?[]const u8 = null,
    state: ?[]const u8 = null,
    artifact: ?[]const u8 = null,
    action_id: ?[]const u8 = null,
    audit_id: ?[]const u8 = null,
    rollback_id: ?[]const u8 = null,
    host_mutation: bool,
};

pub fn queuedModel(status: []const u8) fixture.SnapshotModel {
    var model = baseModel();
    model.lab_status = "queued";
    model.current_stage = status;
    model.incident_status = "none";
    model.verifier_status = "queued";
    return model;
}

pub fn modelFromDaemonOutput(allocator: std.mem.Allocator, raw: []const u8, action_status: []const u8) fixture.SnapshotModel {
    var model = queuedModel(action_status);
    if (raw.len == 0) return unsafeModel("empty daemon output", action_status);

    var saw_live = false;
    var saw_pass_validation = false;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSlice(RawDaemonEvent, allocator, line, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        }) catch return unsafeModel("malformed daemon event", action_status);
        defer parsed.deinit();
        const event = parsed.value;
        if (!std.mem.eql(u8, event.schema, event_schema) or event.host_mutation) return unsafeModel("unsafe daemon event", action_status);
        if (unsafeIncident(event)) return unsafeModel("unsafe incident", action_status);
        const event_action = event.action orelse continue;
        if (!std.mem.eql(u8, event_action, live_action)) continue;
        saw_live = true;
        const event_name = extractString(line, "event") orelse event.event;
        const event_reason = extractString(line, "reason") orelse event.reason;
        const event_state = extractString(line, "state") orelse event.state;
        const event_artifact = extractString(line, "artifact") orelse event.artifact;
        const event_action_id = extractString(line, "action_id") orelse event.action_id;
        const event_audit_id = extractString(line, "audit_id") orelse event.audit_id;
        const event_rollback_id = extractString(line, "rollback_id") orelse event.rollback_id;

        if (event_action_id) |id| {
            if (id.len != 0 and std.mem.eql(u8, model.audit_id, "AUD-tui-vm-lab")) model.audit_id = id;
        }
        if (event_audit_id) |id| {
            if (id.len != 0) model.audit_id = id;
        }
        if (event_rollback_id) |id| {
            if (id.len != 0) model.rollback_id = id;
        }
        if (event_state) |state| {
            if (state.len != 0) model.current_stage = state;
        }
        if (event_artifact) |artifact| {
            recordArtifact(&model, artifact);
        }

        if (statusEq(event, "queued")) {
            model.lab_status = "queued";
            if (event_reason) |reason| {
                if (reason.len != 0) model.current_stage = reason;
            }
        } else if (statusEq(event, "active")) {
            model.lab_status = "active";
            model.rollback_status = "rollback ready";
            model.incident_status = "none";
        } else if (statusEq(event, "REFUSE") or statusEq(event, "SKIP")) {
            model.lab_status = if (statusEq(event, "REFUSE")) "REFUSE" else "SKIP";
            model.incident_status = event_reason orelse "runner refused";
            model.lab_gate = "closed";
            model.release_gate_status = "closed";
        }

        if (statusEq(event, "PASS")) {
            model.lab_status = "PASS";
            model.incident_status = "none";
            if (std.mem.eql(u8, event_name, "microvm_boot") or std.mem.eql(u8, event_name, "vm_marker")) {
                model.vm_marker = event_reason orelse "marker present";
                model.verifier_status = "PASS";
            } else if (std.mem.eql(u8, event_name, "bpf_register")) {
                model.runtime_ops = "ops recorded zigsched_minimal";
                model.partial_status = "PASS";
                model.current_stage = event_state orelse "zigsched_minimal";
            } else if (std.mem.eql(u8, event_name, "runtime_sample")) {
                model.runtime_samples = event_reason orelse "runtime samples accepted";
                model.audit_status = "runtime stream PASS";
            } else if (std.mem.eql(u8, event_name, "rollback")) {
                model.rollback_status = "rollback ready/completed";
                if (std.mem.eql(u8, model.rollback_id, "required")) model.rollback_id = "RB-tui-vm-lab";
            } else if (std.mem.eql(u8, event_name, "cleanup")) {
                model.cleanup_status = "cleanup receipt PASS";
            } else if (std.mem.eql(u8, event_name, "validation")) {
                model.lab_gate = event_reason orelse "validation PASS";
                model.release_gate_status = event_reason orelse "validation PASS";
                saw_pass_validation = true;
            } else if (std.mem.eql(u8, event_name, "stage_finished")) {
                if (!saw_pass_validation) {
                    model.lab_gate = event_reason orelse "PASS";
                    model.release_gate_status = "PASS not release proof";
                }
                saw_pass_validation = true;
            }
        }
    }
    if (!saw_live) return unsafeModel("no live daemon action", action_status);
    if (saw_pass_validation) {
        model.lab_status = "PASS";
        model.release_eligibility = "not release eligible";
    }
    return model;
}

fn baseModel() fixture.SnapshotModel {
    return .{
        .kernel_release = "vm guest kernel",
        .arch = "x86_64",
        .cgroup_status = "vm-only",
        .cgroup_controllers = "guest scoped",
        .capabilities = "host unchanged",
        .sched_state = "host fail-closed",
        .sched_enable_seq = "no host enable",
        .sched_switch_all = "no host switch",
        .sched_nr_rejected = "nr_rejected=guest-only",
        .btf_status = "lab guest only",
        .lab_status = "queued",
        .partial_status = "partial switch lab-only",
        .rollback_requirement = "rollback-required before attach",
        .post_rollback_health = "required",
        .state_restored = "read-only",
        .workload_liveness = "not-started",
        .audit_id = "AUD-tui-vm-lab",
        .rollback_id = "RB-tui-vm-lab",
        .lab_gate = "pending",
        .evidence_mode = "vm-live",
        .verifier_status = "pending",
        .dsq_status = "pending",
        .stress_status = "pending",
        .audit_status = "pending",
        .release_gate_status = "closed",
        .current_stage = "live microvm queued",
        .vm_marker = "pending",
        .runtime_samples = "not-started",
        .runtime_ops = "not-attached",
        .runtime_counters = "guest runtime counters pending",
        .rollback_status = "rollback required",
        .incident_status = "none",
        .release_eligibility = "not release eligible",
        .bundle_path = "none",
        .cleanup_status = "not-started",
        .lab_scope = "lab-only vm guest",
        .fixture_warning = "",
    };
}

fn unsafeModel(reason: []const u8, status: []const u8) fixture.SnapshotModel {
    var model = baseModel();
    model.lab_status = "unsafe_to_assume";
    model.current_stage = status;
    model.incident_status = reason;
    model.lab_gate = "closed";
    model.release_gate_status = "closed";
    model.runtime_samples = "unsafe_to_assume";
    model.runtime_ops = "not-attached";
    model.cleanup_status = "unsafe_to_assume";
    return model;
}

fn unsafeIncident(event: RawDaemonEvent) bool {
    if (!std.mem.eql(u8, event.event, "incident")) return false;
    if (statusEq(event, "unsafe_to_assume")) return true;
    const reason = event.reason orelse return false;
    return std.mem.eql(u8, reason, "private_fields_rejected") or
        std.mem.eql(u8, reason, "malformed_runtime_sample") or
        std.mem.eql(u8, reason, "stream_backpressure_dropped");
}

fn statusEq(event: RawDaemonEvent, expected: []const u8) bool {
    return event.status != null and std.mem.eql(u8, event.status.?, expected);
}

fn extractString(line: []const u8, key: []const u8) ?[]const u8 {
    var needle_buffer: [64]u8 = undefined;
    if (key.len + 4 > needle_buffer.len) return null;
    needle_buffer[0] = '"';
    @memcpy(needle_buffer[1 .. 1 + key.len], key);
    needle_buffer[1 + key.len] = '"';
    needle_buffer[2 + key.len] = ':';
    needle_buffer[3 + key.len] = '"';
    const needle = needle_buffer[0 .. key.len + 4];
    const start = std.mem.indexOf(u8, line, needle) orelse return null;
    var index = start + needle.len;
    while (index < line.len) : (index += 1) {
        if (line[index] == '"' and (index == 0 or line[index - 1] != '\\')) return line[start + needle.len .. index];
    }
    return null;
}

fn recordArtifact(model: *fixture.SnapshotModel, artifact: []const u8) void {
    if (artifact.len == 0) return;
    if (std.mem.endsWith(u8, artifact, "/summary.json")) {
        if (std.fs.path.dirname(artifact)) |parent| model.bundle_path = std.fs.path.basename(parent) else model.bundle_path = std.fs.path.basename(artifact);
    } else if (std.mem.indexOf(u8, artifact, "tui-vm-lab-") != null and std.mem.eql(u8, model.bundle_path, "none")) {
        model.bundle_path = std.fs.path.basename(artifact);
    }
}

test "daemon live model renders accepted lifecycle fields" {
    const raw =
        "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"event\":\"stage_started\",\"action\":\"run_lab_microvm_live\",\"state\":\"vm_only_pending\",\"status\":\"queued\",\"reason\":\"microvm_live_runner_start\",\"artifact\":\"evidence/lab/run-all/tui-vm-lab-123\",\"host_mutation\":false}\n" ++
        "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"event\":\"bpf_register\",\"action\":\"run_lab_microvm_live\",\"state\":\"zigsched_minimal\",\"status\":\"PASS\",\"reason\":\"runtime ops observed\",\"artifact\":\"evidence/lab/run-all/tui-vm-lab-123/partial-attach/partial-attach-evidence.json\",\"host_mutation\":false}\n" ++
        "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"event\":\"runtime_sample\",\"action\":\"run_lab_microvm_live\",\"state\":\"observing\",\"status\":\"PASS\",\"reason\":\"runtime samples accepted\",\"artifact\":\"evidence/lab/run-all/tui-vm-lab-123/observe-partial/runtime-samples.jsonl\",\"host_mutation\":false}\n" ++
        "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"event\":\"rollback\",\"action\":\"run_lab_microvm_live\",\"state\":\"rolled_back\",\"status\":\"PASS\",\"reason\":\"PASS\",\"host_mutation\":false}\n" ++
        "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"event\":\"cleanup\",\"action\":\"run_lab_microvm_live\",\"state\":\"clean\",\"status\":\"PASS\",\"reason\":\"process scan clean\",\"artifact\":\"evidence/lab/run-all/tui-vm-lab-123/summary.json\",\"host_mutation\":false}\n" ++
        "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"event\":\"validation\",\"action\":\"run_lab_microvm_live\",\"state\":\"vm_live_validated\",\"status\":\"PASS\",\"reason\":\"live bundle freshness accepted\",\"artifact\":\"evidence/lab/run-all/tui-vm-lab-123/summary.json\",\"host_mutation\":false}\n";
    const model = modelFromDaemonOutput(std.testing.allocator, raw, "done");
    try std.testing.expectEqualStrings("PASS", model.lab_status);
    try std.testing.expectEqualStrings("tui-vm-lab-123", model.bundle_path);
    try std.testing.expectEqualStrings("runtime samples accepted", model.runtime_samples);
    try std.testing.expect(std.mem.indexOf(u8, model.runtime_ops, "zigsched_minimal") != null);
    try std.testing.expectEqualStrings("rollback ready/completed", model.rollback_status);
    try std.testing.expectEqualStrings("cleanup receipt PASS", model.cleanup_status);
    try std.testing.expectEqualStrings("live bundle freshness accepted", model.lab_gate);
    try std.testing.expectEqualStrings("lab-only vm guest", model.lab_scope);
}
