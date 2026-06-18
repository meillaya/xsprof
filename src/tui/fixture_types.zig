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
    bundle_path: []const u8 = "none",
    cleanup_status: []const u8 = "not-started",
    lab_scope: []const u8 = "host fail-closed",
    fixture_warning: []const u8 = "",
};

pub const TextFactJson = struct {
    status: []const u8,
    value: []const u8 = "",
};

pub const KernelJson = struct {
    release: []const u8 = "fixture-lab",
    arch: []const u8 = "x86_64",
};

pub const SchedExtJson = struct {
    state: TextFactJson = .{ .status = "disabled" },
    enable_seq: TextFactJson = .{ .status = "unavailable" },
    switch_all: TextFactJson = .{ .status = "partial" },
    nr_rejected: TextFactJson = .{ .status = "0" },
};

pub const BtfJson = struct {
    status: []const u8 = "fixture",
};

pub const CgroupJson = struct {
    status: []const u8 = "fixture",
    controllers: []const u8 = "",
};

pub const CapabilityJson = struct {
    effective: []const u8 = "",
};

pub const StageJson = struct {
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
    bundle_path: []const u8 = "",
    cleanup_status: []const u8 = "",
    lab_scope: []const u8 = "",
    stages: []StageJson = &.{},
};
