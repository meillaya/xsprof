//! Frozen aggregate snapshot consumed by the advisor and the UI.
//! Uncollected signals stay at their fail-closed defaults.

const std = @import("std");
const json = @import("../core/json.zig");
const proc = @import("../os/linux/proc.zig");

const Writer = std.Io.Writer;

pub const Aggregates = struct {
    remote_fault_ratio: f64 = 0,
    dominant_node: i32 = -1,
    task_cpu_node: i32 = -1,

    migrations: i64 = 0,
    cross_llc_migration: bool = false,
    llc_domains: i32 = 1,
    wakeups: i64 = 0,
    unnecessary_wakeups: i64 = 0,
    lock_contentions: i64 = 0,
    avg_lock_wait_ms: f64 = 0,

    llc_misses: i64 = 0,
    tlb_misses: i64 = 0,
    page_faults: i64 = 0,
    remote_hitm: f64 = 0,

    buddy_fragmentation: f64 = 0,
    small_alloc_churn: i64 = 0,

    priority_inversion_observed: bool = false,
    pmu_collected: bool = false,
    sched_collected: bool = false,
};

pub fn writeJson(w: *Writer, agg: Aggregates) Writer.Error!void {
    try json.write(w, .{ .object = &.{
        .{ .key = "avg_lock_wait_ms", .value = .{ .float = agg.avg_lock_wait_ms } },
        .{ .key = "buddy_fragmentation", .value = .{ .float = agg.buddy_fragmentation } },
        .{ .key = "cross_llc_migration", .value = .{ .boolean = agg.cross_llc_migration } },
        .{ .key = "dominant_node", .value = .{ .integer = agg.dominant_node } },
        .{ .key = "host_mutation", .value = .{ .boolean = false } },
        .{ .key = "llc_domains", .value = .{ .integer = agg.llc_domains } },
        .{ .key = "llc_misses", .value = .{ .integer = agg.llc_misses } },
        .{ .key = "lock_contentions", .value = .{ .integer = agg.lock_contentions } },
        .{ .key = "migrations", .value = .{ .integer = agg.migrations } },
        .{ .key = "page_faults", .value = .{ .integer = agg.page_faults } },
        .{ .key = "pmu_collected", .value = .{ .boolean = agg.pmu_collected } },
        .{ .key = "priority_inversion_observed", .value = .{ .boolean = agg.priority_inversion_observed } },
        .{ .key = "remote_fault_ratio", .value = .{ .float = agg.remote_fault_ratio } },
        .{ .key = "remote_hitm", .value = .{ .float = agg.remote_hitm } },
        .{ .key = "sched_collected", .value = .{ .boolean = agg.sched_collected } },
        .{ .key = "schema", .value = .{ .string = "xsprof/aggregates/v1" } },
        .{ .key = "small_alloc_churn", .value = .{ .integer = agg.small_alloc_churn } },
        .{ .key = "task_cpu_node", .value = .{ .integer = agg.task_cpu_node } },
        .{ .key = "tlb_misses", .value = .{ .integer = agg.tlb_misses } },
        .{ .key = "unnecessary_wakeups", .value = .{ .integer = agg.unnecessary_wakeups } },
        .{ .key = "wakeups", .value = .{ .integer = agg.wakeups } },
    } });
}

fn parseBuddyCounts(line: []const u8, out: []i64) usize {
    const comma = std.mem.indexOfScalar(u8, line, ',') orelse return 0;
    var it = std.mem.tokenizeAny(u8, line[comma + 1 ..], " \t");
    var n: usize = 0;
    while (it.next()) |token| {
        if (n == out.len) break;
        out[n] = std.fmt.parseInt(i64, token, 10) catch continue;
        n += 1;
    }
    return n;
}

pub fn fromFacts(facts: proc.Facts) Aggregates {
    var agg: Aggregates = .{};
    agg.pmu_collected = facts.perf_event_paranoid <= 1;
    agg.sched_collected = false;
    agg.llc_domains = if (facts.numa_nodes.len == 0)
        1
    else
        @intCast(@min(facts.numa_nodes.len, std.math.maxInt(i32)));

    if (facts.buddyinfo.len != 0) {
        var counts: [16]i64 = undefined;
        const n = parseBuddyCounts(facts.buddyinfo[facts.buddyinfo.len - 1], &counts);
        if (n >= 2) {
            var low: i64 = 0;
            var high: i64 = 0;
            for (counts[0..n], 0..) |value, i| {
                if (i < 4) low += value else high += value;
            }
            const total = low + high;
            if (total > 0) {
                agg.buddy_fragmentation = @as(f64, @floatFromInt(low)) /
                    @as(f64, @floatFromInt(total));
            }
        }
    }
    return agg;
}

test "empty aggregates match the archived golden bytes" {
    const golden =
        "{\"avg_lock_wait_ms\":0,\"buddy_fragmentation\":0,\"cross_llc_migration\":false," ++
        "\"dominant_node\":-1,\"host_mutation\":false,\"llc_domains\":1,\"llc_misses\":0," ++
        "\"lock_contentions\":0,\"migrations\":0,\"page_faults\":0,\"pmu_collected\":false," ++
        "\"priority_inversion_observed\":false,\"remote_fault_ratio\":0,\"remote_hitm\":0," ++
        "\"sched_collected\":false,\"schema\":\"xsprof/aggregates/v1\"," ++
        "\"small_alloc_churn\":0,\"task_cpu_node\":-1,\"tlb_misses\":0," ++
        "\"unnecessary_wakeups\":0,\"wakeups\":0}";
    var buf: [1024]u8 = undefined;
    var w = Writer.fixed(&buf);
    try writeJson(&w, .{});
    try std.testing.expectEqualStrings(golden, w.buffered());
}

test "fragmentation uses the last buddyinfo line" {
    const facts: proc.Facts = .{
        .buddyinfo = &.{"Node 0, zone Normal 10 10 5 5 1 0 0 0 0 0 0"},
    };
    const agg = fromFacts(facts);
    try std.testing.expectApproxEqAbs(@as(f64, 30.0 / 31.0), agg.buddy_fragmentation, 0.0001);
    try std.testing.expectEqual(@as(i32, 1), agg.llc_domains);
}
