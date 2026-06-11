const fixture = @import("fixture.zig");
const layout = @import("layout.zig");

const row = layout.row;
const section = layout.section;

pub fn renderPreflight(writer: anytype, width: usize, model: fixture.SnapshotModel) !void {
    try section(writer, width, "Host Preflight", "Safety Gate");
    try row(writer, width, "kernel tuple", model.kernel_release, "read-only opens only");
    try row(writer, width, "arch", model.arch, "no cgroup writes");
    try row(writer, width, "cgroup v2", model.cgroup_status, "no affinity/scheduler writes");
    try row(writer, width, "controllers", model.cgroup_controllers, "no BPF load path");
    try row(writer, width, "capabilities", model.capabilities, "refuse unsafe verbs");
    try row(writer, width, "sched_ext", model.sched_state, "lab gate required later");
    try row(writer, width, "BTF", model.btf_status, "lab gate required later");
    try section(writer, width, "Read-only Probe Matrix", "Mutation Refusals");
    try row(writer, width, "/sys/kernel/sched_ext/state", model.sched_state, "load: refused");
    try row(writer, width, "enable_seq", model.sched_enable_seq, "attach: refused");
    try row(writer, width, "switch_all", model.sched_switch_all, "enable: refused");
    try row(writer, width, "nr_rejected", model.sched_nr_rejected, "mutate: refused");
    try row(writer, width, "/sys/kernel/btf/vmlinux", model.btf_status, "apply: refused");
    try section(writer, width, "Operator Checklist", "Evidence Channel");
    try row(writer, width, "lab tuple", "required later", "tmux transcript");
    try row(writer, width, "rollback id", "required before writes", "audit id required");
    try row(writer, width, "fallback drill", "required before load", "partial switch first");
    try row(writer, width, "toolchain", "informational", "no compile/load here");
    try row(writer, width, "kernel config", "unsafe_to_assume if hidden", "do not infer support");
    try row(writer, width, "observer", "preflight only", "no performance claims");
    try row(writer, width, "decision", "closed", "operator approval missing");
    try row(writer, width, "mode", "read-only", "FAIL-CLOSED");
}

pub fn renderSchedExt(writer: anytype, width: usize, model: fixture.SnapshotModel) !void {
    try section(writer, width, "sched_ext Readiness", "Fallback Drill");
    try row(writer, width, "state", model.sched_state, "partial switch first");
    try row(writer, width, "enable_seq", model.sched_enable_seq, "fallback command recorded");
    try row(writer, width, "nr_rejected", model.sched_nr_rejected, "DSQ plan required");
    try row(writer, width, "BTF", model.btf_status, "no load before approval");
    try row(writer, width, "gate", "closed", "fallback: refuse live mutation");
    try section(writer, width, "sched_ext Lab Lifecycle", "Fixture Parity");
    try row(writer, width, "lab state", model.lab_status, "read-only verifier-ready");
    try row(writer, width, "partial attach", model.partial_status, "attached-partial scope");
    try row(writer, width, "rollback required", model.rollback_requirement, "rejected if missing");
    try row(writer, width, "fallback-fired", model.post_rollback_health, model.state_restored);
    try row(writer, width, "workload", model.workload_liveness, "health check required");
    try row(writer, width, "audit id", model.audit_id, "append-only ledger");
    try row(writer, width, "rollback id", model.rollback_id, "immutable snapshot");
    try section(writer, width, "Gate Ledger", "No-load Contract");
    try row(writer, width, "approved lab", model.lab_gate, "load command absent");
    try row(writer, width, "kernel tuple", model.kernel_release, "attach command absent");
    try row(writer, width, "CONFIG_SCHED_CLASS_EXT", "not assumed", "enable command absent");
    try row(writer, width, "BPF support", "not assumed", "mutate command absent");
    try section(writer, width, "Dispatch Queue Plan", "Verifier Plan");
    try row(writer, width, "DSQ mapping", "design gate pending", "capture verifier log");
    try row(writer, width, "partial switch", "required", "reject on verifier fail");
    try row(writer, width, "fallback", "drill required", "auto-unload documented");
}

pub fn renderController(writer: anytype, width: usize) !void {
    try section(writer, width, "Controller Dry Run", "Refusal Reasons");
    try row(writer, width, "plan", "preview only", "lab gate missing");
    try row(writer, width, "audit id", "required", "rollback id missing");
    try row(writer, width, "allowlist", "required", "operator confirm missing");
}

pub fn renderObserver(writer: anytype, width: usize) !void {
    try section(writer, width, "Observer", "Caveats");
    try row(writer, width, "live observer", "preflight only", "preflight-only caveat");
    try row(writer, width, "offline fixtures", "descriptive", "no Linux performance claims");
}

pub fn renderHelp(writer: anytype, width: usize) !void {
    try section(writer, width, "Help", "Keys");
    try row(writer, width, "model", "fail-closed", "q/ctrl-c quit");
    try row(writer, width, "scope", "lab gated", "? help, h home, w theme");
}
