const std = @import("std");
const protocol = @import("protocol.zig");

pub const CommandError = error{ InvalidAction, InvalidField, OutOfMemory };
pub const HostBehavior = enum { surrogate, refusal };

pub const EnvVar = struct { name: []const u8, value: []const u8 };

pub const CommandPlan = struct {
    executable: []const u8,
    argv: [12][]const u8,
    argc: usize,
    env: []const EnvVar,
    host_behavior: HostBehavior,
    out_dir: []const u8,

    pub fn args(self: *const CommandPlan) []const []const u8 {
        return self.argv[0..self.argc];
    }

    pub fn deinit(self: CommandPlan, allocator: std.mem.Allocator) void {
        allocator.free(self.out_dir);
    }
};

const clean_env = [_]EnvVar{
    .{ .name = "PATH", .value = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" },
    .{ .name = "ZIG_SCHEDULER_HOST_SAFE", .value = "1" },
    .{ .name = "HOME", .value = "/tmp" },
    .{ .name = "TMPDIR", .value = "/tmp" },
};

const object_path = "zig-out/bpf/zigsched_minimal.bpf.o";
const demo_target = "/sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope";

pub fn buildLabCommand(allocator: std.mem.Allocator, action: protocol.OperatorAction) CommandError!CommandPlan {
    const run_id = if (action.run_id.len == 0) "manual" else action.run_id;
    try validateToken(run_id);
    try validateOptional(action.target_cgroup);
    try validateAuditIdForAction(action);
    try validateRollbackIdForAction(action);

    return switch (action.kind) {
        .run_lab_host_safe => runAll(allocator, run_id),
        .run_lab_vm => runVm(allocator, run_id),
        .run_lab_microvm_live => runMicrovmLive(allocator, run_id),
        .verifier_only => verifierOnly(allocator, run_id),
        .partial_attach => partialAttach(allocator, action, run_id),
        .observe => observePartial(allocator, run_id),
        .rollback, .stop, .rollback_lab_run, .stop_lab_run => rollbackDrill(allocator, run_id),
        .incident_drill => incidentDrill(allocator, run_id),
        else => error.InvalidAction,
    };
}

fn runAll(allocator: std.mem.Allocator, run_id: []const u8) CommandError!CommandPlan {
    var plan = try basePlan(allocator, "qa/vm/run_all_lab.sh", "run-all", run_id, .surrogate);
    append(&plan, "--mode");
    append(&plan, "host-safe");
    append(&plan, "--out");
    append(&plan, plan.out_dir);
    return plan;
}

fn runVm(allocator: std.mem.Allocator, run_id: []const u8) CommandError!CommandPlan {
    var plan = try basePlan(allocator, "qa/vm/run_all_lab.sh", "run-all", run_id, .surrogate);
    inline for (.{ .{ "--mode", "vm-required" }, .{ "--env-file", "qa/vm/lab.env" }, .{ "--out", plan.out_dir }, .{ "--release-version", "0.2.0-lab-live" } }) |pair| {
        append(&plan, pair[0]);
        append(&plan, pair[1]);
    }
    return plan;
}

fn runMicrovmLive(allocator: std.mem.Allocator, run_id: []const u8) CommandError!CommandPlan {
    var plan = try basePlan(allocator, "qa/vm/run_microvm_live_lab.sh", "run-all", run_id, .surrogate);
    append(&plan, "--out");
    append(&plan, plan.out_dir);
    return plan;
}

fn verifierOnly(allocator: std.mem.Allocator, run_id: []const u8) CommandError!CommandPlan {
    var plan = try basePlan(allocator, "qa/vm/verifier_only.sh", "verifier-only", run_id, .refusal);
    append(&plan, "--object");
    append(&plan, object_path);
    append(&plan, "--out");
    append(&plan, plan.out_dir);
    return plan;
}

fn partialAttach(allocator: std.mem.Allocator, action: protocol.OperatorAction, run_id: []const u8) CommandError!CommandPlan {
    const target = if (action.target_cgroup.len == 0) demo_target else action.target_cgroup;
    const audit_id = action.audit_id;
    const rollback_id = action.rollback_id;
    var plan = try basePlan(allocator, "qa/vm/partial_attach.sh", "partial-attach", run_id, .refusal);
    inline for (.{ .{ "--target", target }, .{ "--audit-id", audit_id }, .{ "--rollback-id", rollback_id }, .{ "--out", plan.out_dir }, .{ "--object", object_path } }) |pair| {
        append(&plan, pair[0]);
        append(&plan, pair[1]);
    }
    return plan;
}

fn observePartial(allocator: std.mem.Allocator, run_id: []const u8) CommandError!CommandPlan {
    var plan = try basePlan(allocator, "qa/vm/observe_partial.sh", "observe-partial", run_id, .surrogate);
    append(&plan, "--samples");
    append(&plan, "3");
    append(&plan, "--out");
    append(&plan, plan.out_dir);
    return plan;
}

fn rollbackDrill(allocator: std.mem.Allocator, run_id: []const u8) CommandError!CommandPlan {
    var plan = try basePlan(allocator, "qa/vm/rollback_drill.sh", "rollback-drill", run_id, .surrogate);
    append(&plan, "--out");
    append(&plan, plan.out_dir);
    return plan;
}

fn incidentDrill(allocator: std.mem.Allocator, run_id: []const u8) CommandError!CommandPlan {
    var plan = try basePlan(allocator, "qa/vm/incident_drill.sh", "incident-drill", run_id, .surrogate);
    append(&plan, "--out");
    append(&plan, plan.out_dir);
    return plan;
}

fn basePlan(
    allocator: std.mem.Allocator,
    executable: []const u8,
    stage: []const u8,
    run_id: []const u8,
    behavior: HostBehavior,
) CommandError!CommandPlan {
    const out_dir = try std.fmt.allocPrint(allocator, "evidence/lab/{s}/{s}", .{ stage, run_id });
    var plan = CommandPlan{
        .executable = executable,
        .argv = undefined,
        .argc = 0,
        .env = clean_env[0..],
        .host_behavior = behavior,
        .out_dir = out_dir,
    };
    append(&plan, executable);
    return plan;
}

fn append(plan: *CommandPlan, value: []const u8) void {
    plan.argv[plan.argc] = value;
    plan.argc += 1;
}

fn validateOptional(value: []const u8) CommandError!void {
    if (value.len != 0) try validateText(value);
}

fn validateAuditIdForAction(action: protocol.OperatorAction) CommandError!void {
    if (action.kind != .run_lab_microvm_live and action.kind != .partial_attach) {
        try validateOptional(action.audit_id);
        return;
    }
    if (!protocol.validAuditIdShape(action.audit_id)) return error.InvalidField;
}

fn validateRollbackIdForAction(action: protocol.OperatorAction) CommandError!void {
    if (action.kind != .partial_attach) {
        try validateOptional(action.rollback_id);
        return;
    }
    if (action.rollback_id.len == 0) return error.InvalidField;
    try validateOptional(action.rollback_id);
}

fn validateToken(value: []const u8) CommandError!void {
    if (value.len == 0 or value.len > 80) return error.InvalidField;
    if (std.mem.eql(u8, value, ".") or std.mem.eql(u8, value, "..")) return error.InvalidField;
    if (value[0] == '.' or value[value.len - 1] == '.') return error.InvalidField;
    for (value) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and byte != '.') return error.InvalidField;
    }
}

fn validateText(value: []const u8) CommandError!void {
    if (value.len > 256) return error.InvalidField;
    for (value) |byte| {
        if (byte < 0x20 or byte == 0x7f) return error.InvalidField;
        switch (byte) {
            '`', '$', '&', '|', ';', '<', '>', '(', ')' => return error.InvalidField,
            else => {},
        }
    }
}
