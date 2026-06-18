const std = @import("std");
const types = @import("fixture_types.zig");

const PreflightFixture = types.PreflightFixture;
const SnapshotModel = types.SnapshotModel;
const TextFactJson = types.TextFactJson;

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
        .bundle_path = bundlePath(value),
        .cleanup_status = cleanupStatus(value),
        .lab_scope = labScope(value),
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
    if (isRunAllSummary(value) and std.mem.eql(u8, value.status, "PASS") and std.mem.eql(u8, value.incident_status, "unsafe_to_assume")) {
        return "unsafe_to_assume";
    }
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

fn bundlePath(value: PreflightFixture) []const u8 {
    if (value.bundle_path.len != 0) {
        if (std.fs.path.dirname(value.bundle_path)) |parent| return std.fs.path.basename(parent);
        return std.fs.path.basename(value.bundle_path);
    }
    if (isRunAllSummary(value)) return "bundle path required";
    return "none";
}

fn cleanupStatus(value: PreflightFixture) []const u8 {
    if (value.cleanup_status.len != 0) return value.cleanup_status;
    if (isRunAllSummary(value) and std.mem.eql(u8, value.status, "PASS")) return "cleanup receipt required";
    return "not-started";
}

fn labScope(value: PreflightFixture) []const u8 {
    if (value.lab_scope.len != 0) return value.lab_scope;
    if (std.mem.eql(u8, evidenceMode(value), "vm-live")) return "lab-only vm guest";
    return "host fail-closed";
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
