//! Canonical metrics JSON writer, split from the hot-path aggregator so the
//! pair/timestamp/causal fields can grow without crossing the line limit.
//!
//! Latency-attribution additions are additive: a sidecar written before v0.7
//! still validates, and a reader that ignores the new keys loses no existing
//! meaning. Cause objects only list nonzero causes, so a missing key means
//! "not observed", never an invented zero.

const std = @import("std");
const json = @import("../core/json.zig");
const loss = @import("../core/loss.zig");
const sched_state = @import("../core/sched_state.zig");
const metrics_mod = @import("metrics.zig");
const Metrics = metrics_mod.Metrics;

test "metrics json drops the recorder from top tasks" {
    const metrics: Metrics = .{ .tasks = &.{
        .{ .pid = 1, .comm = "xsprof", .is_self = true },
        .{ .pid = 2, .comm = "worker", .switches = 1 },
    } };
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeJson(&w, metrics, 10);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\"comm\":\"xsprof\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "worker") != null);
}

/// Writes the bounded cause object `{"<reason>":{"count":N,"total_us":N},...}`
/// with ascending reason keys. Returns the number of entries written.
fn writeCauseObject(
    entries: *[sched_state.cause_count]json.Entry,
    inner_entries: *[sched_state.cause_count][2]json.Entry,
    cause_values: *[sched_state.cause_count]json.Value,
    stats: *const [sched_state.cause_count]metrics_mod.CauseStat,
) usize {
    const names = @typeInfo(sched_state.Cause).@"enum".field_names;
    var count: usize = 0;
    for (names, 0..) |name, index| {
        const stat = stats[index];
        if (stat.count == 0) continue;
        inner_entries[count][0] = .{ .key = "count", .value = .{ .unsigned = stat.count } };
        inner_entries[count][1] = .{ .key = "total_us", .value = .{ .unsigned = stat.total_us } };
        cause_values[count] = json.Value{ .object = inner_entries[count][0..] };
        entries[count] = .{ .key = name, .value = cause_values[count] };
        count += 1;
    }
    return count;
}

pub fn writeJson(w: *std.Io.Writer, metrics: Metrics, top: usize) !void {
    const allocator = std.heap.smp_allocator;
    const task_count = blk: {
        var count: usize = 0;
        for (metrics.tasks) |task| {
            if (task.is_self) continue;
            if (count == top) break;
            count += 1;
        }
        break :blk count;
    };
    var task_values = try allocator.alloc(json.Value, task_count);
    defer allocator.free(task_values);
    var task_entries = try allocator.alloc([]json.Entry, task_count);
    defer {
        for (task_entries) |entries| allocator.free(entries);
        allocator.free(task_entries);
    }
    // Per-task off-CPU cause objects: outer reason entries, inner count/total
    // pairs, and the inner object values (all bounded by the enum width).
    var task_reason_entries = try allocator.alloc([sched_state.cause_count]json.Entry, task_count);
    defer allocator.free(task_reason_entries);
    var task_inner_entries = try allocator.alloc([sched_state.cause_count][2]json.Entry, task_count);
    defer allocator.free(task_inner_entries);
    var task_cause_values = try allocator.alloc([sched_state.cause_count]json.Value, task_count);
    defer allocator.free(task_cause_values);
    var task_reason_count = try allocator.alloc(usize, task_count);
    defer allocator.free(task_reason_count);

    var out_index: usize = 0;
    for (metrics.tasks) |task| {
        if (task.is_self) continue;
        if (out_index == task_count) break;
        const entries = try allocator.alloc(json.Entry, 17);
        task_reason_count[out_index] = writeCauseObject(
            &task_reason_entries[out_index],
            &task_inner_entries[out_index],
            &task_cause_values[out_index],
            &task.offcpu_by_reason,
        );
        entries[0] = .{ .key = "comm", .value = .{ .string = task.comm } };
        entries[1] = .{ .key = "faults_major", .value = .{ .unsigned = task.faults_major } };
        entries[2] = .{ .key = "faults_minor", .value = .{ .unsigned = task.faults_minor } };
        entries[3] = .{ .key = "last_cpu", .value = .{ .integer = task.last_cpu } };
        entries[4] = .{ .key = "migrations", .value = .{ .unsigned = task.migrations } };
        entries[5] = .{ .key = "offcpu_by_reason", .value = .{
            .object = task_reason_entries[out_index][0..task_reason_count[out_index]],
        } };
        entries[6] = .{ .key = "offcpu_p95_us", .value = .{ .unsigned = task.offcpu_p95_us } };
        entries[7] = .{ .key = "pid", .value = .{ .integer = task.pid } };
        entries[8] = .{ .key = "preempt_p95_us", .value = .{ .unsigned = task.preempt_p95_us } };
        entries[9] = .{ .key = "preemptions", .value = .{ .unsigned = task.preemptions } };
        entries[10] = .{ .key = "switches", .value = .{ .unsigned = task.switches } };
        entries[11] = .{ .key = "wait_max_us", .value = .{ .unsigned = task.wait_max_us } };
        entries[12] = .{ .key = "wait_p50_us", .value = .{ .unsigned = task.wait_p50_us } };
        entries[13] = .{ .key = "wait_p95_us", .value = .{ .unsigned = task.wait_p95_us } };
        entries[14] = .{ .key = "wait_p99_us", .value = .{ .unsigned = task.wait_p99_us } };
        entries[15] = .{ .key = "wait_samples", .value = .{ .unsigned = task.wait_samples } };
        entries[16] = .{ .key = "wakeups", .value = .{ .unsigned = task.wakeups } };
        task_entries[out_index] = entries;
        task_values[out_index] = .{ .object = entries };
        out_index += 1;
    }

    var cpu_values = try allocator.alloc(json.Value, metrics.cpus.len);
    defer allocator.free(cpu_values);
    var cpu_entries = try allocator.alloc([]json.Entry, metrics.cpus.len);
    defer {
        for (cpu_entries) |entries| allocator.free(entries);
        allocator.free(cpu_entries);
    }
    for (metrics.cpus, 0..) |cpu, index| {
        const entries = try allocator.alloc(json.Entry, 5);
        entries[0] = .{ .key = "busy_us", .value = .{ .unsigned = cpu.busy_us } };
        entries[1] = .{ .key = "cpu", .value = .{ .unsigned = cpu.cpu } };
        entries[2] = .{ .key = "faults", .value = .{ .unsigned = cpu.faults } };
        entries[3] = .{ .key = "idle_us", .value = .{ .unsigned = cpu.idle_us } };
        entries[4] = .{ .key = "switches", .value = .{ .unsigned = cpu.switches } };
        cpu_entries[index] = entries;
        cpu_values[index] = .{ .object = entries };
    }

    var pair_values = try allocator.alloc(json.Value, metrics.wakeup_pairs.len);
    defer allocator.free(pair_values);
    var pair_entries = try allocator.alloc([]json.Entry, metrics.wakeup_pairs.len);
    defer {
        for (pair_entries) |entries| allocator.free(entries);
        allocator.free(pair_entries);
    }
    for (metrics.wakeup_pairs, 0..) |pair, index| {
        const entries = try allocator.alloc(json.Entry, 6);
        entries[0] = .{ .key = "count", .value = .{ .unsigned = pair.count } };
        entries[1] = .{ .key = "p95_wait_us", .value = .{ .unsigned = pair.p95_wait_us } };
        entries[2] = .{ .key = "waker_comm", .value = .{ .string = pair.waker_comm } };
        entries[3] = .{ .key = "waker_pid", .value = .{ .integer = pair.waker_pid } };
        entries[4] = .{ .key = "woken_comm", .value = .{ .string = pair.woken_comm } };
        entries[5] = .{ .key = "woken_pid", .value = .{ .integer = pair.woken_pid } };
        pair_entries[index] = entries;
        pair_values[index] = .{ .object = entries };
    }

    // Loss breakdown: nonzero kinds only, enum (alphabetical) order so the
    // object keys are canonical ascending.
    var loss_entries: [loss.kind_count]json.Entry = undefined;
    var loss_count: usize = 0;
    inline for (@typeInfo(loss.ByKind).@"struct".field_names) |field_name| {
        const value = @field(metrics.loss_by_kind, field_name);
        if (value != 0) {
            loss_entries[loss_count] = .{ .key = field_name, .value = .{ .unsigned = value } };
            loss_count += 1;
        }
    }

    var cause_entries: [sched_state.cause_count]json.Entry = undefined;
    var cause_inner: [sched_state.cause_count][2]json.Entry = undefined;
    var cause_values: [sched_state.cause_count]json.Value = undefined;
    const cause_count = writeCauseObject(&cause_entries, &cause_inner, &cause_values, &metrics.causes);

    try json.write(w, .{ .object = &.{
        .{ .key = "cpus", .value = .{ .array = cpu_values } },
        .{ .key = "events", .value = .{ .unsigned = metrics.events } },
        .{ .key = "faults_major", .value = .{ .unsigned = metrics.faults_major } },
        .{ .key = "faults_minor", .value = .{ .unsigned = metrics.faults_minor } },
        .{ .key = "first_us", .value = .{ .unsigned = metrics.first_us } },
        .{ .key = "host_mutation", .value = .{ .boolean = false } },
        .{ .key = "last_us", .value = .{ .unsigned = metrics.last_us } },
        .{ .key = "loss_by_kind", .value = .{ .object = loss_entries[0..loss_count] } },
        .{ .key = "lost", .value = .{ .unsigned = metrics.lost } },
        .{ .key = "migrations", .value = .{ .unsigned = metrics.migrations } },
        .{ .key = "offcpu_by_reason", .value = .{ .object = cause_entries[0..cause_count] } },
        .{ .key = "offcpu_samples", .value = .{ .unsigned = metrics.offcpu_samples } },
        .{ .key = "offcpu_unresolved", .value = .{ .unsigned = metrics.offcpu_unresolved } },
        .{ .key = "out_of_order", .value = .{ .unsigned = metrics.out_of_order } },
        .{ .key = "pairs_truncated", .value = .{ .boolean = metrics.pairs_truncated } },
        .{ .key = "preempt_p95_us", .value = .{ .unsigned = metrics.preempt.quantileUpper(950) } },
        .{ .key = "preempt_unresolved", .value = .{ .unsigned = metrics.preempt_unresolved } },
        .{ .key = "preemptions", .value = .{ .unsigned = metrics.preemptions } },
        .{ .key = "quantiles", .value = .{ .object = &.{
            .{ .key = "approximate", .value = .{ .boolean = true } },
            .{ .key = "method", .value = .{ .string = "log2_histogram_1us" } },
        } } },
        .{ .key = "schema", .value = .{ .string = "xsprof/metrics/v1" } },
        .{ .key = "self_unnecessary_wakeups", .value = .{ .unsigned = metrics.self_unnecessary_wakeups } },
        .{ .key = "self_wakeups", .value = .{ .unsigned = metrics.self_wakeups } },
        .{ .key = "stack_frames", .value = .{ .unsigned = metrics.stack_frames } },
        .{ .key = "stack_samples", .value = .{ .unsigned = metrics.stack_samples } },
        .{ .key = "switches", .value = .{ .unsigned = metrics.switches } },
        .{ .key = "tasks", .value = .{ .array = task_values[0..out_index] } },
        .{ .key = "unnecessary_wakeups", .value = .{ .unsigned = metrics.unnecessary_wakeups } },
        .{ .key = "unresolved_wakeups", .value = .{ .unsigned = metrics.unresolved_wakeups } },
        .{ .key = "wakeup_pairs", .value = .{ .array = pair_values } },
        .{ .key = "wakeups", .value = .{ .unsigned = metrics.wakeups } },
    } });
}

// Checks the additive loss breakdown is canonical and only lists nonzero kinds.
test "metrics json reports loss_by_kind in ascending key order" {
    var metrics: Metrics = .{};
    metrics.lost = 9;
    metrics.loss_by_kind.sample_loss = 5;
    metrics.loss_by_kind.retention_loss = 2;
    metrics.loss_by_kind.capture_corrupt_segment = 2;
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeJson(&w, metrics, 10);
    try std.testing.expect(std.mem.indexOf(
        u8,
        w.buffered(),
        "\"loss_by_kind\":{\"capture_corrupt_segment\":2,\"retention_loss\":2,\"sample_loss\":5}",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\"lost\":9") != null);
    // The breakdown precedes "lost" and no zero-kind key leaks in.
    const loss_by_kind = std.mem.indexOf(u8, w.buffered(), "\"loss_by_kind\"").?;
    const lost = std.mem.indexOf(u8, w.buffered(), "\"lost\"").?;
    try std.testing.expect(loss_by_kind < lost);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\"capture_missing_segment\"") == null);
}

// Checks the additive causal fields are canonical, only list nonzero causes,
// and that the root object keys stay strictly ascending.
test "metrics json reports offcpu causes and preemptions" {
    var metrics: Metrics = .{};
    metrics.offcpu_samples = 2;
    metrics.offcpu_unresolved = 1;
    metrics.causes[@backingInt(sched_state.Cause.interruptible)] = .{ .count = 2, .total_us = 500 };
    metrics.preempt.observe(7);
    metrics.preemptions = 1;
    metrics.tasks = &.{.{
        .pid = 2,
        .comm = "worker",
        .offcpu_by_reason = blk: {
            var causes: [sched_state.cause_count]metrics_mod.CauseStat = @splat(.{});
            causes[@backingInt(sched_state.Cause.uninterruptible)] = .{ .count = 1, .total_us = 50 };
            break :blk causes;
        },
        .preemptions = 1,
        .preempt_p95_us = 10,
    }};
    var buf: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeJson(&w, metrics, 10);
    const text = w.buffered();
    try std.testing.expect(std.mem.indexOf(
        u8,
        text,
        "\"offcpu_by_reason\":{\"interruptible\":{\"count\":2,\"total_us\":500}}",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"offcpu_samples\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"offcpu_unresolved\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"preempt_p95_us\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"preemptions\":1") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text,
        "\"offcpu_by_reason\":{\"uninterruptible\":{\"count\":1,\"total_us\":50}}" ++
            ",\"offcpu_p95_us\":0,\"pid\":2,\"preempt_p95_us\":10,\"preemptions\":1,\"switches\":0",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"reason\":\"dead\"") == null);
}
