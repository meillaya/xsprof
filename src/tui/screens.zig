const fixture = @import("fixture.zig");
const layout = @import("layout.zig");

const row = layout.row;
const section = layout.section;

pub fn renderPreflight(writer: anytype, width: usize, model: fixture.SnapshotModel) !void {
    try section(writer, width, "dashboard home", "operator sources");
    try row(writer, width, "choose a flow", "preflight", "read-only host facts");
    try row(writer, width, "sched_ext readiness", model.sched_state, "BTF + kernel tuple");
    try row(writer, width, "live microVM lab", model.lab_scope, "m key launches gated flow later");
    try row(writer, width, "rollback / audit", model.rollback_status, model.audit_id);
    try row(writer, width, "observer", model.runtime_samples, "runtime stream caveats");
    try section(writer, width, "host facts", "safety gate");
    try row(writer, width, "kernel tuple", model.kernel_release, model.arch);
    try row(writer, width, "cgroup v2", model.cgroup_status, "no cgroup writes");
    try row(writer, width, "controllers", model.cgroup_controllers, "no affinity/scheduler writes");
    try row(writer, width, "capabilities", model.capabilities, "refuse unsafe verbs");
    try row(writer, width, "sched_ext", model.sched_state, "no BPF load path on host");
    try row(writer, width, "BTF", model.btf_status, "lab gate required");
    try section(writer, width, "start here", "recent evidence");
    try row(writer, width, "1 preflight", "zig build tui -- --screen preflight", "snapshot only");
    try row(writer, width, "2 live lab", "zig build tui-live-vm", "VM-only attach path");
    try row(writer, width, "3 rollback", "b rollback after m", "audit id required");
    try row(writer, width, "4 observe", "runtime samples", "no performance claims");
    try row(writer, width, "recent", model.bundle_path, model.cleanup_status);
    try section(writer, width, "operator contract", "FAIL-CLOSED");
    try row(writer, width, "unsafe verbs", "load attach enable mutate apply", "refused");
    try row(writer, width, "lab boundary", model.evidence_mode, "host fail-closed");
    try row(writer, width, "decision", "closed", "operator approval missing");
}

pub fn renderSchedExt(writer: anytype, width: usize, model: fixture.SnapshotModel) !void {
    try section(writer, width, "sched_ext status", "fallback drill");
    try row(writer, width, "state", model.sched_state, "partial switch first");
    try row(writer, width, "enable_seq", model.sched_enable_seq, "fallback command recorded");
    try row(writer, width, "nr_rejected", model.sched_nr_rejected, "DSQ plan required");
    try row(writer, width, "BTF", model.btf_status, "no load before approval");
    try section(writer, width, "sched_ext Lab Lifecycle", "Live Lab Stream");
    try row(writer, width, "evidence mode", model.evidence_mode, "fixture/host/vm separated");
    try row(writer, width, "lab state", model.lab_status, model.current_stage);
    try row(writer, width, "verifier", model.verifier_status, "verifier-ready check");
    try row(writer, width, "partial attach", model.partial_status, model.runtime_ops);
    try row(writer, width, "runtime samples", model.runtime_samples, model.runtime_counters);
    try row(writer, width, "rollback status", model.rollback_status, model.rollback_id);
    try row(writer, width, "incident", model.incident_status, "unsafe_to_assume on gaps");
    try section(writer, width, "Gate Ledger", "No-load Contract");
    try row(writer, width, "lab scope", model.lab_scope, "host fail-closed");
    try row(writer, width, "bundle path", model.bundle_path, "freshness required");
    try row(writer, width, "cleanup status", model.cleanup_status, "process scan required");
    try row(writer, width, "vm marker", model.vm_marker, model.evidence_mode);
    try row(writer, width, "kernel tuple", model.kernel_release, model.arch);
    try row(writer, width, "audit id", model.audit_id, model.audit_status);
    try row(writer, width, "release eligible", model.release_eligibility, model.release_gate_status);
    try row(writer, width, "approved lab", model.lab_gate, "load command absent");
}

pub fn renderVmLab(writer: anytype, width: usize, model: fixture.SnapshotModel) !void {
    try section(writer, width, "lifecycle lanes", model.current_stage);
    try row(writer, width, "preflight build boot", model.lab_status, model.incident_status);
    try row(writer, width, "marker verifier attach", model.verifier_status, model.runtime_ops);
    try row(writer, width, "observe rollback audit cleanup", model.runtime_samples, model.cleanup_status);
    try row(writer, width, "progress", "▰▰▰▰▰▰▰▰▰▱", "VM-only attach path");
    try row(writer, width, "lab scope", model.lab_scope, "host fail-closed");
    try row(writer, width, "vm marker", model.vm_marker, model.evidence_mode);
    try row(writer, width, "bundle", model.bundle_path, model.cleanup_status);
    try section(writer, width, "event stream", "current stage");
    try row(writer, width, "microvm_boot", model.current_stage, "guest-only");
    try row(writer, width, "bpf_register", model.runtime_ops, "no host load");
    try row(writer, width, "runtime_sample", model.runtime_samples, model.runtime_counters);
    try row(writer, width, "rollback", model.rollback_status, model.rollback_id);
    try row(writer, width, "validation", model.lab_gate, model.release_gate_status);
    try section(writer, width, "runtime counters", "audit / rollback ledger");
    try row(writer, width, "ops", model.runtime_ops, "zigsched_minimal required during attach");
    try row(writer, width, "samples", model.runtime_samples, "before / during / after");
    try row(writer, width, "counters", model.runtime_counters, "reject/fallback/fatal stable");
    try row(writer, width, "audit id", model.audit_id, model.audit_status);
    try row(writer, width, "rollback id", model.rollback_id, model.rollback_status);
    try section(writer, width, "safety contract", "not release proof");
    try row(writer, width, "release eligible", model.release_eligibility, "signed live proof withheld");
    try row(writer, width, "cleanup", model.cleanup_status, "process scan required");
}

pub fn renderController(writer: anytype, width: usize, model: fixture.SnapshotModel) !void {
    try section(writer, width, "Controller Dry Run", "Refusal Reasons");
    try row(writer, width, "plan", "preview only", "lab gate missing");
    try row(writer, width, "current stage", model.current_stage, model.evidence_mode);
    try row(writer, width, "audit id", model.audit_id, model.rollback_status);
    try row(writer, width, "allowlist", "required", "operator confirm missing");
    try row(writer, width, "release eligible", model.release_eligibility, model.release_gate_status);
}

pub fn renderObserver(writer: anytype, width: usize, model: fixture.SnapshotModel) !void {
    try section(writer, width, "Observer", "Live Stream Caveats");
    try row(writer, width, "runtime samples", model.runtime_samples, model.runtime_ops);
    try row(writer, width, "vm marker", model.vm_marker, model.evidence_mode);
    try row(writer, width, "incident", model.incident_status, "no performance claims");
    try row(writer, width, "audit id", model.audit_id, model.audit_status);
    try row(writer, width, "offline fixtures", "descriptive", "claim boundary held");
}

pub fn renderHelp(writer: anytype, width: usize) !void {
    try section(writer, width, "Help", "Keys");
    try row(writer, width, "model", "fail-closed", "q quit  m vm lab");
    try row(writer, width, "rollback", "b confirm/send", "s stop uses rollback id");
    try row(writer, width, "scope", "lab gated", "? help, h home, w theme");
}
