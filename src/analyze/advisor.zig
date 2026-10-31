//! Performance Advisor: a pure function over aggregates. Recommendations are
//! suggestions only; there is no syscall or auto-apply path here.

const std = @import("std");
const json = @import("../core/json.zig");
const aggregates = @import("aggregates.zig");

const Writer = std.Io.Writer;
const Aggregates = aggregates.Aggregates;

pub const Severity = enum { info, warning, critical };
pub const Confidence = enum { measured, heuristic };

pub const Recommendation = struct {
    kind: []const u8,
    detail: []const u8,
    rationale: []const u8,
};

pub const Finding = struct {
    id: []const u8,
    severity: Severity,
    confidence: Confidence,
    summary: []const u8,
    evidence: []const []const u8,
    recommendations: []const Recommendation,
};

pub const Thresholds = struct {
    false_sharing_hitm_min: f64 = 0.05,
    excessive_lock_wait_ms: f64 = 1.0,
    excessive_lock_contentions_min: i64 = 1,
    unnecessary_wakeup_ratio: f64 = 0.30,
    affinity_churn_migrations_min: i64 = 100,
    numa_remote_fault_ratio: f64 = 0.20,
    allocator_fragmentation_min: f64 = 0.50,
    priority_inversion_enabled: bool = true,
};

pub fn severityName(severity: Severity) []const u8 {
    return @tagName(severity);
}

pub fn confidenceName(confidence: Confidence) []const u8 {
    return @tagName(confidence);
}

fn severityRank(severity: Severity) u8 {
    return switch (severity) {
        .critical => 2,
        .warning => 1,
        .info => 0,
    };
}

fn shouldComeBefore(a: Finding, b: Finding) bool {
    const ar = severityRank(a.severity);
    const br = severityRank(b.severity);
    if (ar != br) return ar > br;
    return a.evidence.len > b.evidence.len;
}

fn stableSort(findings: []Finding) void {
    var i: usize = 1;
    while (i < findings.len) : (i += 1) {
        const key = findings[i];
        var j = i;
        while (j > 0 and shouldComeBefore(key, findings[j - 1])) : (j -= 1) {
            findings[j] = findings[j - 1];
        }
        findings[j] = key;
    }
}

fn oneEvidence(
    allocator: std.mem.Allocator,
    comptime fmt: []const u8,
    args: anytype,
) ![]const []const u8 {
    const evidence = try allocator.alloc([]const u8, 1);
    errdefer allocator.free(evidence);
    evidence[0] = try std.fmt.allocPrint(allocator, fmt, args);
    return evidence;
}

fn oneRecommendation(
    allocator: std.mem.Allocator,
    kind: []const u8,
    comptime detail_fmt: []const u8,
    detail_args: anytype,
    comptime rationale_fmt: []const u8,
    rationale_args: anytype,
) ![]const Recommendation {
    const recs = try allocator.alloc(Recommendation, 1);
    errdefer allocator.free(recs);
    recs[0] = .{
        .kind = kind,
        .detail = try std.fmt.allocPrint(allocator, detail_fmt, detail_args),
        .rationale = try std.fmt.allocPrint(allocator, rationale_fmt, rationale_args),
    };
    return recs;
}

pub fn analyze(
    allocator: std.mem.Allocator,
    agg: Aggregates,
    thresholds: Thresholds,
) ![]Finding {
    var out: std.ArrayList(Finding) = .empty;
    errdefer {
        for (out.items) |finding| {
            for (finding.evidence) |line| allocator.free(line);
            allocator.free(finding.evidence);
            for (finding.recommendations) |rec| {
                allocator.free(rec.detail);
                allocator.free(rec.rationale);
            }
            allocator.free(finding.recommendations);
        }
        out.deinit(allocator);
    }

    // Rule 5: poor NUMA placement.
    if (agg.remote_fault_ratio > thresholds.numa_remote_fault_ratio and
        agg.dominant_node >= 0 and agg.task_cpu_node >= 0 and
        agg.dominant_node != agg.task_cpu_node)
    {
        try out.append(allocator, .{
            .id = "poor-numa-placement",
            .severity = .warning,
            .confidence = .measured,
            .summary = "Task memory is dominated by a NUMA node different from where it runs.",
            .evidence = try oneEvidence(
                allocator,
                "remote_fault_ratio={d} dominant_mem_node={d} task_cpu_node={d}",
                .{ agg.remote_fault_ratio, agg.dominant_node, agg.task_cpu_node },
            ),
            .recommendations = try oneRecommendation(
                allocator,
                "numa_bind",
                "numactl --membind={d} --cpunodebind={d} ./app",
                .{ agg.dominant_node, agg.dominant_node },
                "Bind memory and CPU to node {d} to raise the local-fault ratio toward >0.9.",
                .{agg.dominant_node},
            ),
        });
    }

    // Rule 4: CPU affinity churn.
    if (agg.sched_collected and agg.cross_llc_migration and
        agg.migrations > thresholds.affinity_churn_migrations_min)
    {
        try out.append(allocator, .{
            .id = "cpu-affinity-churn",
            .severity = .warning,
            .confidence = .measured,
            .summary = "Frequent cross-LLC migrations are cooling caches for a migratory task group.",
            .evidence = try oneEvidence(
                allocator,
                "migrations={d} llc_domains={d}",
                .{ agg.migrations, agg.llc_domains },
            ),
            .recommendations = try oneRecommendation(
                allocator,
                "sched_setaffinity",
                "sched_setaffinity(<pid>, mask_of_one_llc_domain);  // e.g. cpus 0-7 for domain 0",
                .{},
                "Pin the task group to a single LLC domain to stop cross-LLC migration.",
                .{},
            ),
        });
    }

    // Rule 3: unnecessary wakeups.
    if (agg.sched_collected and agg.wakeups > 0 and
        @as(f64, @floatFromInt(agg.unnecessary_wakeups)) /
            @as(f64, @floatFromInt(agg.wakeups)) > thresholds.unnecessary_wakeup_ratio)
    {
        try out.append(allocator, .{
            .id = "unnecessary-wakeups",
            .severity = .info,
            .confidence = .measured,
            .summary = "A large share of wakeups are not followed by a run within the window.",
            .evidence = try oneEvidence(
                allocator,
                "unnecessary_wakeups={d}/{d}",
                .{ agg.unnecessary_wakeups, agg.wakeups },
            ),
            .recommendations = try oneRecommendation(
                allocator,
                "tuning",
                "Batch/coalesce wakeups or use polling for the affected producer/consumer pair.",
                .{},
                "Reduce wakeup-to-idle churn that wastes CPU and perturbs the scheduler.",
                .{},
            ),
        });
    }

    // Rule 2: excessive locking.
    if (agg.lock_contentions >= thresholds.excessive_lock_contentions_min and
        agg.avg_lock_wait_ms > thresholds.excessive_lock_wait_ms)
    {
        try out.append(allocator, .{
            .id = "excessive-locking",
            .severity = .warning,
            .confidence = .measured,
            .summary = "Lock contention wait time is high relative to useful work.",
            .evidence = try oneEvidence(
                allocator,
                "lock_contentions={d} avg_wait_ms={d}",
                .{ agg.lock_contentions, agg.avg_lock_wait_ms },
            ),
            .recommendations = try oneRecommendation(
                allocator,
                "tuning",
                "Shard the contended lock, reduce critical-section length, or go lock-free.",
                .{},
                "Cut average lock wait below ~1ms to remove the serialization bottleneck.",
                .{},
            ),
        });
    }

    // Rule 1: false sharing, with a measured path and a heuristic fallback.
    if (agg.pmu_collected and agg.remote_hitm > thresholds.false_sharing_hitm_min) {
        try out.append(allocator, .{
            .id = "false-sharing",
            .severity = .critical,
            .confidence = .measured,
            .summary = "Cross-core cache-line ping-pong (remote HITM) indicates false sharing.",
            .evidence = try oneEvidence(allocator, "remote_hitm_rate={d}", .{agg.remote_hitm}),
            .recommendations = try oneRecommendation(
                allocator,
                "tuning",
                "Pad hot fields to a 64B cache line (alignas(64)) or split per-thread.",
                .{},
                "Eliminate shared writable cache lines between cores.",
                .{},
            ),
        });
    } else if (!agg.pmu_collected and agg.llc_misses > 0) {
        try out.append(allocator, .{
            .id = "false-sharing",
            .severity = .info,
            .confidence = .heuristic,
            .summary = "Elevated LLC misses may indicate false sharing (PMU HITM unavailable).",
            .evidence = try oneEvidence(
                allocator,
                "llc_misses={d} (heuristic; CAP_PERFMON needed for confirmation)",
                .{agg.llc_misses},
            ),
            .recommendations = &.{},
        });
    }

    // Rule 6: allocator fragmentation.
    if (agg.buddy_fragmentation > thresholds.allocator_fragmentation_min) {
        try out.append(allocator, .{
            .id = "allocator-fragmentation",
            .severity = .info,
            .confidence = .measured,
            .summary = "High-order buddy lists are depleted relative to low-order (fragmentation).",
            .evidence = try oneEvidence(
                allocator,
                "buddy_fragmentation_index={d}",
                .{agg.buddy_fragmentation},
            ),
            .recommendations = try oneRecommendation(
                allocator,
                "tuning",
                "Use huge pages / a slab-friendly allocator; reduce small-allocation churn.",
                .{},
                "Lower fragmentation to keep high-order allocations cheap.",
                .{},
            ),
        });
    }

    // Rule 7: priority inversion.
    if (thresholds.priority_inversion_enabled and agg.priority_inversion_observed) {
        try out.append(allocator, .{
            .id = "priority-inversion",
            .severity = .critical,
            .confidence = .measured,
            .summary = "A high-priority task was blocked on a lock held by a preempted low-priority task.",
            .evidence = try oneEvidence(
                allocator,
                "priority_inversion observed via lock-owner + sched_switch chain",
                .{},
            ),
            .recommendations = try oneRecommendation(
                allocator,
                "tuning",
                "Use priority-inheritance mutexes (PTHREAD_PRIO_INHERIT) or shorten the hold.",
                .{},
                "Prevent unbounded priority inversion on the critical lock.",
                .{},
            ),
        });
    }

    stableSort(out.items);
    return out.toOwnedSlice(allocator);
}

pub fn freeFindings(allocator: std.mem.Allocator, findings: []Finding) void {
    for (findings) |finding| {
        for (finding.evidence) |line| allocator.free(line);
        allocator.free(finding.evidence);
        for (finding.recommendations) |rec| {
            allocator.free(rec.detail);
            allocator.free(rec.rationale);
        }
        if (finding.recommendations.len != 0) allocator.free(finding.recommendations);
    }
    allocator.free(findings);
}

fn writeRecommendation(w: *Writer, rec: Recommendation) Writer.Error!void {
    try json.write(w, .{ .object = &.{
        .{ .key = "detail", .value = .{ .string = rec.detail } },
        .{ .key = "kind", .value = .{ .string = rec.kind } },
        .{ .key = "rationale", .value = .{ .string = rec.rationale } },
    } });
}

fn writeFinding(w: *Writer, finding: Finding) Writer.Error!void {
    try w.writeByte('{');
    try w.writeAll("\"confidence\":");
    try json.write(w, .{ .string = confidenceName(finding.confidence) });
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
    try json.write(w, .{ .string = severityName(finding.severity) });
    try w.writeAll(",\"summary\":");
    try json.write(w, .{ .string = finding.summary });
    try w.writeByte('}');
}

pub fn writeReportJson(
    w: *Writer,
    allocator: std.mem.Allocator,
    agg: Aggregates,
    thresholds: Thresholds,
) !void {
    const findings = try analyze(allocator, agg, thresholds);
    defer freeFindings(allocator, findings);
    try w.writeAll("{\"capabilities\":{\"pmu_collected\":");
    try json.write(w, .{ .boolean = agg.pmu_collected });
    try w.writeAll(",\"sched_collected\":");
    try json.write(w, .{ .boolean = agg.sched_collected });
    try w.writeAll("},\"findings\":[");
    for (findings, 0..) |finding, i| {
        if (i != 0) try w.writeByte(',');
        try writeFinding(w, finding);
    }
    try w.writeAll("],\"host_mutation\":false,\"schema\":\"xsprof/advisor-report/v1\"}\n");
}

pub fn writeReportMarkdown(
    w: *Writer,
    allocator: std.mem.Allocator,
    agg: Aggregates,
    thresholds: Thresholds,
) !void {
    const findings = try analyze(allocator, agg, thresholds);
    defer freeFindings(allocator, findings);
    try w.writeAll("# xsprof Performance Advisor Report\n\n");
    try w.print("- PMU collected: {s}\n", .{if (agg.pmu_collected) "yes" else "no"});
    try w.print("- Scheduler collected: {s}\n\n", .{if (agg.sched_collected) "yes" else "no"});
    if (findings.len == 0) {
        try w.writeAll(
            "No findings. Either the workload is healthy or the signals needed for " ++
                "detection were not collected (see capabilities above; the framework " ++
                "fails closed).\n",
        );
        return;
    }
    try w.writeAll("| # | Severity | Finding | Confidence |\n|---|----------|---------|------------|\n");
    for (findings, 0..) |finding, i| {
        try w.print("| {d} | {s} | {s} | {s} |\n", .{
            i + 1,
            severityName(finding.severity),
            finding.id,
            confidenceName(finding.confidence),
        });
    }
    try w.writeAll("\n## Detail\n\n");
    for (findings) |finding| {
        try w.print("### {s} ({s}, {s})\n\n{s}\n\nEvidence:\n", .{
            finding.id,
            severityName(finding.severity),
            confidenceName(finding.confidence),
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
        .llc_misses = 1000,
        .remote_hitm = 0.2,
        .buddy_fragmentation = 0.8,
        .priority_inversion_observed = true,
        .pmu_collected = true,
        .sched_collected = true,
    };
}

test "all seven rules fire on a stressed snapshot" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const findings = try analyze(arena.allocator(), stressed(), .{});
    try std.testing.expectEqual(@as(usize, 7), findings.len);
    try std.testing.expectEqual(Severity.critical, findings[0].severity);
    try std.testing.expectEqualStrings("false-sharing", findings[0].id);
}

test "healthy and uncollected snapshots stay silent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const findings = try analyze(arena.allocator(), .{}, .{});
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "thresholds are strict greater-than boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const boundary: Aggregates = .{
        .remote_fault_ratio = 0.20,
        .dominant_node = 1,
        .task_cpu_node = 0,
        .migrations = 100,
        .cross_llc_migration = true,
        .sched_collected = true,
        .wakeups = 100,
        .unnecessary_wakeups = 30,
        .lock_contentions = 1,
        .avg_lock_wait_ms = 1.0,
        .pmu_collected = true,
        .remote_hitm = 0.05,
        .buddy_fragmentation = 0.50,
    };
    const findings = try analyze(arena.allocator(), boundary, .{});
    try std.testing.expectEqual(@as(usize, 0), findings.len);
}

test "advisor report carries host_mutation=false and no apply path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: [8192]u8 = undefined;
    var w = Writer.fixed(&buf);
    try writeReportJson(&w, arena.allocator(), stressed(), .{});
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\"host_mutation\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "sched_setaffinity") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\"schema\":\"xsprof/advisor-report/v1\"") != null);
}
