//! One-command root-cause summary for a scheduler window. This is a reporting
//! layer over the streaming metric index and the advisor; it never mutates.

const std = @import("std");
const json = @import("../core/json.zig");
const sched_state = @import("../core/sched_state.zig");
const latency = @import("latency.zig");
const metrics_mod = @import("metrics.zig");
const advisor = @import("advisor.zig");
const report = @import("report.zig");
const rules = @import("rules.zig");

const Writer = std.Io.Writer;

pub const Report = struct {
    source: []const u8,
    window_ms: u64,
    events: usize,
    malformed: usize,
    lost: u64,
    out_of_order: u64,
    metrics: metrics_mod.Metrics,
    findings: []const advisor.Finding,
    rule_reports: []const rules.Report,
    pid_filter: ?i32 = null,
    comm_filter: ?[]const u8 = null,
};

fn includeTask(report_value: *const Report, task: metrics_mod.TaskMetric) bool {
    if (report_value.pid_filter) |pid| {
        if (task.pid != pid) return false;
    }
    if (report_value.comm_filter) |comm| {
        if (!std.mem.eql(u8, task.comm, comm)) return false;
    }
    return true;
}

fn causeTotal(metrics: *const metrics_mod.Metrics) u64 {
    var total: u64 = 0;
    for (metrics.causes) |stat| total +|= stat.count;
    return total;
}

fn taskComm(metrics: *const metrics_mod.Metrics, pid: i32) []const u8 {
    for (metrics.tasks) |task| {
        if (task.pid == pid) return task.comm;
    }
    return "?";
}

fn writeLatencySummary(w: *Writer, metrics: *const metrics_mod.Metrics) Writer.Error!void {
    try w.print(
        "latency: offcpu_samples={d} offcpu_unresolved={d} causes={d} preemptions={d} " ++
            "preempt_unresolved={d} chain_edges={d} chain_roots={d} chain_cycles={d} " ++
            "chain_depth_cuts={d} chain_truncated={s}\n",
        .{
            metrics.offcpu_samples,
            metrics.offcpu_unresolved,
            causeTotal(metrics),
            metrics.preemptions,
            metrics.preempt_unresolved,
            metrics.chain_edges,
            metrics.chain_roots,
            metrics.chain_cycles_cut,
            metrics.chain_depth_cut,
            if (metrics.chain_truncated) "yes" else "no",
        },
    );
}

/// OFF-CPU CAUSES: the bounded attribution of blocked-sleep samples to the
/// switch-out prev_state cause. Sorted by accumulated time then reason name.
fn writeOffcpuCauses(w: *Writer, metrics: *const metrics_mod.Metrics, limit: usize) Writer.Error!void {
    try w.writeAll("\nOFF-CPU CAUSES\n");
    const cause_names = @typeInfo(sched_state.Cause).@"enum".field_names;
    var indices: [sched_state.cause_count]usize = undefined;
    var count: usize = 0;
    for (metrics.causes, 0..) |stat, index| {
        if (stat.count == 0) continue;
        indices[count] = index;
        count += 1;
    }
    std.mem.sortUnstable(usize, indices[0..count], &metrics.causes, struct {
        fn less(stats: *const [sched_state.cause_count]metrics_mod.CauseStat, a: usize, b: usize) bool {
            if (stats[a].total_us != stats[b].total_us) return stats[a].total_us > stats[b].total_us;
            return a < b;
        }
    }.less);
    if (count == 0) {
        try w.writeAll("  (no blocked off-CPU samples in this window)\n");
        return;
    }
    var shown: usize = 0;
    for (indices[0..count]) |index| {
        if (shown == limit) break;
        shown += 1;
        try w.print("  {s:<20} samples={d:<7} total={d}ms\n", .{
            cause_names[index],
            metrics.causes[index].count,
            metrics.causes[index].total_us / 1000,
        });
    }
    if (count > shown) try w.writeAll("  (cause table truncated)\n");
}

/// PREEMPTION: involuntary switch-outs (prev_state == running) that resumed
/// without a wakeup. The recorder self task is excluded from the task ranking.
fn writePreemption(w: *Writer, report_value: *const Report, limit: usize) Writer.Error!void {
    const metrics = &report_value.metrics;
    try w.writeAll("\nPREEMPTION\n");
    try w.print("  preemptions={d} p95={d}ms unresolved={d}\n", .{
        metrics.preemptions,
        metrics.preempt.quantileUpper(950) / 1000,
        metrics.preempt_unresolved,
    });
    var shown: usize = 0;
    for (metrics.tasks) |task| {
        if (task.is_self or task.preemptions == 0 or !includeTask(report_value, task)) continue;
        if (shown == limit) break;
        shown += 1;
        try w.print("  {s:<20} pid={d:<7} n={d:<6} p95={d}ms\n", .{
            task.comm,
            @as(u32, @intCast(@max(0, task.pid))),
            task.preemptions,
            task.preempt_p95_us / 1000,
        });
    }
    if (shown == 0) try w.writeAll("  (no involuntary preemptions detected)\n");
}

/// CRITICAL CHAINS: wakeup chains ranked by accumulated wake-to-run wait. A
/// chain root whose own waker was not observed is a lower bound, not zero.
fn writeCriticalChains(w: *Writer, metrics: *const metrics_mod.Metrics, limit: usize) Writer.Error!void {
    try w.writeAll("\nCRITICAL CHAINS\n");
    const count: usize = @min(@as(usize, metrics.chain_count), limit);
    if (count == 0) {
        try w.writeAll("  (no wakeup chains in this window)\n");
    }
    for (metrics.chains[0..count]) |chain| {
        try w.print("  root={s}:{d} -> leaf={s}:{d} depth={d} count={d} total={d}ms p95={d}ms\n", .{
            taskComm(metrics, chain.root_pid),
            chain.root_pid,
            chain.leaf_comm,
            chain.leaf_pid,
            chain.depth,
            chain.count,
            chain.total_wait_us / 1000,
            chain.p95_wait_us / 1000,
        });
    }
    try w.print(
        "  edges={d} roots={d} cycles_cut={d} depth_cut={d} truncated={s}\n",
        .{
            metrics.chain_edges,
            metrics.chain_roots,
            metrics.chain_cycles_cut,
            metrics.chain_depth_cut,
            if (metrics.chain_truncated) "yes" else "no",
        },
    );
}

pub fn writeText(w: *Writer, report_value: *const Report) Writer.Error!void {
    try w.print("xsprof why  source={s}  window={d}ms  events={d} malformed={d}\n", .{
        report_value.source,
        report_value.window_ms,
        report_value.events,
        report_value.malformed,
    });
    try w.print(
        "switches={d} wakeups={d} migrations={d} faults={d}/{d} lost={d} out_of_order={d}\n",
        .{
            report_value.metrics.switches,
            report_value.metrics.wakeups,
            report_value.metrics.migrations,
            report_value.metrics.faults_minor,
            report_value.metrics.faults_major,
            report_value.lost,
            report_value.out_of_order,
        },
    );
    if (report_value.out_of_order != 0) {
        try w.writeAll("caveat: replayed rows are not timestamp-sorted; correlation is best-effort.\n");
    }
    if (report_value.lost != 0) {
        try w.writeAll("caveat: sample loss is present; findings may under-count activity.\n");
    }
    try writeLatencySummary(w, &report_value.metrics);

    try w.writeAll("\nTOP WAIT TASKS\n");
    var shown: usize = 0;
    for (report_value.metrics.tasks) |task| {
        if (task.is_self or task.wait_samples == 0 or !includeTask(report_value, task)) continue;
        if (shown == 8) break;
        shown += 1;
        try w.print("  {s:<20} pid={d:<7} p95={d}ms p99={d}ms offcpu95={d}ms switches={d}\n", .{
            task.comm,
            @as(u32, @intCast(@max(0, task.pid))),
            task.wait_p95_us / 1000,
            task.wait_p99_us / 1000,
            task.offcpu_p95_us / 1000,
            task.switches,
        });
    }
    if (shown == 0) try w.writeAll("  (no wait samples in this window)\n");

    if (report_value.metrics.wakeup_pairs.len != 0) {
        try w.writeAll("\nWAKEUP CHAINS (waker -> woken)\n");
        var pairs: usize = 0;
        for (report_value.metrics.wakeup_pairs) |pair| {
            if (pairs == 8) break;
            pairs += 1;
            try w.print("  {s}:{d} -> {s}:{d}  count={d} p95={d}ms\n", .{
                pair.waker_comm,
                @as(u32, @intCast(@max(0, pair.waker_pid))),
                pair.woken_comm,
                @as(u32, @intCast(@max(0, pair.woken_pid))),
                pair.count,
                pair.p95_wait_us / 1000,
            });
        }
        if (report_value.metrics.pairs_truncated) try w.writeAll("  (pair table truncated)\n");
    }

    try writeOffcpuCauses(w, &report_value.metrics, 8);
    try writePreemption(w, report_value, 4);
    try writeCriticalChains(w, &report_value.metrics, 8);

    try w.writeAll("\nINSIGHTS\n");
    if (report_value.findings.len == 0) {
        try w.writeAll("  no advisor threshold breached with the collected signals\n");
    }
    for (report_value.findings) |finding| {
        try w.print("  [{s}/{s}] {s}\n", .{
            advisor.severityName(finding.severity),
            advisor.confidenceName(finding.confidence),
            finding.summary,
        });
        for (finding.evidence) |line| try w.print("    evidence: {s}\n", .{line});
    }
    try w.writeAll("\nRULE STATUS\n");
    for (report_value.rule_reports) |rule| {
        try w.print("  {s:<24} {s}", .{ rule.id, @tagName(rule.status) });
        if (rule.reason.len != 0) try w.print("  ({s})", .{rule.reason});
        try w.writeByte('\n');
    }
}

pub fn writeJson(w: *Writer, report_value: *const Report) Writer.Error!void {
    try w.writeAll("{\"cpus\":[");
    for (report_value.metrics.cpus, 0..) |cpu, index| {
        if (index != 0) try w.writeByte(',');
        try json.write(w, .{ .object = &.{
            .{ .key = "busy_us", .value = .{ .unsigned = cpu.busy_us } },
            .{ .key = "cpu", .value = .{ .unsigned = cpu.cpu } },
            .{ .key = "faults", .value = .{ .unsigned = cpu.faults } },
            .{ .key = "idle_us", .value = .{ .unsigned = cpu.idle_us } },
            .{ .key = "switches", .value = .{ .unsigned = cpu.switches } },
        } });
    }
    try w.print("],\"events\":{d},\"findings\":[", .{report_value.events});
    for (report_value.findings, 0..) |finding, index| {
        if (index != 0) try w.writeByte(',');
        try report.writeFinding(w, finding);
    }
    try w.writeAll("],\"host_mutation\":false,\"latency\":");
    try latency.writeJson(w, &report_value.metrics);
    try w.writeAll(",\"lost\":");
    try json.write(w, .{ .unsigned = report_value.lost });
    try w.writeAll(",\"malformed\":");
    try json.write(w, .{ .unsigned = report_value.malformed });
    try w.writeAll(",\"out_of_order\":");
    try json.write(w, .{ .unsigned = report_value.out_of_order });
    try w.writeAll(",\"pairs\":[");
    for (report_value.metrics.wakeup_pairs, 0..) |pair, index| {
        if (index != 0) try w.writeByte(',');
        try json.write(w, .{ .object = &.{
            .{ .key = "count", .value = .{ .unsigned = pair.count } },
            .{ .key = "p95_wait_us", .value = .{ .unsigned = pair.p95_wait_us } },
            .{ .key = "waker_comm", .value = .{ .string = pair.waker_comm } },
            .{ .key = "waker_pid", .value = .{ .integer = pair.waker_pid } },
            .{ .key = "woken_comm", .value = .{ .string = pair.woken_comm } },
            .{ .key = "woken_pid", .value = .{ .integer = pair.woken_pid } },
        } });
    }
    try w.writeAll("],\"rules\":[");
    for (report_value.rule_reports, 0..) |rule, index| {
        if (index != 0) try w.writeByte(',');
        try report.writeRule(w, rule);
    }
    try w.writeAll("],\"schema\":\"xsprof/why/v1\",\"source\":");
    try json.write(w, .{ .string = report_value.source });
    try w.writeAll(",\"tasks\":[");
    var task_index: usize = 0;
    for (report_value.metrics.tasks) |task| {
        if (task.is_self or !includeTask(report_value, task)) continue;
        if (task_index == 64) break;
        if (task_index != 0) try w.writeByte(',');
        task_index += 1;
        try json.write(w, .{ .object = &.{
            .{ .key = "comm", .value = .{ .string = task.comm } },
            .{ .key = "faults_major", .value = .{ .unsigned = task.faults_major } },
            .{ .key = "faults_minor", .value = .{ .unsigned = task.faults_minor } },
            .{ .key = "last_cpu", .value = .{ .integer = task.last_cpu } },
            .{ .key = "migrations", .value = .{ .unsigned = task.migrations } },
            .{ .key = "offcpu_p95_us", .value = .{ .unsigned = task.offcpu_p95_us } },
            .{ .key = "pid", .value = .{ .integer = task.pid } },
            .{ .key = "switches", .value = .{ .unsigned = task.switches } },
            .{ .key = "wait_p95_us", .value = .{ .unsigned = task.wait_p95_us } },
            .{ .key = "wait_p99_us", .value = .{ .unsigned = task.wait_p99_us } },
            .{ .key = "wakeups", .value = .{ .unsigned = task.wakeups } },
        } });
    }
    try w.print("],\"window_ms\":{d}}}\n", .{report_value.window_ms});
}

test "why JSON includes pairs and findings" {
    const tasks = [_]metrics_mod.TaskMetric{
        .{ .pid = 1, .comm = "worker", .wait_p95_us = 2000, .wait_samples = 1 },
    };
    const pairs = [_]metrics_mod.WakeupPair{
        .{ .waker_pid = 2, .woken_pid = 1, .waker_comm = "waker", .woken_comm = "worker", .count = 1, .p95_wait_us = 2000 },
    };
    const metrics: metrics_mod.Metrics = .{ .switches = 1, .tasks = &tasks, .wakeup_pairs = &pairs };
    const value: Report = .{ .source = "test", .window_ms = 10, .events = 1, .malformed = 0, .lost = 0, .out_of_order = 0, .metrics = metrics, .findings = &.{}, .rule_reports = &.{} };
    var buffer: [8192]u8 = undefined;
    var writer = Writer.fixed(&buffer);
    try writeJson(&writer, &value);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\"wakeup_pairs\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\"pairs\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\"schema\":\"xsprof/why/v1\"") != null);
}

test "why text reports off-cpu causes, preemption, and critical chains" {
    const tasks = [_]metrics_mod.TaskMetric{
        .{ .pid = 100, .comm = "worker", .preemptions = 2, .preempt_p95_us = 4_000 },
    };
    var metrics: metrics_mod.Metrics = .{ .tasks = &tasks };
    metrics.causes[@backingInt(sched_state.Cause.interruptible)] = .{ .count = 3, .total_us = 9_000 };
    metrics.offcpu_samples = 3;
    metrics.preemptions = 2;
    metrics.preempt.observe(4_000);
    metrics.chain_count = 1;
    metrics.chains[0] = .{
        .root_pid = 100,
        .leaf_pid = 101,
        .leaf_comm = "worker",
        .depth = 2,
        .count = 3,
        .total_wait_us = 9_000,
        .p95_wait_us = 5_000,
    };
    metrics.chain_edges = 3;
    metrics.chain_roots = 1;
    const value: Report = .{
        .source = "test",
        .window_ms = 10,
        .events = 3,
        .malformed = 0,
        .lost = 0,
        .out_of_order = 0,
        .metrics = metrics,
        .findings = &.{},
        .rule_reports = &.{},
    };
    var buffer: [8192]u8 = undefined;
    var writer = Writer.fixed(&buffer);
    try writeText(&writer, &value);
    const text = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "OFF-CPU CAUSES") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "interruptible") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "PREEMPTION") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "preemptions=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "CRITICAL CHAINS") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "root=worker:100 -> leaf=worker:101") != null);
    // The machine-readable summary line is what qa/latency_smoke.sh parses.
    try std.testing.expect(std.mem.indexOf(u8, text, "latency: offcpu_samples=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "chain_truncated=no") != null);
}
