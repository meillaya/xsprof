const std = @import("std");
const list_writer = @import("list_writer");
const bench = @import("bench_root");

pub const schema_name = "zig-scheduler/performance-gate";
pub const schema_version: u32 = 1;

pub const MetricKind = enum {
    case_count,
    total_export_bytes,
    total_analysis_markdown_bytes,
    total_analysis_svg_bytes,
    total_trace_events,
    max_export_bytes,
    max_trace_events,

    pub fn label(self: MetricKind) []const u8 {
        return switch (self) {
            .case_count => "case_count",
            .total_export_bytes => "total_export_bytes",
            .total_analysis_markdown_bytes => "total_analysis_markdown_bytes",
            .total_analysis_svg_bytes => "total_analysis_svg_bytes",
            .total_trace_events => "total_trace_events",
            .max_export_bytes => "max_export_bytes",
            .max_trace_events => "max_trace_events",
        };
    }
};

pub const Budget = struct {
    metric: MetricKind,
    ceiling: u32,
    reason: []const u8,
};

pub const budgets = [_]Budget{
    .{ .metric = .case_count, .ceiling = 6, .reason = "baseline matrix remains explicit and reviewable" },
    .{ .metric = .total_export_bytes, .ceiling = 30_000, .reason = "report export size budget" },
    .{ .metric = .total_analysis_markdown_bytes, .ceiling = 14_000, .reason = "markdown analysis budget" },
    .{ .metric = .total_analysis_svg_bytes, .ceiling = 18_000, .reason = "SVG analysis budget" },
    .{ .metric = .total_trace_events, .ceiling = 200, .reason = "trace volume scaling budget" },
    .{ .metric = .max_export_bytes, .ceiling = 6_500, .reason = "per-report export ceiling" },
    .{ .metric = .max_trace_events, .ceiling = 50, .reason = "per-case trace ceiling" },
};

pub const MetricResult = struct {
    metric: MetricKind,
    actual: u32,
    ceiling: u32,
    ok: bool,
    reason: []const u8,
};

pub const Evaluation = struct {
    schema: []const u8 = schema_name,
    version: u32 = schema_version,
    baseline_schema: []const u8 = bench.schema_name,
    baseline_version: u32 = bench.schema_version,
    all_ok: bool,
    metrics: [budgets.len]MetricResult,
};

fn actualFor(metric: MetricKind, report: *const bench.Report) u32 {
    return switch (metric) {
        .case_count => report.aggregate.case_count,
        .total_export_bytes => report.aggregate.total_export_bytes,
        .total_analysis_markdown_bytes => report.aggregate.total_analysis_markdown_bytes,
        .total_analysis_svg_bytes => report.aggregate.total_analysis_svg_bytes,
        .total_trace_events => report.aggregate.total_trace_events,
        .max_export_bytes => report.aggregate.max_export_bytes,
        .max_trace_events => report.aggregate.max_trace_events,
    };
}

pub fn evaluate(allocator: std.mem.Allocator) !Evaluation {
    var report = try bench.run(allocator);
    defer report.deinit(allocator);

    var metrics: [budgets.len]MetricResult = undefined;
    var all_ok = true;
    for (budgets, 0..) |budget, index| {
        const actual = actualFor(budget.metric, &report);
        const ok = actual <= budget.ceiling;
        all_ok = all_ok and ok;
        metrics[index] = .{
            .metric = budget.metric,
            .actual = actual,
            .ceiling = budget.ceiling,
            .ok = ok,
            .reason = budget.reason,
        };
    }

    return .{ .all_ok = all_ok, .metrics = metrics };
}

pub fn writeMarkdown(writer: anytype, evaluation: Evaluation) !void {
    try writer.writeAll("# zig-scheduler performance gate\n\n");
    try writer.print("- Contract: `{s}` v{d}\n", .{ evaluation.schema, evaluation.version });
    try writer.print("- Baseline: `{s}` v{d}\n", .{ evaluation.baseline_schema, evaluation.baseline_version });
    try writer.writeAll("- Scope: reproducible simulator-local budgets; not Linux or production-runtime performance evidence.\n");
    try writer.print("- Result: **{s}**\n\n", .{if (evaluation.all_ok) "PASS" else "FAIL"});
    try writer.writeAll("| metric | actual | ceiling | status | reason |\n");
    try writer.writeAll("| --- | ---: | ---: | --- | --- |\n");
    for (evaluation.metrics) |metric| {
        try writer.print("| `{s}` | {d} | {d} | {s} | {s} |\n", .{
            metric.metric.label(),
            metric.actual,
            metric.ceiling,
            if (metric.ok) "PASS" else "FAIL",
            metric.reason,
        });
    }
    try writer.writeAll("\nBudgets compare against the committed benchmark baseline matrix and may change only with reviewed baseline/budget evidence.\n");
}

pub fn renderMarkdown(allocator: std.mem.Allocator) ![]u8 {
    const evaluation = try evaluate(allocator);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var writer = list_writer.writer(&out, allocator);
    try writeMarkdown(&writer, evaluation);
    return try out.toOwnedSlice(allocator);
}

pub fn assertBudgets(allocator: std.mem.Allocator) !void {
    const evaluation = try evaluate(allocator);
    if (!evaluation.all_ok) return error.PerformanceBudgetExceeded;
}

test "performance gate performance budget gate passes against committed benchmark baseline" {
    const allocator = std.testing.allocator;
    const evaluation = try evaluate(allocator);
    try std.testing.expect(evaluation.all_ok);
    try std.testing.expectEqual(budgets.len, evaluation.metrics.len);
    for (evaluation.metrics) |metric| {
        try std.testing.expect(metric.actual <= metric.ceiling);
        try std.testing.expect(metric.reason.len != 0);
    }
}

test "performance gate markdown reports scope and reviewed budget rule" {
    const allocator = std.testing.allocator;
    const rendered = try renderMarkdown(allocator);
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "zig-scheduler performance gate") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "simulator-local budgets") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "not Linux or production-runtime") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "may change only with reviewed") != null);
}
