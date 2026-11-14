//! Baseline/candidate comparison over scheduler metrics, matched by comm.
//!
//! A gate may take 1..8 captures per side. Each capture is reduced to the same
//! bounded log-bucket histograms the metrics index keeps, the per-comm buckets
//! are pooled across runs, and a regression must beat both the requested
//! threshold and an empirical noise floor (the largest run-to-run p95 spread of
//! either side, normalized by the pooled baseline p95).
//!
//! Missing data is unknown (`null`), never zero. The one-capture-per-side path
//! reproduces the legacy output (including its 0-when-absent convention) and
//! reports noise 0: one sample has no observed spread.

const std = @import("std");
const metrics_mod = @import("metrics.zig");
const json = @import("../core/json.zig");
const session_meta = @import("../core/session_meta.zig");

pub const max_runs_per_side = 8;
pub const default_threshold_pct = 10.0;
pub const max_fail_reasons = 64;

// --- Gate rules (`--fail-on`) ---

pub const LatencyMetric = enum { wait_p50, wait_p95, wait_p99, wait_max, offcpu_p95 };

pub fn latencyName(metric: LatencyMetric) []const u8 {
    return switch (metric) {
        .wait_p50 => "wait.p50",
        .wait_p95 => "wait.p95",
        .wait_p99 => "wait.p99",
        .wait_max => "wait.max",
        .offcpu_p95 => "offcpu.p95",
    };
}

pub const CounterMetric = enum { preemptions, migrations, loss };

pub fn counterName(metric: CounterMetric) []const u8 {
    return switch (metric) {
        .preemptions => "preemptions",
        .migrations => "migrations",
        .loss => "loss",
    };
}

pub const Rule = union(enum) {
    /// Latency families are percentages; the gate fails when the candidate
    /// grows more than this percentage over the baseline and over the noise.
    latency: struct { metric: LatencyMetric, threshold_pct: f64 },
    /// Counters are absolute; the gate fails when the candidate mean per run
    /// exceeds the baseline mean per run by more than this amount.
    counter: struct { metric: CounterMetric, threshold: u64 },
};

/// Parse one `--fail-on` value: `wait.p50|p95|p99|max=<pct>`,
/// `offcpu.p95=<pct>`, or `preemptions|migrations|loss=<absolute>`.
/// Latency values accept an optional trailing `%` (the legacy spelling).
pub fn parseRule(text: []const u8) error{InvalidRule}!Rule {
    const equals = std.mem.indexOfScalar(u8, text, '=') orelse return error.InvalidRule;
    const name = std.mem.trim(u8, text[0..equals], " ");
    const raw_value = std.mem.trim(u8, text[equals + 1 ..], " ");
    if (name.len == 0 or raw_value.len == 0) return error.InvalidRule;
    const latency_names = [_][]const u8{ "wait.p50", "wait.p95", "wait.p99", "wait.max", "offcpu.p95" };
    const latency_metrics = [_]LatencyMetric{ .wait_p50, .wait_p95, .wait_p99, .wait_max, .offcpu_p95 };
    inline for (latency_names, latency_metrics) |candidate, metric| {
        if (std.mem.eql(u8, name, candidate)) {
            return .{ .latency = .{ .metric = metric, .threshold_pct = try parsePercent(raw_value) } };
        }
    }
    const counter_names = [_][]const u8{ "preemptions", "migrations", "loss" };
    const counter_metrics = [_]CounterMetric{ .preemptions, .migrations, .loss };
    inline for (counter_names, counter_metrics) |candidate, metric| {
        if (std.mem.eql(u8, name, candidate)) {
            if (std.mem.endsWith(u8, raw_value, "%")) return error.InvalidRule;
            const parsed = std.fmt.parseInt(u64, raw_value, 10) catch return error.InvalidRule;
            return .{ .counter = .{ .metric = metric, .threshold = parsed } };
        }
    }
    return error.InvalidRule;
}

fn parsePercent(value: []const u8) error{InvalidRule}!f64 {
    var text = value;
    if (std.mem.endsWith(u8, text, "%")) text = text[0 .. text.len - 1];
    if (text.len == 0) return error.InvalidRule;
    const parsed = std.fmt.parseFloat(f64, text) catch return error.InvalidRule;
    if (!std.math.isFinite(parsed) or parsed < 0) return error.InvalidRule;
    return parsed;
}

// --- Run inputs ---

/// One capture's contribution to the comparison: its scalar totals plus the
/// bounded per-comm histograms extracted from the metrics index.
pub const RunInput = struct {
    source: []const u8,
    metrics: metrics_mod.Metrics = .{},
    comms: []const CommRun = &.{},
};

/// Per-comm bounded histogram of one capture, pooled across the tasks that
/// shared the comm name in that capture (matching how `compare` has always
/// grouped by comm because PIDs churn between runs).
pub const CommRun = struct {
    comm: []const u8,
    wait: metrics_mod.Histogram = .{},
    offcpu: metrics_mod.Histogram = .{},
    /// Legacy per-comm p95: the worst task p95 for this comm, which is exactly
    /// what the single-capture output has always reported.
    max_wait_p95_us: u64 = 0,
    max_offcpu_p95_us: u64 = 0,
    switches: u64 = 0,
};

fn mergeHistogram(dest: *metrics_mod.Histogram, source: metrics_mod.Histogram) void {
    for (&dest.buckets, source.buckets) |*target, value| target.* +|= value;
    dest.count +|= source.count;
    dest.total_us +|= source.total_us;
    dest.max_us = @max(dest.max_us, source.max_us);
}

/// How the metrics index decides a task is the profiler itself (mirrors its
/// private `isSelf`): the capture-owner pid when a marker supplied one, else
/// the archived profiler comm prefixes.
fn isProbeTask(index: *const metrics_mod.Index, pid: i32, comm: []const u8) bool {
    if (index.self_seen) return pid > 0 and pid == index.self_pid;
    return session_meta.isProfilerComm(comm);
}

/// Reduce a live metrics index to one bounded histogram per comm.
///
/// The index keeps the raw per-task histograms that `snapshot` compresses into
/// quantiles; a multi-run gate must pool the buckets themselves, because the
/// p95 of a union of runs is not the p95 of the per-run p95s. Reading the index
/// state here (rather than a per-task summary) avoids re-deriving the wakeup
/// pairing and keeps this module the only owner of the merge rule.
pub fn extractComms(
    allocator: std.mem.Allocator,
    index: *const metrics_mod.Index,
) ![]CommRun {
    var list: std.ArrayList(CommRun) = .empty;
    errdefer list.deinit(allocator);
    var positions = std.StringHashMap(usize).init(allocator);
    defer positions.deinit();
    var iterator = index.tasks.iterator();
    while (iterator.next()) |entry| {
        const task = entry.value_ptr.*;
        if (task.comm.len == 0) continue;
        if (isProbeTask(index, task.pid, task.comm)) continue;
        const slot = try positions.getOrPut(task.comm);
        if (!slot.found_existing) {
            try list.append(allocator, .{ .comm = try allocator.dupe(u8, task.comm) });
            slot.value_ptr.* = list.items.len - 1;
        }
        const run = &list.items[slot.value_ptr.*];
        mergeHistogram(&run.wait, task.wait);
        mergeHistogram(&run.offcpu, task.offcpu);
        run.max_wait_p95_us = @max(run.max_wait_p95_us, task.wait.quantileUpper(950));
        run.max_offcpu_p95_us = @max(run.max_offcpu_p95_us, task.offcpu.quantileUpper(950));
        run.switches +|= task.switches;
    }
    return list.toOwnedSlice(allocator);
}

// --- Merged report data ---

pub const Totals = struct {
    switches: u64 = 0,
    wakeups: u64 = 0,
    migrations: u64 = 0,
    faults_minor: u64 = 0,
    faults_major: u64 = 0,
    lost: u64 = 0,
    cpu_busy_us: u64 = 0,
    /// Summed preemptions when the causal-latency metrics are available.
    preemptions: ?u64 = null,
};

pub const TaskDelta = struct {
    comm: []const u8,
    base_p95_us: ?u64 = null,
    candidate_p95_us: ?u64 = null,
    base_switches: u64 = 0,
    candidate_switches: u64 = 0,
    /// Captures on each side in which this comm was observed.
    base_runs: usize = 0,
    candidate_runs: usize = 0,
    delta_pct: ?f64 = null,
    /// Empirical noise floor: largest inter-run p95 spread of either side over
    /// the pooled baseline p95, in percent. null when the baseline is unknown.
    noise_pct: ?f64 = null,
    regression: bool = false,
};

pub const Options = struct {
    /// Legacy scalar: the `wait.p95` threshold (10% unless overridden).
    threshold_pct: f64 = default_threshold_pct,
    rules: []const Rule = &.{},
};

pub const Report = struct {
    base_source: []const u8,
    candidate_source: []const u8,
    base_runs: usize,
    candidate_runs: usize,
    base: Totals,
    candidate: Totals,
    tasks: []TaskDelta,
    regressions: usize,
    threshold_pct: f64,
    fail_reasons: []const []const u8,
    /// Gate metrics that could not be evaluated because no capture had
    /// comparable samples. These are reported as "not a pass" by the CLI.
    unavailable_rules: []const []const u8,
};

const MergedComm = struct {
    comm: []const u8,
    wait: metrics_mod.Histogram = .{},
    offcpu: metrics_mod.Histogram = .{},
    switches: u64 = 0,
    runs_seen: usize = 0,
    runs_with_wait: usize = 0,
    runs_with_offcpu: usize = 0,
    max_task_p95_us: u64 = 0,
    max_task_offcpu_p95_us: u64 = 0,
    /// Per-run pooled latency values, kept for the noise floor.
    run_wait: [max_runs_per_side][4]u64 = @splat(@splat(0)),
    run_wait_count: usize = 0,
    run_offcpu: [max_runs_per_side]u64 = @splat(0),
    run_offcpu_count: usize = 0,
};

const Side = struct {
    list: std.ArrayList(MergedComm),
    positions: std.StringHashMap(usize),

    fn init(allocator: std.mem.Allocator) Side {
        return .{
            .list = .empty,
            .positions = std.StringHashMap(usize).init(allocator),
        };
    }

    fn deinit(self: *Side, allocator: std.mem.Allocator) void {
        self.list.deinit(allocator);
        self.positions.deinit();
    }

    fn lookup(self: *const Side, comm: []const u8) ?*const MergedComm {
        const index = self.positions.get(comm) orelse return null;
        return &self.list.items[index];
    }
};

fn mergeSide(allocator: std.mem.Allocator, inputs: []const RunInput) !Side {
    var side = Side.init(allocator);
    errdefer side.deinit(allocator);
    for (inputs) |input| {
        for (input.comms) |run| {
            const slot = try side.positions.getOrPut(run.comm);
            if (!slot.found_existing) {
                try side.list.append(allocator, .{ .comm = run.comm });
                slot.value_ptr.* = side.list.items.len - 1;
            }
            const merged = &side.list.items[slot.value_ptr.*];
            mergeHistogram(&merged.wait, run.wait);
            mergeHistogram(&merged.offcpu, run.offcpu);
            merged.switches +|= run.switches;
            merged.runs_seen += 1;
            merged.max_task_p95_us = @max(merged.max_task_p95_us, run.max_wait_p95_us);
            merged.max_task_offcpu_p95_us = @max(merged.max_task_offcpu_p95_us, run.max_offcpu_p95_us);
            if (run.wait.count != 0) {
                merged.runs_with_wait += 1;
                if (merged.run_wait_count < max_runs_per_side) {
                    merged.run_wait[merged.run_wait_count] = .{
                        run.wait.quantileUpper(500),
                        run.wait.quantileUpper(950),
                        run.wait.quantileUpper(990),
                        run.wait.max_us,
                    };
                    merged.run_wait_count += 1;
                }
            }
            if (run.offcpu.count != 0) {
                merged.runs_with_offcpu += 1;
                if (merged.run_offcpu_count < max_runs_per_side) {
                    merged.run_offcpu[merged.run_offcpu_count] = run.offcpu.quantileUpper(950);
                    merged.run_offcpu_count += 1;
                }
            }
        }
    }
    return side;
}

fn deltaPct(base: u64, candidate: u64) f64 {
    if (base == 0) return if (candidate == 0) 0 else 100.0;
    return (@as(f64, @floatFromInt(candidate)) - @as(f64, @floatFromInt(base))) /
        @as(f64, @floatFromInt(base)) * 100.0;
}

fn rangePct(values: []const u64, base: u64) f64 {
    if (values.len < 2 or base == 0) return 0;
    var low = values[0];
    var high = values[0];
    for (values[1..]) |value| {
        low = @min(low, value);
        high = @max(high, value);
    }
    return @as(f64, @floatFromInt(high - low)) / @as(f64, @floatFromInt(base)) * 100.0;
}

/// Percentage spread of one metric across a side's runs, relative to `base`.
fn runSpreadPct(agg: ?*const MergedComm, metric: LatencyMetric, base: u64) f64 {
    const side = agg orelse return 0;
    return switch (metric) {
        .offcpu_p95 => rangePct(side.run_offcpu[0..side.run_offcpu_count], base),
        .wait_p50 => columnSpreadPct(side, 0, base),
        .wait_p95 => columnSpreadPct(side, 1, base),
        .wait_p99 => columnSpreadPct(side, 2, base),
        .wait_max => columnSpreadPct(side, 3, base),
    };
}

fn columnSpreadPct(agg: *const MergedComm, column: usize, base: u64) f64 {
    if (agg.run_wait_count < 2 or base == 0) return 0;
    var low = agg.run_wait[0][column];
    var high = low;
    for (agg.run_wait[1..agg.run_wait_count]) |run| {
        low = @min(low, run[column]);
        high = @max(high, run[column]);
    }
    return @as(f64, @floatFromInt(high - low)) / @as(f64, @floatFromInt(base)) * 100.0;
}

/// Fold the per-run rows into one metric value for the merged side.
fn mergedLatency(agg: *const MergedComm, metric: LatencyMetric) ?u64 {
    switch (metric) {
        .offcpu_p95 => {
            if (agg.offcpu.count == 0) return null;
            if (agg.runs_with_offcpu == 1) return agg.max_task_offcpu_p95_us;
            return agg.offcpu.quantileUpper(950);
        },
        .wait_p95 => {
            if (agg.wait.count == 0) return null;
            if (agg.runs_with_wait == 1) return agg.max_task_p95_us;
            return agg.wait.quantileUpper(950);
        },
        .wait_p50 => return if (agg.wait.count == 0) null else agg.wait.quantileUpper(500),
        .wait_p99 => return if (agg.wait.count == 0) null else agg.wait.quantileUpper(990),
        .wait_max => return if (agg.wait.count == 0) null else agg.wait.max_us,
    }
}

/// Noise for one metric: spread of that metric across the runs on both sides,
/// divided by the pooled baseline value. `null` when the baseline has no
/// comparable samples; 0 when a single run per comm leaves no spread.
fn metricNoise(metric: LatencyMetric, base: ?*const MergedComm, candidate: *const MergedComm, base_value: u64) ?f64 {
    if (base_value == 0) return 0;
    return @max(runSpreadPct(base, metric, base_value), runSpreadPct(candidate, metric, base_value));
}

fn addTotals(inputs: []const RunInput) Totals {
    var result = Totals{};
    for (inputs) |input| {
        const metrics = input.metrics;
        result.switches +|= metrics.switches;
        result.wakeups +|= metrics.wakeups;
        result.migrations +|= metrics.migrations;
        result.faults_minor +|= metrics.faults_minor;
        result.faults_major +|= metrics.faults_major;
        result.lost +|= metrics.lost;
        for (metrics.cpus) |cpu| result.cpu_busy_us +|= cpu.busy_us;
        if (preemptionTotal(metrics)) |total| {
            result.preemptions = (result.preemptions orelse 0) +| total;
        }
    }
    return result;
}

/// Total preemptions for one capture. The causal-latency metrics expose this
/// as a top-level counter; while an older build only carries per-task counts,
/// fall back to their sum. A build without either reports unknown.
fn preemptionTotal(metrics: metrics_mod.Metrics) ?u64 {
    const has_total = @hasField(metrics_mod.Metrics, "preemptions");
    if (comptime has_total) {
        if (metrics.preemptions != 0) return metrics.preemptions;
    }
    if (comptime @hasField(metrics_mod.TaskMetric, "preemptions")) {
        var total: u64 = 0;
        for (metrics.tasks) |task| total +|= task.preemptions;
        if (total != 0) return total;
    }
    if (comptime has_total) return metrics.preemptions;
    return null;
}

/// Whether `--fail-on` can evaluate this counter in the current build.
pub fn counterAvailable(metric: CounterMetric) bool {
    return switch (metric) {
        .preemptions => @hasField(metrics_mod.Metrics, "preemptions") or
            @hasField(metrics_mod.TaskMetric, "preemptions"),
        .migrations, .loss => true,
    };
}

fn ruleValue(agg: ?*const MergedComm, metric: LatencyMetric, legacy: bool) ?u64 {
    if (!legacy) return if (agg) |value| mergedLatency(value, metric) else null;
    if (metric != .wait_p95) return if (agg) |value| mergedLatency(value, metric) else null;
    // The legacy single-capture path reports 0 for an absent task and compares
    // it, exactly like the pre-noise-aware gate did.
    if (agg) |value| return mergedLatency(value, metric) orelse 0;
    return 0;
}

fn makeTaskDelta(
    candidate: *const MergedComm,
    base: ?*const MergedComm,
    legacy: bool,
    threshold_pct: f64,
) !TaskDelta {
    var task = TaskDelta{
        .comm = candidate.comm,
        .base_switches = if (base) |value| value.switches else 0,
        .candidate_switches = candidate.switches,
        .base_runs = if (base) |value| value.runs_seen else 0,
        .candidate_runs = candidate.runs_seen,
    };
    if (legacy) {
        const base_p95 = if (base) |value| value.max_task_p95_us else 0;
        const candidate_p95 = candidate.max_task_p95_us;
        const delta = deltaPct(base_p95, candidate_p95);
        task.base_p95_us = base_p95;
        task.candidate_p95_us = candidate_p95;
        task.delta_pct = delta;
        task.noise_pct = 0;
        task.regression = delta > threshold_pct and delta > 0;
        return task;
    }
    task.base_p95_us = if (base) |value| mergedLatency(value, .wait_p95) else null;
    task.candidate_p95_us = mergedLatency(candidate, .wait_p95);
    if (task.base_p95_us != null and task.candidate_p95_us != null) {
        const base_value = task.base_p95_us.?;
        const delta = deltaPct(base_value, task.candidate_p95_us.?);
        const noise = metricNoise(.wait_p95, base, candidate, base_value);
        task.delta_pct = delta;
        task.noise_pct = noise;
        task.regression = delta > threshold_pct and delta > (noise orelse 0);
    }
    return task;
}

/// Evaluate every requested gate rule against the merged sides.
fn evaluateRules(
    allocator: std.mem.Allocator,
    base: *const Side,
    candidate: *const Side,
    base_inputs: []const RunInput,
    candidate_inputs: []const RunInput,
    rules: []const Rule,
    legacy: bool,
    reasons: *std.ArrayList([]const u8),
    unavailable: *std.ArrayList([]const u8),
) !void {
    for (rules) |rule| switch (rule) {
        .latency => |latency_rule| {
            var evaluated: usize = 0;
            for (candidate.list.items) |*task| {
                const base_agg = base.lookup(task.comm);
                const base_value = ruleValue(base_agg, latency_rule.metric, legacy) orelse continue;
                const candidate_value = ruleValue(task, latency_rule.metric, legacy) orelse continue;
                evaluated += 1;
                const delta = deltaPct(base_value, candidate_value);
                const noise = if (legacy)
                    0.0
                else
                    metricNoise(latency_rule.metric, base_agg, task, base_value) orelse 0.0;
                if (delta > latency_rule.threshold_pct and delta > noise) {
                    const reason = try std.fmt.allocPrint(
                        allocator,
                        "{s}:{s} delta {d:.1}% > threshold {d:.1}% and noise {d:.1}%",
                        .{ latencyName(latency_rule.metric), task.comm, delta, latency_rule.threshold_pct, noise },
                    );
                    try appendCapped(allocator, reasons, reason);
                }
            }
            if (evaluated == 0) try unavailable.append(allocator, latencyName(latency_rule.metric));
        },
        .counter => |counter_rule| {
            const base_sum: ?u64 = counterSum(counter_rule.metric, base_inputs);
            const candidate_sum: ?u64 = counterSum(counter_rule.metric, candidate_inputs);
            if (base_sum == null or candidate_sum == null) {
                try unavailable.append(allocator, counterName(counter_rule.metric));
                continue;
            }
            const base_mean = @as(f64, @floatFromInt(base_sum.?)) /
                @as(f64, @floatFromInt(base_inputs.len));
            const candidate_mean = @as(f64, @floatFromInt(candidate_sum.?)) /
                @as(f64, @floatFromInt(candidate_inputs.len));
            const delta = candidate_mean - base_mean;
            const threshold: f64 = @floatFromInt(counter_rule.threshold);
            if (delta > threshold) {
                const reason = try std.fmt.allocPrint(
                    allocator,
                    "{s}: candidate mean {d:.1}/run > baseline mean {d:.1}/run + threshold {d:.1}",
                    .{ counterName(counter_rule.metric), candidate_mean, base_mean, threshold },
                );
                try appendCapped(allocator, reasons, reason);
            }
        },
    };
}

fn appendCapped(
    allocator: std.mem.Allocator,
    reasons: *std.ArrayList([]const u8),
    reason: []const u8,
) !void {
    if (reasons.items.len < max_fail_reasons) {
        try reasons.append(allocator, reason);
    } else if (reasons.items.len == max_fail_reasons) {
        try reasons.append(allocator, "fail reasons truncated; more rules failed");
    }
}

fn counterSum(metric: CounterMetric, inputs: []const RunInput) ?u64 {
    var total: u64 = 0;
    for (inputs) |input| {
        switch (metric) {
            .migrations => total +|= input.metrics.migrations,
            .loss => total +|= input.metrics.lost,
            .preemptions => {
                const value = preemptionTotal(input.metrics) orelse return null;
                total +|= value;
            },
        }
    }
    return total;
}

fn joinSources(allocator: std.mem.Allocator, inputs: []const RunInput) ![]const u8 {
    if (inputs.len == 1) return inputs[0].source;
    var joined: std.ArrayList(u8) = .empty;
    errdefer joined.deinit(allocator);
    for (inputs, 0..) |input, index| {
        if (index != 0) try joined.appendSlice(allocator, ", ");
        try joined.appendSlice(allocator, input.source);
    }
    return joined.toOwnedSlice(allocator);
}

pub fn build(
    allocator: std.mem.Allocator,
    base_inputs: []const RunInput,
    candidate_inputs: []const RunInput,
    options: Options,
) !Report {
    if (base_inputs.len == 0 or base_inputs.len > max_runs_per_side or
        candidate_inputs.len == 0 or candidate_inputs.len > max_runs_per_side)
    {
        return error.InvalidRunCount;
    }
    const legacy = base_inputs.len == 1 and candidate_inputs.len == 1;
    var base = try mergeSide(allocator, base_inputs);
    defer base.deinit(allocator);
    var candidate = try mergeSide(allocator, candidate_inputs);
    defer candidate.deinit(allocator);

    var task_list: std.ArrayList(TaskDelta) = .empty;
    errdefer task_list.deinit(allocator);
    for (candidate.list.items) |*task| {
        try task_list.append(allocator, try makeTaskDelta(
            task,
            base.lookup(task.comm),
            legacy,
            options.threshold_pct,
        ));
    }
    std.mem.sortUnstable(TaskDelta, task_list.items, {}, struct {
        fn less(_: void, a: TaskDelta, b: TaskDelta) bool {
            const a_p95 = a.candidate_p95_us orelse std.math.maxInt(u64);
            const b_p95 = b.candidate_p95_us orelse std.math.maxInt(u64);
            if (a_p95 != b_p95) return a_p95 > b_p95;
            return std.mem.order(u8, a.comm, b.comm) == .lt;
        }
    }.less);

    var reasons: std.ArrayList([]const u8) = .empty;
    errdefer reasons.deinit(allocator);
    var unavailable: std.ArrayList([]const u8) = .empty;
    errdefer unavailable.deinit(allocator);
    try evaluateRules(
        allocator,
        &base,
        &candidate,
        base_inputs,
        candidate_inputs,
        options.rules,
        legacy,
        &reasons,
        &unavailable,
    );
    std.mem.sortUnstable([]const u8, reasons.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    std.mem.sortUnstable([]const u8, unavailable.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    var regressions: usize = 0;
    for (task_list.items) |task| {
        if (task.regression) regressions += 1;
    }
    return .{
        .base_source = try joinSources(allocator, base_inputs),
        .candidate_source = try joinSources(allocator, candidate_inputs),
        .base_runs = base_inputs.len,
        .candidate_runs = candidate_inputs.len,
        .base = addTotals(base_inputs),
        .candidate = addTotals(candidate_inputs),
        .tasks = try task_list.toOwnedSlice(allocator),
        .regressions = regressions,
        .threshold_pct = options.threshold_pct,
        .fail_reasons = try reasons.toOwnedSlice(allocator),
        .unavailable_rules = try unavailable.toOwnedSlice(allocator),
    };
}

// --- Canonical JSON writer ---

fn optU64(value: ?u64) json.Value {
    return if (value) |number| .{ .unsigned = number } else .nul;
}

fn optFloat(value: ?f64) json.Value {
    return if (value) |number| .{ .float = number } else .nul;
}

fn totalsValue(totals: Totals, entries: *[8]json.Entry) []const json.Entry {
    entries[0] = .{ .key = "cpu_busy_us", .value = .{ .unsigned = totals.cpu_busy_us } };
    entries[1] = .{ .key = "faults_major", .value = .{ .unsigned = totals.faults_major } };
    entries[2] = .{ .key = "faults_minor", .value = .{ .unsigned = totals.faults_minor } };
    entries[3] = .{ .key = "lost", .value = .{ .unsigned = totals.lost } };
    entries[4] = .{ .key = "migrations", .value = .{ .unsigned = totals.migrations } };
    entries[5] = .{ .key = "preemptions", .value = optU64(totals.preemptions) };
    entries[6] = .{ .key = "switches", .value = .{ .unsigned = totals.switches } };
    entries[7] = .{ .key = "wakeups", .value = .{ .unsigned = totals.wakeups } };
    return entries;
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
        const item = try allocator.alloc(json.Entry, 10);
        item[0] = .{ .key = "base_p95_us", .value = optU64(task.base_p95_us) };
        item[1] = .{ .key = "base_runs", .value = .{ .unsigned = task.base_runs } };
        item[2] = .{ .key = "base_switches", .value = .{ .unsigned = task.base_switches } };
        item[3] = .{ .key = "candidate_p95_us", .value = optU64(task.candidate_p95_us) };
        item[4] = .{ .key = "candidate_runs", .value = .{ .unsigned = task.candidate_runs } };
        item[5] = .{ .key = "candidate_switches", .value = .{ .unsigned = task.candidate_switches } };
        item[6] = .{ .key = "comm", .value = .{ .string = task.comm } };
        item[7] = .{ .key = "delta_pct", .value = optFloat(task.delta_pct) };
        item[8] = .{ .key = "noise_pct", .value = optFloat(task.noise_pct) };
        item[9] = .{ .key = "regression", .value = .{ .boolean = task.regression } };
        entries[index] = item;
        task_values[index] = .{ .object = item };
    }
    var reason_values = try allocator.alloc(json.Value, report.fail_reasons.len);
    defer allocator.free(reason_values);
    for (report.fail_reasons, 0..) |reason, index| {
        reason_values[index] = .{ .string = reason };
    }
    var base_entries: [8]json.Entry = undefined;
    var candidate_entries: [8]json.Entry = undefined;
    try json.write(w, .{ .object = &.{
        .{ .key = "base", .value = .{ .object = totalsValue(report.base, &base_entries) } },
        .{ .key = "base_runs", .value = .{ .unsigned = report.base_runs } },
        .{ .key = "base_source", .value = .{ .string = report.base_source } },
        .{ .key = "candidate", .value = .{ .object = totalsValue(report.candidate, &candidate_entries) } },
        .{ .key = "candidate_runs", .value = .{ .unsigned = report.candidate_runs } },
        .{ .key = "candidate_source", .value = .{ .string = report.candidate_source } },
        .{ .key = "fail_reasons", .value = .{ .array = reason_values } },
        .{ .key = "host_mutation", .value = .{ .boolean = false } },
        .{ .key = "regressions", .value = .{ .unsigned = report.regressions } },
        .{ .key = "schema", .value = .{ .string = "xsprof/compare/v1" } },
        .{ .key = "tasks", .value = .{ .array = task_values } },
        .{ .key = "threshold_pct", .value = .{ .float = report.threshold_pct } },
    } });
}

// --- Human-readable reports ---

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

fn writeRuns(w: *std.Io.Writer, count: usize) !void {
    if (count > 1) try w.print(" ({d} runs)", .{count});
}

pub fn writeMarkdown(w: *std.Io.Writer, report: Report) !void {
    try w.writeAll("# xsprof comparison\n\nBase: `");
    try w.writeAll(report.base_source);
    try w.writeAll("`");
    try writeRuns(w, report.base_runs);
    try w.writeAll("  \nCandidate: `");
    try w.writeAll(report.candidate_source);
    try w.writeAll("`");
    try writeRuns(w, report.candidate_runs);
    try w.print("\n\nRegressions: **{d}** at threshold {d:.1}% (noise-aware)\n\n", .{
        report.regressions,
        report.threshold_pct,
    });
    try w.writeAll("| comm | base p95 | candidate p95 | delta | noise floor | runs |\n");
    try w.writeAll("|---|---:|---:|---:|---:|---:|\n");
    for (report.tasks) |task| {
        if (task.base_p95_us) |base_p95| {
            try w.print("| {s} | {d} ms | ", .{ task.comm, base_p95 / 1000 });
        } else {
            try w.print("| {s} | unknown | ", .{task.comm});
        }
        if (task.candidate_p95_us) |candidate_p95| {
            try w.print("{d} ms | ", .{candidate_p95 / 1000});
        } else {
            try w.writeAll("unknown | ");
        }
        if (task.delta_pct) |delta| {
            try w.print("{d:.1}% | ", .{delta});
        } else {
            try w.writeAll("unknown | ");
        }
        if (task.noise_pct) |noise| {
            try w.print("{d:.1}% | ", .{noise});
        } else {
            try w.writeAll("unknown | ");
        }
        try w.print("{d}/{d} |\n", .{ task.base_runs, task.candidate_runs });
    }
    if (report.fail_reasons.len != 0) {
        try w.writeAll("\n## Gate failures\n\n");
        for (report.fail_reasons) |reason| try w.print("- {s}\n", .{reason});
    }
}

pub fn writeHtml(w: *std.Io.Writer, report: Report) !void {
    try w.writeAll("<!doctype html><html><head><meta charset=\"utf-8\"><title>xsprof comparison</title>" ++
        "<style>body{font-family:monospace;background:#0b0b0a;color:#f5efe4;padding:24px}" ++
        "table{border-collapse:collapse;width:100%}td,th{border-bottom:1px solid #3a332b;padding:6px;text-align:left}" ++
        ".bad{color:#ff6b9a}</style></head><body><h1>xsprof comparison</h1>");
    try w.writeAll("<p>Base: <code>");
    try escape(w, report.base_source);
    try w.writeAll("</code>");
    try writeRuns(w, report.base_runs);
    try w.writeAll("<br>Candidate: <code>");
    try escape(w, report.candidate_source);
    try w.writeAll("</code>");
    try writeRuns(w, report.candidate_runs);
    try w.writeAll("</p>");
    try w.print("<p>Regressions: <strong>{d}</strong> at threshold {d:.1}% (noise-aware)</p>", .{
        report.regressions,
        report.threshold_pct,
    });
    try w.writeAll("<table><thead><tr><th>comm</th><th>base p95</th><th>candidate p95</th>" ++
        "<th>delta</th><th>noise floor</th><th>runs</th></tr></thead><tbody>");
    for (report.tasks) |task| {
        try w.writeAll("<tr><td>");
        try escape(w, task.comm);
        try w.writeAll("</td><td>");
        if (task.base_p95_us) |base_p95| {
            try w.print("{d} ms", .{base_p95 / 1000});
        } else {
            try w.writeAll("unknown");
        }
        try w.writeAll("</td><td>");
        if (task.candidate_p95_us) |candidate_p95| {
            try w.print("{d} ms", .{candidate_p95 / 1000});
        } else {
            try w.writeAll("unknown");
        }
        try w.writeAll("</td><td class=\"");
        try w.writeAll(if (task.regression) "bad" else "");
        try w.writeAll("\">");
        if (task.delta_pct) |delta| {
            try w.print("{d:.1}%", .{delta});
        } else {
            try w.writeAll("unknown");
        }
        try w.writeAll("</td><td>");
        if (task.noise_pct) |noise| {
            try w.print("{d:.1}%", .{noise});
        } else {
            try w.writeAll("unknown");
        }
        try w.print("</td><td>{d}/{d}</td></tr>", .{ task.base_runs, task.candidate_runs });
    }
    try w.writeAll("</tbody></table>");
    if (report.fail_reasons.len != 0) {
        try w.writeAll("<h2>Gate failures</h2><ul>");
        for (report.fail_reasons) |reason| {
            try w.writeAll("<li>");
            try escape(w, reason);
            try w.writeAll("</li>");
        }
        try w.writeAll("</ul>");
    }
    try w.writeAll("</body></html>\n");
}

// --- Tests (deterministic synthetic data; no timing dependence) ---

fn commRun(name: []const u8, waits: []const u64) CommRun {
    var histogram = metrics_mod.Histogram{};
    for (waits) |value| histogram.observe(value);
    return .{
        .comm = name,
        .wait = histogram,
        .max_wait_p95_us = histogram.quantileUpper(950),
        .switches = 10,
    };
}

fn runOf(source: []const u8, comms: []const CommRun) RunInput {
    return .{ .source = source, .comms = comms };
}

test "histogram merge pools runs and reports the noise floor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var run1 = [_]u64{1000};
    var run2 = [_]u64{3000};
    const base_runs = [_]RunInput{
        runOf("b1", &.{commRun("worker", &run1)}),
        runOf("b2", &.{commRun("worker", &run2)}),
    };
    var candidate_wait = [_]u64{1500};
    const candidate_runs = [_]RunInput{
        runOf("c1", &.{commRun("worker", &candidate_wait)}),
    };
    const report = try build(allocator, &base_runs, &candidate_runs, .{});
    try std.testing.expectEqual(@as(usize, 2), report.base_runs);
    const task = report.tasks[0];
    try std.testing.expectEqual(@as(u64, 4096), task.base_p95_us.?);
    try std.testing.expectEqual(@as(u64, 2048), task.candidate_p95_us.?);
    try std.testing.expectApproxEqAbs(@as(f64, 75.0), task.noise_pct.?, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, -50.0), task.delta_pct.?, 0.001);
    try std.testing.expect(!task.regression);
    try std.testing.expectEqual(@as(usize, 2), task.base_runs);
    try std.testing.expectEqual(@as(u64, 20), task.base_switches);
}
test "noise floor suppresses a small shift and flags a large one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var dense: [100]u64 = @splat(1000);
    var sparse = [_]u64{3000};
    const base_runs = [_]RunInput{
        runOf("b1", &.{commRun("worker", &dense)}),
        runOf("b2", &.{commRun("worker", &sparse)}),
    };
    // Pooled base p95 stays at the dense bucket (1024us) while a sparse run
    // saw 4096us: a 300% noise floor.
    var quiet = [_]u64{1500};
    var loud = [_]u64{12000};
    const suppressed_runs = [_]RunInput{
        runOf("c1", &.{commRun("worker", &quiet)}),
        runOf("c2", &.{commRun("worker", &quiet)}),
    };
    var rule = [_]Rule{.{ .latency = .{ .metric = .wait_p95, .threshold_pct = 0 } }};
    const suppressed = try build(allocator, &base_runs, &suppressed_runs, .{ .rules = &rule });
    try std.testing.expectApproxEqAbs(@as(f64, 300.0), suppressed.tasks[0].noise_pct.?, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 100.0), suppressed.tasks[0].delta_pct.?, 0.001);
    try std.testing.expect(!suppressed.tasks[0].regression);
    try std.testing.expectEqual(@as(usize, 0), suppressed.fail_reasons.len);
    try std.testing.expectEqual(@as(usize, 0), suppressed.unavailable_rules.len);
    const loud_runs = [_]RunInput{
        runOf("c1", &.{commRun("worker", &loud)}),
        runOf("c2", &.{commRun("worker", &loud)}),
    };
    const flagged = try build(allocator, &base_runs, &loud_runs, .{ .rules = &rule });
    try std.testing.expect(flagged.tasks[0].regression);
    try std.testing.expectEqual(@as(usize, 1), flagged.fail_reasons.len);
    try std.testing.expect(std.mem.indexOf(u8, flagged.fail_reasons[0], "wait.p95:worker") != null);
}
test "single-capture output keeps the legacy values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var base_wait = [_]u64{1000};
    var candidate_wait = [_]u64{2000};
    const base_runs = [_]RunInput{runOf("base", &.{commRun("worker", &base_wait)})};
    const candidate_runs = [_]RunInput{runOf("candidate", &.{commRun("worker", &candidate_wait)})};
    const report = try build(allocator, &base_runs, &candidate_runs, .{});
    try std.testing.expectEqualStrings("base", report.base_source);
    try std.testing.expectEqual(@as(u64, 1024), report.tasks[0].base_p95_us.?);
    try std.testing.expectEqual(@as(u64, 2048), report.tasks[0].candidate_p95_us.?);
    try std.testing.expectApproxEqAbs(@as(f64, 100.0), report.tasks[0].delta_pct.?, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), report.tasks[0].noise_pct.?, 0.001);
    try std.testing.expect(report.tasks[0].regression);
    try std.testing.expectEqual(@as(usize, 1), report.regressions);
    // The legacy absent-comm convention stays intact for one capture per side.
    const empty_base = [_]RunInput{runOf("base", &.{})};
    const legacy = try build(allocator, &empty_base, &candidate_runs, .{});
    try std.testing.expectEqual(@as(u64, 0), legacy.tasks[0].base_p95_us.?);
    try std.testing.expectApproxEqAbs(@as(f64, 100.0), legacy.tasks[0].delta_pct.?, 0.001);
    try std.testing.expect(legacy.tasks[0].regression);
    var buffer = std.Io.Writer.Allocating.init(allocator);
    defer buffer.deinit();
    try writeJson(&buffer.writer, report);
    const text = buffer.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "\"schema\":\"xsprof/compare/v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"host_mutation\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"base_runs\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"fail_reasons\":[]") != null);
}
test "missing multi-run data stays unknown instead of zero" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var old_wait = [_]u64{1000};
    var new_wait = [_]u64{2000};
    const base_runs = [_]RunInput{
        runOf("b1", &.{commRun("old-task", &old_wait)}),
        runOf("b2", &.{commRun("old-task", &old_wait)}),
    };
    const candidate_runs = [_]RunInput{
        runOf("c1", &.{commRun("new-task", &new_wait)}),
        runOf("c2", &.{commRun("new-task", &new_wait)}),
    };
    var rule = [_]Rule{.{ .latency = .{ .metric = .wait_p95, .threshold_pct = 0 } }};
    const report = try build(allocator, &base_runs, &candidate_runs, .{ .rules = &rule });
    try std.testing.expectEqual(@as(usize, 1), report.tasks.len);
    const task = report.tasks[0];
    try std.testing.expectEqualStrings("new-task", task.comm);
    try std.testing.expect(task.base_p95_us == null and task.delta_pct == null and task.noise_pct == null);
    try std.testing.expect(!task.regression);
    try std.testing.expectEqual(@as(usize, 0), task.base_runs);
    try std.testing.expectEqual(@as(usize, 2), task.candidate_runs);
    try std.testing.expectEqual(@as(usize, 1), report.unavailable_rules.len);
    try std.testing.expectEqualStrings("wait.p95", report.unavailable_rules[0]);
}
test "counter rules compare mean-per-run deltas" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var base_inputs = [_]RunInput{
        .{ .source = "b1", .metrics = .{ .migrations = 5, .lost = 0 } },
        .{ .source = "b2", .metrics = .{ .migrations = 5, .lost = 0 } },
    };
    var candidate_inputs = [_]RunInput{
        .{ .source = "c1", .metrics = .{ .migrations = 10, .lost = 0 } },
        .{ .source = "c2", .metrics = .{ .migrations = 10, .lost = 0 } },
    };
    var migrate_rule = [_]Rule{.{ .counter = .{ .metric = .migrations, .threshold = 5 } }};
    const pass_report = try build(allocator, &base_inputs, &candidate_inputs, .{ .rules = &migrate_rule });
    try std.testing.expectEqual(@as(usize, 0), pass_report.fail_reasons.len);
    migrate_rule[0] = .{ .counter = .{ .metric = .migrations, .threshold = 4 } };
    const fail_report = try build(allocator, &base_inputs, &candidate_inputs, .{ .rules = &migrate_rule });
    try std.testing.expectEqual(@as(usize, 1), fail_report.fail_reasons.len);
    try std.testing.expect(std.mem.indexOf(u8, fail_report.fail_reasons[0], "migrations:") != null);
    var loss_rule = [_]Rule{.{ .counter = .{ .metric = .loss, .threshold = 0 } }};
    candidate_inputs[0].metrics.lost = 2;
    const loss_report = try build(allocator, &base_inputs, &candidate_inputs, .{ .rules = &loss_rule });
    try std.testing.expectEqual(@as(usize, 1), loss_report.fail_reasons.len);
}
test "fail-on grammar parses latency and counter rules" {
    const percent = try parseRule("wait.p95=10%");
    try std.testing.expectEqual(LatencyMetric.wait_p95, percent.latency.metric);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), percent.latency.threshold_pct, 0.001);
    const plain = try parseRule("offcpu.p95=20");
    try std.testing.expectEqual(LatencyMetric.offcpu_p95, plain.latency.metric);
    const counter = try parseRule("loss=0");
    try std.testing.expectEqual(CounterMetric.loss, counter.counter.metric);
    try std.testing.expectEqual(@as(u64, 0), counter.counter.threshold);
    inline for (.{ "wait.p95", "wait.p90=5", "wait.p95=abc", "wait.p95=-1", "loss=10%", "bogus=1", "migrations=x" }) |text| {
        try std.testing.expectError(error.InvalidRule, parseRule(text));
    }
}
