const std = @import("std");

pub const SnapshotModel = struct {
    kernel_release: []const u8,
    arch: []const u8,
    cgroup_status: []const u8,
    cgroup_controllers: []const u8,
    capabilities: []const u8,
    sched_state: []const u8,
    sched_enable_seq: []const u8,
    sched_switch_all: []const u8,
    sched_nr_rejected: []const u8,
    btf_status: []const u8,
    lab_status: []const u8 = "read-only",
    partial_status: []const u8 = "partial switch required",
    rollback_requirement: []const u8 = "rollback-required before attach",
    post_rollback_health: []const u8 = "required",
    state_restored: []const u8 = "read-only",
    workload_liveness: []const u8 = "not-started",
    audit_id: []const u8 = "required",
    rollback_id: []const u8 = "required",
    lab_gate: []const u8 = "missing",
    evidence_mode: []const u8 = "live-read-only",
    verifier_status: []const u8 = "pending",
    dsq_status: []const u8 = "pending",
    stress_status: []const u8 = "pending",
    audit_status: []const u8 = "pending",
    release_gate_status: []const u8 = "closed",
    current_stage: []const u8 = "preflight",
    vm_marker: []const u8 = "none",
    runtime_samples: []const u8 = "not-started",
    runtime_ops: []const u8 = "not-attached",
    runtime_counters: []const u8 = "nr_rejected=unknown",
    rollback_status: []const u8 = "rollback required",
    incident_status: []const u8 = "none",
    release_eligibility: []const u8 = "not release eligible",
    fixture_warning: []const u8 = "",
};

const TextFactJson = struct {
    status: []const u8,
    value: []const u8 = "",
};

const KernelJson = struct {
    release: []const u8 = "fixture-lab",
    arch: []const u8 = "x86_64",
};

const SchedExtJson = struct {
    state: TextFactJson = .{ .status = "disabled" },
    enable_seq: TextFactJson = .{ .status = "unavailable" },
    switch_all: TextFactJson = .{ .status = "partial" },
    nr_rejected: TextFactJson = .{ .status = "0" },
};

const BtfJson = struct {
    status: []const u8 = "fixture",
};

const CgroupJson = struct {
    status: []const u8 = "fixture",
    controllers: []const u8 = "",
};

const CapabilityJson = struct {
    effective: []const u8 = "",
};

const StageJson = struct {
    stage: []const u8 = "",
    status: []const u8 = "",
    reason: []const u8 = "",
};

pub const PreflightFixture = struct {
    kernel: KernelJson = .{},
    sched_ext: SchedExtJson = .{},
    btf: BtfJson = .{},
    cgroup_v2: CgroupJson = .{},
    capabilities: CapabilityJson = .{},
    schema: []const u8 = "",
    status: []const u8 = "",
    audit_id: []const u8 = "required",
    rollback_id: []const u8 = "required",
    post_rollback_health: []const u8 = "required",
    state_restored: []const u8 = "read-only",
    workload_alive: bool = false,
    rollback_snapshot: []const u8 = "",
    transcript: []const u8 = "",
    mode: []const u8 = "",
    vm_kind: []const u8 = "",
    evidence_mode: []const u8 = "",
    release_status: []const u8 = "",
    release_use: bool = false,
    release_eligible_live_proof: bool = false,
    rollback_result: []const u8 = "",
    current_stage: []const u8 = "",
    vm_marker: []const u8 = "",
    runtime_samples: []const u8 = "",
    runtime_ops: []const u8 = "",
    runtime_counters: []const u8 = "",
    incident_status: []const u8 = "",
    stages: []StageJson = &.{},
};

pub fn load(allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed(PreflightFixture) {
    const source = try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .unlimited);
    defer allocator.free(source);
    return std.json.parseFromSlice(PreflightFixture, allocator, source, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
}

pub fn model(value: PreflightFixture) SnapshotModel {
    return .{
        .kernel_release = value.kernel.release,
        .arch = value.kernel.arch,
        .cgroup_status = value.cgroup_v2.status,
        .cgroup_controllers = value.cgroup_v2.controllers,
        .capabilities = value.capabilities.effective,
        .sched_state = factText(value.sched_ext.state),
        .sched_enable_seq = factText(value.sched_ext.enable_seq),
        .sched_switch_all = factText(value.sched_ext.switch_all),
        .sched_nr_rejected = factText(value.sched_ext.nr_rejected),
        .btf_status = value.btf.status,
        .lab_status = labStatus(value),
        .partial_status = partialStatus(value),
        .rollback_requirement = rollbackRequirement(value),
        .post_rollback_health = value.post_rollback_health,
        .state_restored = value.state_restored,
        .workload_liveness = if (value.workload_alive) "alive" else "not-started",
        .audit_id = value.audit_id,
        .rollback_id = value.rollback_id,
        .lab_gate = labGate(value),
        .evidence_mode = evidenceMode(value),
        .verifier_status = stageStatus(value, "verifier_only", "pending"),
        .dsq_status = stageStatus(value, "dsq_policy_smoke", "pending"),
        .stress_status = stageStatus(value, "stress_chaos", "pending"),
        .audit_status = auditStatus(value),
        .release_gate_status = releaseGateStatus(value),
        .current_stage = currentStage(value),
        .vm_marker = vmMarker(value),
        .runtime_samples = runtimeSamples(value),
        .runtime_ops = runtimeOps(value),
        .runtime_counters = runtimeCounters(value),
        .rollback_status = rollbackStatus(value),
        .incident_status = incidentStatus(value),
        .release_eligibility = releaseEligibility(value),
        .fixture_warning = "FIXTURE deterministic host facts; do not infer live support",
    };
}

fn factText(fact: TextFactJson) []const u8 {
    if (fact.value.len == 0) return fact.status;
    return fact.value;
}

fn isRollbackSummary(value: PreflightFixture) bool {
    return std.mem.eql(u8, value.schema, "zig-scheduler/rollback-drill-summary/v1");
}

fn isRunAllSummary(value: PreflightFixture) bool {
    return std.mem.eql(u8, value.schema, "zig-scheduler/run-all-lab/v1");
}

fn labStatus(value: PreflightFixture) []const u8 {
    if (isRunAllSummary(value)) return value.status;
    if (!isRollbackSummary(value)) return "read-only";
    if (std.mem.eql(u8, value.status, "PASS")) return "fallback-fired";
    if (std.mem.eql(u8, value.status, "REJECTED")) return "rejected";
    return value.status;
}

fn partialStatus(value: PreflightFixture) []const u8 {
    if (isRunAllSummary(value)) return stageStatus(value, "partial_attach", "pending");
    if (isRollbackSummary(value)) return "attached-partial observed";
    return "verifier-ready pending";
}

fn rollbackRequirement(value: PreflightFixture) []const u8 {
    if (isRunAllSummary(value)) return stageStatus(value, "rollback_drill", "required");
    if (isRollbackSummary(value) and std.mem.eql(u8, value.post_rollback_health, "PASS")) {
        return "rollback-required cleared";
    }
    return "rollback-required";
}

fn labGate(value: PreflightFixture) []const u8 {
    if (isRunAllSummary(value) and value.release_status.len != 0) return value.release_status;
    if (isRollbackSummary(value)) return "rollback evidence present";
    return "missing";
}

fn evidenceMode(value: PreflightFixture) []const u8 {
    if (value.evidence_mode.len != 0) return value.evidence_mode;
    if (value.vm_kind.len != 0) return value.vm_kind;
    if (value.mode.len != 0) return value.mode;
    return "live-read-only";
}

fn auditStatus(value: PreflightFixture) []const u8 {
    if (isRunAllSummary(value)) return stageStatus(value, "observe_partial", "pending");
    if (isRollbackSummary(value) and value.audit_id.len != 0) return "ledger-linked";
    return "pending";
}

fn releaseGateStatus(value: PreflightFixture) []const u8 {
    if (isRunAllSummary(value)) {
        const status = stageStatus(value, "release_gate", "");
        if (status.len != 0) return status;
        if (value.release_status.len != 0) return value.release_status;
    }
    return "closed";
}

fn currentStage(value: PreflightFixture) []const u8 {
    if (value.current_stage.len != 0) return value.current_stage;
    if (!isRunAllSummary(value)) return "preflight";
    if (!std.mem.eql(u8, stageStatus(value, "observe_partial", ""), "")) return "observe_partial";
    if (!std.mem.eql(u8, stageStatus(value, "partial_attach", ""), "")) return "partial_attach";
    if (!std.mem.eql(u8, stageStatus(value, "verifier_only", ""), "")) return "verifier_only";
    return "run_all_pending";
}

fn vmMarker(value: PreflightFixture) []const u8 {
    if (value.vm_marker.len != 0) return value.vm_marker;
    if (value.vm_kind.len != 0 and !std.mem.eql(u8, value.vm_kind, "host-safe-surrogate")) return "marker required";
    return "host-safe none";
}

fn runtimeSamples(value: PreflightFixture) []const u8 {
    if (value.runtime_samples.len != 0) return value.runtime_samples;
    if (std.mem.eql(u8, stageStatus(value, "observe_partial", ""), "PASS")) return "observe_partial PASS";
    return "not-started";
}

fn runtimeOps(value: PreflightFixture) []const u8 {
    if (value.runtime_ops.len != 0) return value.runtime_ops;
    if (std.mem.eql(u8, stageStatus(value, "partial_attach", ""), "PASS")) return "ops recorded";
    return "not-attached";
}

fn runtimeCounters(value: PreflightFixture) []const u8 {
    if (value.runtime_counters.len != 0) return value.runtime_counters;
    return factText(value.sched_ext.nr_rejected);
}

fn rollbackStatus(value: PreflightFixture) []const u8 {
    if (value.rollback_result.len != 0) return "rollback ready/completed";
    if (std.mem.eql(u8, stageStatus(value, "rollback_drill", ""), "PASS")) return "rollback ready/completed";
    return rollbackRequirement(value);
}

fn incidentStatus(value: PreflightFixture) []const u8 {
    if (value.incident_status.len != 0) return value.incident_status;
    if (std.mem.eql(u8, stageStatus(value, "observe_partial", ""), "PASS")) return "none";
    return "unsafe_to_assume";
}

fn releaseEligibility(value: PreflightFixture) []const u8 {
    if (value.release_eligible_live_proof) return "eligible with live proof";
    if (value.release_use) return "pending signed proof";
    return "not release eligible";
}

fn stageStatus(value: PreflightFixture, name: []const u8, fallback: []const u8) []const u8 {
    for (value.stages) |stage| {
        if (std.mem.eql(u8, stage.stage, name)) {
            if (stage.reason.len == 0) return stage.status;
            if (stage.status.len == 0) return stage.reason;
            return stage.status;
        }
    }
    return fallback;
}
