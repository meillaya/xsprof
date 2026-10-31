//! Baseline/candidate comparison over scheduler metrics. Tasks are matched by
//! comm across runs; missing data stays unknown instead of becoming zero.

const std = @import("std");
const metrics_mod = @import("metrics.zig");
const json = @import("../core/json.zig");

pub const TaskDelta = struct {
    comm: []const u8,
    base_p95_us: u64 = 0,
    candidate_p95_us: u64 = 0,
    base_switches: u64 = 0,
    candidate_switches: u64 = 0,
    delta_pct: f64 = 0,
    regression: bool = false,
};

pub const Totals = struct {
    switches: u64 = 0,
    wakeups: u64 = 0,
    migrations: u64 = 0,
    faults_minor: u64 = 0,
    faults_major: u64 = 0,
    lost: u64 = 0,
    cpu_busy_us: u64 = 0,
};

pub const Report = struct {
    base_source: []const u8,
    candidate_source: []const u8,
    base: Totals,
    candidate: Totals,
    tasks: []TaskDelta,
    regressions: usize,
    threshold_pct: f64,
};

const Group = struct {
    p95: u64 = 0,
    switches: u64 = 0,
};

fn totals(metrics: metrics_mod.Metrics) Totals {
    var result = Totals{
        .switches = metrics.switches,
        .wakeups = metrics.wakeups,
        .migrations = metrics.migrations,
        .faults_minor = metrics.faults_minor,
        .faults_major = metrics.faults_major,
        .lost = metrics.lost,
    };
    for (metrics.cpus) |cpu| result.cpu_busy_us += cpu.busy_us;
    return result;
}

fn groups(
    allocator: std.mem.Allocator,
    metrics: metrics_mod.Metrics,
) !std.StringHashMap(Group) {
    var result = std.StringHashMap(Group).init(allocator);
    errdefer result.deinit();
    for (metrics.tasks) |task| {
        if (task.comm.len == 0) continue;
        const entry = try result.getOrPut(task.comm);
        if (!entry.found_existing) entry.value_ptr.* = .{};
        entry.value_ptr.p95 = @max(entry.value_ptr.p95, task.wait_p95_us);
        entry.value_ptr.switches += task.switches;
    }
    return result;
}

fn deltaPct(base: u64, candidate: u64) f64 {
    if (base == 0) return if (candidate == 0) 0 else 100.0;
    return (@as(f64, @floatFromInt(candidate)) - @as(f64, @floatFromInt(base))) /
        @as(f64, @floatFromInt(base)) * 100.0;
}

pub fn build(
    allocator: std.mem.Allocator,
    base_source: []const u8,
    base_metrics: metrics_mod.Metrics,
    candidate_source: []const u8,
    candidate_metrics: metrics_mod.Metrics,
    threshold_pct: f64,
) !Report {
    var base_groups = try groups(allocator, base_metrics);
    defer base_groups.deinit();
    var candidate_groups = try groups(allocator, candidate_metrics);
    defer candidate_groups.deinit();

    var tasks: std.ArrayList(TaskDelta) = .empty;
    errdefer tasks.deinit(allocator);
    var iterator = candidate_groups.iterator();
    while (iterator.next()) |entry| {
        const base = base_groups.get(entry.key_ptr.*) orelse Group{};
        const candidate = entry.value_ptr.*;
        const delta = deltaPct(base.p95, candidate.p95);
        try tasks.append(allocator, .{
            .comm = entry.key_ptr.*,
            .base_p95_us = base.p95,
            .candidate_p95_us = candidate.p95,
            .base_switches = base.switches,
            .candidate_switches = candidate.switches,
            .delta_pct = delta,
            .regression = delta > threshold_pct,
        });
    }
    std.mem.sortUnstable(TaskDelta, tasks.items, {}, struct {
        fn less(_: void, a: TaskDelta, b: TaskDelta) bool {
            if (a.candidate_p95_us != b.candidate_p95_us) return a.candidate_p95_us > b.candidate_p95_us;
            return std.mem.order(u8, a.comm, b.comm) == .lt;
        }
    }.less);

    var regressions: usize = 0;
    for (tasks.items) |task| {
        if (task.regression) regressions += 1;
    }
    return .{
        .base_source = base_source,
        .candidate_source = candidate_source,
        .base = totals(base_metrics),
        .candidate = totals(candidate_metrics),
        .tasks = try tasks.toOwnedSlice(allocator),
        .regressions = regressions,
        .threshold_pct = threshold_pct,
    };
}

pub fn writeJson(w: *std.Io.Writer, report: Report) !void {
    const allocator = std.heap.smp_allocator;
    var task_values = try allocator.alloc(json.Value, report.tasks.len);
    defer allocator.free(task_values);
    var entries = try allocator.alloc([]json.Entry, report.tasks.len);
    defer {
        for (entries) |item| allocator.free(item);
        allocator.free(entries);
    }
    for (report.tasks, 0..) |task, index| {
        const item = try allocator.alloc(json.Entry, 7);
        item[0] = .{ .key = "base_p95_us", .value = .{ .unsigned = task.base_p95_us } };
        item[1] = .{ .key = "base_switches", .value = .{ .unsigned = task.base_switches } };
        item[2] = .{ .key = "candidate_p95_us", .value = .{ .unsigned = task.candidate_p95_us } };
        item[3] = .{ .key = "candidate_switches", .value = .{ .unsigned = task.candidate_switches } };
        item[4] = .{ .key = "comm", .value = .{ .string = task.comm } };
        item[5] = .{ .key = "delta_pct", .value = .{ .float = task.delta_pct } };
        item[6] = .{ .key = "regression", .value = .{ .boolean = task.regression } };
        entries[index] = item;
        task_values[index] = .{ .object = item };
    }
    try json.write(w, .{ .object = &.{
        .{ .key = "base", .value = .{ .object = &.{
            .{ .key = "cpu_busy_us", .value = .{ .unsigned = report.base.cpu_busy_us } },
            .{ .key = "faults_major", .value = .{ .unsigned = report.base.faults_major } },
            .{ .key = "faults_minor", .value = .{ .unsigned = report.base.faults_minor } },
            .{ .key = "lost", .value = .{ .unsigned = report.base.lost } },
            .{ .key = "migrations", .value = .{ .unsigned = report.base.migrations } },
            .{ .key = "switches", .value = .{ .unsigned = report.base.switches } },
            .{ .key = "wakeups", .value = .{ .unsigned = report.base.wakeups } },
        } } },
        .{ .key = "base_source", .value = .{ .string = report.base_source } },
        .{ .key = "candidate", .value = .{ .object = &.{
            .{ .key = "cpu_busy_us", .value = .{ .unsigned = report.candidate.cpu_busy_us } },
            .{ .key = "faults_major", .value = .{ .unsigned = report.candidate.faults_major } },
            .{ .key = "faults_minor", .value = .{ .unsigned = report.candidate.faults_minor } },
            .{ .key = "lost", .value = .{ .unsigned = report.candidate.lost } },
            .{ .key = "migrations", .value = .{ .unsigned = report.candidate.migrations } },
            .{ .key = "switches", .value = .{ .unsigned = report.candidate.switches } },
            .{ .key = "wakeups", .value = .{ .unsigned = report.candidate.wakeups } },
        } } },
        .{ .key = "candidate_source", .value = .{ .string = report.candidate_source } },
        .{ .key = "host_mutation", .value = .{ .boolean = false } },
        .{ .key = "regressions", .value = .{ .unsigned = report.regressions } },
        .{ .key = "schema", .value = .{ .string = "xsprof/compare/v1" } },
        .{ .key = "tasks", .value = .{ .array = task_values } },
        .{ .key = "threshold_pct", .value = .{ .float = report.threshold_pct } },
    } });
}

fn escape(w: *std.Io.Writer, text: []const u8) !void {
    for (text) |byte| {
        switch (byte) {
            '&' => try w.writeAll("&amp;"),
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            '"' => try w.writeAll("&quot;"),
            '\'' => try w.writeAll("&#39;"),
            else => try w.writeByte(byte),
        }
    }
}

pub fn writeMarkdown(w: *std.Io.Writer, report: Report) !void {
    try w.print("# xsprof comparison\n\nBase: `{s}`  \nCandidate: `{s}`\n\n", .{
        report.base_source,
        report.candidate_source,
    });
    try w.print("Regressions: **{d}** at threshold {d:.1}%\n\n", .{
        report.regressions,
        report.threshold_pct,
    });
    try w.writeAll("| comm | base p95 | candidate p95 | delta |\n|---|---:|---:|---:|\n");
    for (report.tasks) |task| {
        try w.print("| {s} | {d} ms | {d} ms | {d:.1}% |\n", .{
            task.comm,
            task.base_p95_us / 1000,
            task.candidate_p95_us / 1000,
            task.delta_pct,
        });
    }
}

pub fn writeHtml(w: *std.Io.Writer, report: Report) !void {
    try w.writeAll("<!doctype html><html><head><meta charset=\"utf-8\"><title>xsprof comparison</title>" ++
        "<style>body{font-family:monospace;background:#0b0b0a;color:#f5efe4;padding:24px}" ++
        "table{border-collapse:collapse;width:100%}td,th{border-bottom:1px solid #3a332b;padding:6px;text-align:left}" ++
        ".bad{color:#ff6b9a}</style></head><body><h1>xsprof comparison</h1>");
    try w.writeAll("<p>Base: <code>");
    try escape(w, report.base_source);
    try w.writeAll("</code><br>Candidate: <code>");
    try escape(w, report.candidate_source);
    try w.writeAll("</code></p>");
    try w.print("<p>Regressions: <strong>{d}</strong> at threshold {d:.1}%</p>", .{
        report.regressions,
        report.threshold_pct,
    });
    try w.writeAll("<table><thead><tr><th>comm</th><th>base p95</th><th>candidate p95</th><th>delta</th></tr></thead><tbody>");
    for (report.tasks) |task| {
        try w.writeAll("<tr><td>");
        try escape(w, task.comm);
        try w.print("</td><td>{d} ms</td><td>{d} ms</td><td class=\"{s}\">{d:.1}%</td></tr>", .{
            task.base_p95_us / 1000,
            task.candidate_p95_us / 1000,
            if (task.regression) "bad" else "",
            task.delta_pct,
        });
    }
    try w.writeAll("</tbody></table></body></html>\n");
}

// Checks comm grouping and regression detection with different PIDs.
test "compare groups by comm and flags regressions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const base_tasks = [_]metrics_mod.TaskMetric{
        .{ .pid = 1, .comm = "worker", .wait_p95_us = 1000, .switches = 10 },
    };
    const candidate_tasks = [_]metrics_mod.TaskMetric{
        .{ .pid = 2, .comm = "worker", .wait_p95_us = 2000, .switches = 12 },
    };
    const report = try build(
        arena.allocator(),
        "base",
        .{ .tasks = &base_tasks },
        "candidate",
        .{ .tasks = &candidate_tasks },
        10,
    );
    try std.testing.expectEqual(@as(usize, 1), report.tasks.len);
    try std.testing.expect(report.tasks[0].regression);
    try std.testing.expectEqual(@as(usize, 1), report.regressions);
}
