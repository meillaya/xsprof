const linux = @import("linux_scheduler");
const fixture = @import("fixture.zig");

pub fn live(report: linux.PreflightReport) fixture.SnapshotModel {
    return .{
        .kernel_release = report.kernel_release,
        .arch = report.arch,
        .cgroup_status = @tagName(report.cgroup_v2.status),
        .cgroup_controllers = report.cgroup_v2.controllers,
        .capabilities = report.capabilities.effective_hex,
        .sched_state = factText(report.sched_ext.state),
        .sched_enable_seq = factText(report.sched_ext.enable_seq),
        .sched_switch_all = factText(report.sched_ext.switch_all),
        .sched_nr_rejected = factText(report.sched_ext.nr_rejected),
        .btf_status = @tagName(report.btf.status),
        .lab_scope = "host fail-closed",
        .bundle_path = "none",
        .cleanup_status = "not-started",
    };
}

fn factText(fact: linux.sched_ext.TextFact) []const u8 {
    if (fact.value.len == 0) return @tagName(fact.status);
    return fact.value;
}
