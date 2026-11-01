//! Canonical advisor report writers. Findings are evidence only; every rule
//! also reports its status so an uncollected signal can never read as CLEAR.

const std = @import("std");
const json = @import("../core/json.zig");
const aggregates = @import("aggregates.zig");
const advisor = @import("advisor.zig");
const rules = @import("rules.zig");

const Writer = std.Io.Writer;
const Aggregates = aggregates.Aggregates;

fn writeRecommendation(w: *Writer, rec: advisor.Recommendation) Writer.Error!void {
    try json.write(w, .{ .object = &.{
        .{ .key = "detail", .value = .{ .string = rec.detail } },
        .{ .key = "kind", .value = .{ .string = rec.kind } },
        .{ .key = "rationale", .value = .{ .string = rec.rationale } },
    } });
}

pub fn writeFinding(w: *Writer, finding: advisor.Finding) Writer.Error!void {
    try w.writeByte('{');
    try w.writeAll("\"confidence\":");
    try json.write(w, .{ .string = advisor.confidenceName(finding.confidence) });
    try w.writeAll(",\"evidence\":[");
    for (finding.evidence, 0..) |line, i| {
        if (i != 0) try w.writeByte(',');
        try json.write(w, .{ .string = line });
    }
    try w.writeAll("],\"id\":");
    try json.write(w, .{ .string = finding.id });
    try w.writeAll(",\"recommendations\":[");
    for (finding.recommendations, 0..) |rec, i| {
        if (i != 0) try w.writeByte(',');
        try writeRecommendation(w, rec);
    }
    try w.writeAll("],\"severity\":");
    try json.write(w, .{ .string = advisor.severityName(finding.severity) });
    try w.writeAll(",\"summary\":");
    try json.write(w, .{ .string = finding.summary });
    try w.writeByte('}');
}

pub fn writeRule(w: *Writer, report: rules.Report) Writer.Error!void {
    try w.writeAll("{\"id\":");
    try json.write(w, .{ .string = report.id });
    try w.writeAll(",\"reason\":");
    try json.write(w, .{ .string = report.reason });
    try w.writeAll(",\"status\":");
    try json.write(w, .{ .string = @tagName(report.status) });
    try w.writeByte('}');
}

pub fn writeReportJson(
    w: *Writer,
    allocator: std.mem.Allocator,
    agg: Aggregates,
    thresholds: advisor.Thresholds,
) !void {
    const findings = try advisor.analyze(allocator, agg, thresholds);
    defer advisor.freeFindings(allocator, findings);
    const report_list = try rules.reports(allocator, agg, findings);
    defer rules.freeReports(allocator, report_list);

    try w.writeAll("{\"capabilities\":{\"pmu_collected\":");
    try json.write(w, .{ .boolean = agg.pmu_collected });
    try w.writeAll(",\"sched_collected\":");
    try json.write(w, .{ .boolean = agg.sched_collected });
    try w.writeAll("},\"findings\":[");
    for (findings, 0..) |finding, i| {
        if (i != 0) try w.writeByte(',');
        try writeFinding(w, finding);
    }
    try w.writeAll("],\"host_mutation\":false,\"rules\":[");
    for (report_list, 0..) |report, i| {
        if (i != 0) try w.writeByte(',');
        try writeRule(w, report);
    }
    try w.writeAll("],\"schema\":\"xsprof/advisor-report/v1\"}\n");
}

fn statusText(status: rules.Status) []const u8 {
    return switch (status) {
        .finding => "FINDING",
        .clear => "CLEAR",
        .skip => "SKIP",
    };
}

fn signalText(value: bool) []const u8 {
    return if (value) "yes" else "no";
}

pub fn writeReportMarkdown(
    w: *Writer,
    allocator: std.mem.Allocator,
    agg: Aggregates,
    thresholds: advisor.Thresholds,
) !void {
    const findings = try advisor.analyze(allocator, agg, thresholds);
    defer advisor.freeFindings(allocator, findings);
    const report_list = try rules.reports(allocator, agg, findings);
    defer rules.freeReports(allocator, report_list);

    try w.writeAll("# xsprof Performance Advisor Report\n\n");
    try w.print("- PMU collected: {s}\n", .{signalText(agg.pmu_collected)});
    try w.print("- Scheduler collected: {s}\n", .{signalText(agg.sched_collected)});
    try w.print("- sched_switch: {s}\n", .{signalText(agg.signals.sched_switch)});
    try w.print("- sched_wakeup: {s}\n", .{signalText(agg.signals.sched_wakeup)});
    try w.print("- sched_migrate: {s}\n", .{signalText(agg.signals.sched_migrate)});
    try w.print("- CPU LLC topology: {s}\n", .{signalText(agg.signals.cpu_topology)});
    try w.print("- PMU HITM: {s}\n", .{signalText(agg.signals.pmu_hitm)});
    try w.print("- lock contention: {s}\n", .{signalText(agg.signals.lock_contention)});
    try w.print("- allocator/buddyinfo: {s}\n", .{signalText(agg.signals.allocator)});
    try w.print("- NUMA fault placement: {s}\n", .{signalText(agg.signals.numa_fault)});
    try w.print("- priority/lock-owner chain: {s}\n\n", .{signalText(agg.signals.priority_inversion)});

    try w.writeAll("| Rule | Status | Why |\n|------|--------|-----|\n");
    for (report_list) |report| {
        try w.print("| {s} | {s} | {s} |\n", .{
            report.id,
            statusText(report.status),
            report.reason,
        });
    }
    try w.writeAll("\n");

    if (findings.len == 0) {
        var clear: usize = 0;
        var skipped: usize = 0;
        for (report_list) |report| switch (report.status) {
            .clear => clear += 1,
            .skip => skipped += 1,
            .finding => {},
        };
        try w.print(
            "No rule fired. {d} rule{s} evaluated clear; {d} rule{s} skipped for missing signals.\n",
            .{ clear, if (clear == 1) "" else "s", skipped, if (skipped == 1) "" else "s" },
        );
        return;
    }

    try w.writeAll("## Findings\n\n");
    for (findings) |finding| {
        try w.print("### {s} ({s}, {s})\n\n{s}\n\nEvidence:\n", .{
            finding.id,
            advisor.severityName(finding.severity),
            advisor.confidenceName(finding.confidence),
            finding.summary,
        });
        for (finding.evidence) |line| try w.print("- `{s}`\n", .{line});
        if (finding.recommendations.len != 0) {
            try w.writeAll("\nRecommendations (suggestions only — never auto-applied):\n");
            for (finding.recommendations) |rec| {
                try w.print("- **{s}**: `{s}` — {s}\n", .{ rec.kind, rec.detail, rec.rationale });
            }
        }
        try w.writeAll("\n");
    }
}

fn allSignals() aggregates.Signals {
    return .{
        .sched_switch = true,
        .sched_wakeup = true,
        .sched_migrate = true,
        .numa_fault = true,
        .cpu_topology = true,
        .pmu_hitm = true,
        .lock_contention = true,
        .allocator = true,
        .priority_inversion = true,
    };
}

fn stressed() Aggregates {
    return .{
        .remote_fault_ratio = 0.5,
        .dominant_node = 1,
        .task_cpu_node = 0,
        .migrations = 200,
        .cross_llc_migration = true,
        .llc_domains = 2,
        .wakeups = 100,
        .unnecessary_wakeups = 50,
        .lock_contentions = 3,
        .avg_lock_wait_ms = 2,
        .remote_hitm = 0.2,
        .buddy_fragmentation = 0.8,
        .priority_inversion_observed = true,
        .pmu_collected = true,
        .sched_collected = true,
        .signals = allSignals(),
    };
}

test "report carries statuses, host_mutation=false, and no apply path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: [16 * 1024]u8 = undefined;
    var w = Writer.fixed(&buf);
    try writeReportJson(&w, arena.allocator(), stressed(), .{});
    const text = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "\"host_mutation\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"schema\":\"xsprof/advisor-report/v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "sched_setaffinity") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"rules\":[") != null);
    for (rules.ids) |id| {
        try std.testing.expect(std.mem.indexOf(u8, text, id) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, text, "\"status\":\"finding\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"id\":\"priority-inversion\",\"reason\":\"threshold breached by the collected signal\",\"status\":\"finding\"") != null);
}

test "empty report marks every rule SKIP" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: [16 * 1024]u8 = undefined;
    var w = Writer.fixed(&buf);
    try writeReportJson(&w, arena.allocator(), .{}, .{});
    const text = w.buffered();
    for (rules.ids) |id| {
        const start = std.mem.indexOf(u8, text, id).?;
        const tail = text[start..];
        try std.testing.expect(std.mem.indexOf(u8, tail, "\"status\":\"skip\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, tail, "\"status\":\"clear\"") == null);
    }
}

test "markdown states clear and skipped counts without ambiguity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: [16 * 1024]u8 = undefined;
    var w = Writer.fixed(&buf);
    try writeReportMarkdown(&w, arena.allocator(), .{}, .{});
    const text = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "xsprof Performance Advisor Report") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "| priority-inversion | SKIP |") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "No rule fired.") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "0 rules evaluated clear; 7 rules skipped") != null);
}
