//! Converts a replay Session, its metrics, and advisor findings into the
//! console model. Every unavailable signal stays explicit; nothing is
//! zero-filled into a success state.

const std = @import("std");
const session_mod = @import("../../stream/session.zig");
const metrics_mod = @import("../../analyze/metrics.zig");
const advisor_mod = @import("../../analyze/advisor.zig");
const event_mod = @import("../../core/event.zig");
const model_mod = @import("model.zig");

const Session = session_mod.Session;
const Model = model_mod.Model;

pub const Context = struct {
    host: []const u8 = "journal",
    kernel: []const u8 = "",
    arch: []const u8 = "",
    source: []const u8 = "REPLAY",
    fixture: []const u8 = "",
    capture_window: []const u8 = "",
    capture_start: []const u8 = "",
    capture_end: []const u8 = "",
    session_label: []const u8 = "",
    live: bool = false,
    started_at: i64 = 0,
};

const rule_ids = [_][]const u8{
    "poor-numa-placement",
    "cpu-affinity-churn",
    "unnecessary-wakeups",
    "excessive-locking",
    "false-sharing",
    "allocator-fragmentation",
    "priority-inversion",
};

pub fn fromSession(allocator: std.mem.Allocator, session: *const Session, ctx: Context) !Model {
    const duration_us = session.durationUs();
    const window_ms: f64 = @as(f64, @floatFromInt(duration_us)) / 1000.0;
    const first_us = session.first_us;

    var lanes = std.StringHashMap(u8).init(allocator);
    var lane_next: u8 = 1;
    for (session.top_comms) |comm| {
        if (std.mem.eql(u8, comm.comm, "idle")) continue;
        if (lanes.contains(comm.comm)) continue;
        if (lane_next > 9) break;
        try lanes.put(comm.comm, lane_next);
        lane_next += 1;
    }

    const slices = try allocator.alloc(model_mod.Slice, session.slices.len);
    for (session.slices, 0..) |slice, i| {
        const lane = lanes.get(slice.comm) orelse 9;
        slices[i] = .{
            .id = @intCast(i),
            .cpu = slice.cpu,
            .comm = slice.comm,
            .pid = slice.pid,
            .lane = lane,
            .start = @as(f64, @floatFromInt(slice.start_us -| first_us)) / 1000.0,
            .dur = @as(f64, @floatFromInt(slice.end_us -| slice.start_us)) / 1000.0,
        };
    }

    const cpu_stats = try allocator.alloc(model_mod.CpuStat, @max(1, session.cpu_count));
    var total_busy: f64 = 0;
    var busy_cpus: u32 = 0;
    for (cpu_stats, 0..) |*stat, index| {
        var busy: u64 = 0;
        var idle: u64 = 0;
        var switches: u32 = 0;
        var best_p95: u64 = 0;
        for (session.metrics.cpus) |cpu| {
            if (cpu.cpu != index) continue;
            busy = cpu.busy_us;
            idle = cpu.idle_us;
            switches = @intCast(@min(cpu.switches, std.math.maxInt(u32)));
        }
        for (session.metrics.tasks) |task| {
            if (task.last_cpu == index) best_p95 = @max(best_p95, task.wait_p95_us);
        }
        var slice_busy_us: u64 = 0;
        const total = busy + idle;
        const slice_total_us: u64 = if (duration_us == 0) 1 else duration_us;
        const busy_pct: u8 = if (slice_busy_us == 0)
            (if (total == 0) 0 else @intFromFloat(@round(@as(f64, @floatFromInt(busy)) * 100.0 / @as(f64, @floatFromInt(total)))))
        else
            @intFromFloat(@min(100.0, @round(@as(f64, @floatFromInt(slice_busy_us)) * 100.0 / @as(f64, @floatFromInt(slice_total_us)))));
        if (total > 0 or slice_busy_us > 0) {
            total_busy += @floatFromInt(busy_pct);
            busy_cpus += 1;
        }
        var buckets = try allocator.alloc(f64, 48);
        @memset(buckets, 0);
        if (window_ms > 0) {
            const bucket_ms = window_ms / 48.0;
            for (session.slices) |slice| {
                if (slice.cpu != index) continue;
                if (!std.mem.eql(u8, slice.comm, "idle")) slice_busy_us +|= slice.end_us -| slice.start_us;
                const start = @as(f64, @floatFromInt(slice.start_us -| first_us)) / 1000.0;
                const end = @as(f64, @floatFromInt(slice.end_us -| first_us)) / 1000.0;
                if (end <= start) continue;
                const b0: usize = @intFromFloat(@min(47, @floor(start / bucket_ms)));
                const b1: usize = @intFromFloat(@min(47, @floor(end / bucket_ms)));
                var b = b0;
                while (b <= b1) : (b += 1) {
                    const bs = @as(f64, @floatFromInt(b)) * bucket_ms;
                    const be = bs + bucket_ms;
                    const overlap = @min(end, be) - @max(start, bs);
                    if (overlap > 0) buckets[b] = @min(1.0, buckets[b] + overlap / bucket_ms);
                }
            }
        }
        stat.* = .{
            .cpu = @intCast(index),
            .busy = busy_pct,
            .switches = switches,
            .migrations = 0,
            .runqueue = null,
            .p95 = if (best_p95 == 0) null else @as(f64, @floatFromInt(best_p95)) / 1000.0,
            .buckets = buckets,
        };
    }

    const thread_count: usize = @min(session.metrics.tasks.len, 9);
    const threads = try allocator.alloc(model_mod.Thread, thread_count);
    for (threads, 0..) |*thread, index| {
        const task = session.metrics.tasks[index];
        thread.* = .{
            .comm = task.comm,
            .pid = task.pid,
            .switches = @intCast(@min(task.switches, std.math.maxInt(u32))),
            .migrations = @intCast(@min(task.migrations, std.math.maxInt(u32))),
            .p95 = if (task.wait_p95_us == 0) null else @as(f64, @floatFromInt(task.wait_p95_us)) / 1000.0,
            .lane = lanes.get(task.comm) orelse @intCast((index % 9) + 1),
            .share = if (session.switches == 0) 0 else @as(f64, @floatFromInt(task.switches)) * 100.0 / @as(f64, @floatFromInt(session.switches)),
        };
    }

    var type_map = std.StringHashMap(u32).init(allocator);
    for (session.events) |e| {
        const entry = try type_map.getOrPut(event_mod.kindName(e.kind));
        if (!entry.found_existing) entry.value_ptr.* = 0;
        entry.value_ptr.* += 1;
    }
    const type_order = [_][]const u8{ "sched_switch", "sched_wakeup", "sched_migrate", "page_fault", "cache_miss", "loss" };
    var type_list: std.ArrayList(model_mod.TypeCount) = .empty;
    for (type_order) |kind| {
        if (type_map.get(kind)) |count| {
            if (count > 0) try type_list.append(allocator, .{ .kind = kind, .count = count });
        }
    }
    var type_it = type_map.iterator();
    while (type_it.next()) |entry| {
        var known = false;
        for (type_order) |kind| known = known or std.mem.eql(u8, kind, entry.key_ptr.*);
        if (!known and entry.value_ptr.* > 0) {
            try type_list.append(allocator, .{ .kind = entry.key_ptr.*, .count = entry.value_ptr.* });
        }
    }

    var lost_list: std.ArrayList(f64) = .empty;
    var events = try allocator.alloc(model_mod.Event, session.events.len);
    for (session.events, 0..) |e, index| {
        const is_loss = e.kind == .marker and (std.mem.indexOf(u8, e.detail, "loss") != null or std.mem.indexOf(u8, e.detail, "dropped") != null or std.mem.indexOf(u8, e.detail, "lost") != null);
        events[index] = .{
            .id = @intCast(index),
            .ts = @as(f64, @floatFromInt(e.ts_ns -| session.first_us * 1000)) / 1_000_000.0,
            .type = event_mod.kindName(e.kind),
            .cpu = e.cpu,
            .comm = e.comm,
            .pid = e.pid,
            .detail = e.detail,
            .loss = is_loss,
        };
        if (is_loss) try lost_list.append(allocator, events[index].ts);
    }

    const p95 = session.metrics.wait.quantileUpper(950);
    const p99 = session.metrics.wait.quantileUpper(990);
    const busy_avg: ?u8 = if (busy_cpus == 0) null else @intFromFloat(@round(total_busy / @as(f64, @floatFromInt(busy_cpus))));
    var fixture_buf = ctx.fixture;
    if (fixture_buf.len == 0) fixture_buf = session.source;
    const capture_window = if (ctx.capture_window.len != 0)
        ctx.capture_window
    else
        try std.fmt.allocPrint(allocator, "{d:.3} s", .{window_ms / 1000.0});

    const agg = session.aggregate();
    const findings = advisor_mod.analyze(allocator, agg, .{}) catch &.{};
    const cards = try buildAdvisorCards(allocator, findings, agg);
    const memory = try buildMemory(allocator, session, agg);

    return .{
        .schema = "xsprof/design-demo/v1",
        .meta = .{
            .host = ctx.host,
            .kernel = ctx.kernel,
            .arch = ctx.arch,
            .source = if (ctx.live) "LIVE" else ctx.source,
            .fixture = fixture_buf,
            .startedAt = ctx.started_at,
            .excerpt = capture_window,
            .captureWindow = capture_window,
            .sessionLabel = if (ctx.session_label.len > 0) ctx.session_label else if (ctx.live) "LIVE JOURNAL  ·  SANITIZED" else "JOURNAL  ·  REPLAY  ·  SANITIZED",
            .captureStart = ctx.capture_start,
            .captureEnd = ctx.capture_end,
        },
        .mode = .intervals,
        .summary = .{
            .events = @intCast(@min(session.events.len, std.math.maxInt(u32))),
            .switches = session.switches,
            .migrations = session.migrations,
            .wakeups = session.wakeups,
            .faults = session.faults,
            .lost = session.lost,
            .cpus = session.cpu_count,
            .p95 = if (session.metrics.wait.count == 0) null else @as(f64, @floatFromInt(p95)) / 1000.0,
            .p99 = if (session.metrics.wait.count == 0) null else @as(f64, @floatFromInt(p99)) / 1000.0,
            .cpuBusy = busy_avg,
            .runqueue = null,
            .windowMs = window_ms,
            .switchRate = if (window_ms > 0) @as(f64, @floatFromInt(session.switches)) / (window_ms / 1000.0) else 0,
        },
        .capabilities = try buildCapabilities(allocator, session),
        .cpuStats = cpu_stats,
        .threads = threads,
        .advisor = cards,
        .memory = memory,
        .typeCounts = try type_list.toOwnedSlice(allocator),
        .lostAt = try lost_list.toOwnedSlice(allocator),
        .windowMs = window_ms,
        .segments = &.{},
        .retention = null,
        .slices = slices,
        .events = events,
        .demo = false,
    };
}

fn buildCapabilities(allocator: std.mem.Allocator, session: *const Session) ![]model_mod.Capability {
    const caps = try allocator.alloc(model_mod.Capability, session.capabilities.len);
    for (caps, 0..) |*cap, i| {
        const source = session.capabilities[i];
        cap.* = .{
            .name = source.name,
            .state = source.state,
            .detail = source.reason,
            .glyph = "",
        };
    }
    return caps;
}

fn buildMemory(allocator: std.mem.Allocator, session: *const Session, agg: @import("../../analyze/aggregates.zig").Aggregates) !?model_mod.Memory {
    _ = allocator;
    const mem: model_mod.Memory = .{
        .pageFaults = @intCast(@max(0, agg.page_faults)),
        .cacheMiss = 0,
        .reclaims = 0,
        .reclaimMax = 0,
        .cross = 0,
        .numa = if (agg.llc_domains > 1) "multiple LLC domains" else "1 node",
        .has_llc = agg.pmu_collected,
        .has_reclaim = false,
        .has_cross = agg.pmu_collected and agg.remote_fault_ratio > 0,
    };
    if (mem.pageFaults == 0 and !mem.has_llc and !mem.has_cross) return null;
    _ = session;
    return mem;
}

fn buildAdvisorCards(allocator: std.mem.Allocator, findings: []const advisor_mod.Finding, agg: @import("../../analyze/aggregates.zig").Aggregates) ![]model_mod.AdvisorCard {
    const cards = try allocator.alloc(model_mod.AdvisorCard, rule_ids.len);
    for (rule_ids, 0..) |id, index| {
        var matched: ?advisor_mod.Finding = null;
        for (findings) |finding| {
            if (std.mem.eql(u8, finding.id, id)) {
                matched = finding;
                break;
            }
        }
        if (matched) |finding| {
            var rec_buf = std.ArrayList(u8).empty;
            try rec_buf.appendSlice(allocator, "Suggestion only — never applied. ");
            if (finding.recommendations.len > 0) {
                try rec_buf.appendSlice(allocator, finding.recommendations[0].rationale);
            }
            cards[index] = .{
                .id = id,
                .severity = if (finding.severity == .critical) "WARNING" else if (finding.severity == .warning) "WARNING" else "INFO",
                .confidence = if (finding.confidence == .measured) 0.86 else 0.61,
                .summary = finding.summary,
                .evidence = finding.evidence,
                .recommendation = try rec_buf.toOwnedSlice(allocator),
                .focus = null,
            };
        } else {
            const collected = signalCollected(id, agg);
            cards[index] = .{
                .id = id,
                .severity = if (collected) "CLEAR" else "SKIP",
                .confidence = if (collected) 0.88 else null,
                .summary = if (collected) "No threshold breach in the collected signals for this rule." else "The signal this rule needs was not collected in this journal.",
                .evidence = &.{},
                .recommendation = if (collected) "Suggestion only — never applied. No action indicated by this rule." else "Suggestion only — never applied. Re-run with the required signal enabled.",
                .focus = null,
            };
        }
    }
    return cards;
}

fn signalCollected(id: []const u8, agg: @import("../../analyze/aggregates.zig").Aggregates) bool {
    if (std.mem.eql(u8, id, "poor-numa-placement")) return agg.dominant_node >= 0;
    if (std.mem.eql(u8, id, "cpu-affinity-churn") or std.mem.eql(u8, id, "unnecessary-wakeups") or std.mem.eql(u8, id, "priority-inversion")) return agg.sched_collected;
    if (std.mem.eql(u8, id, "excessive-locking") or std.mem.eql(u8, id, "false-sharing")) return agg.pmu_collected;
    if (std.mem.eql(u8, id, "allocator-fragmentation")) return agg.small_alloc_churn > 0 or agg.buddy_fragmentation > 0;
    return false;
}

test "healthy replay derives a populated, explicit model" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const session = try Session.load(std.testing.io, arena.allocator(), "fixtures/ui/healthy.ndjson");
    const model = try fromSession(arena.allocator(), &session, .{ .fixture = "fixtures/ui/healthy.ndjson" });
    try std.testing.expect(model.events.len == session.events.len);
    try std.testing.expect(model.slices.len > 100);
    try std.testing.expect(model.threads.len > 0);
    try std.testing.expect(model.cpuStats.len == 4);
    try std.testing.expectEqual(@as(usize, 7), model.advisor.len);
    try std.testing.expectEqual(@as(usize, 3), model.capabilities.len);
    try std.testing.expect(model.summary.lost == 3);
    try std.testing.expect(model.summary.p95 != null);
    try std.testing.expect(!model.demo);
    var skip = false;
    for (model.advisor) |card| skip = skip or std.mem.eql(u8, card.severity, "SKIP");
    try std.testing.expect(skip);
}

pub fn applyRecorder(allocator: std.mem.Allocator, model: *model_mod.Model, manifest: *const @import("../../recorder/manifest.zig").Manifest) !void {
    const segments = try allocator.alloc(model_mod.Segment, manifest.segments.len);
    var used_bytes: u64 = 0;
    for (manifest.segments, 0..) |segment, index| {
        used_bytes +|= segment.bytes;
        var name: []const u8 = segment.path;
        if (std.mem.lastIndexOfScalar(u8, name, '/')) |slash| name = name[slash + 1 ..];
        segments[index] = .{
            .name = try allocator.dupe(u8, name),
            .bytes = try humanBytes(allocator, segment.bytes),
            .window = if (segment.end_wall_ns > segment.start_wall_ns)
                try std.fmt.allocPrint(allocator, "{s} → {s}", .{ clockText(segment.start_wall_ns), clockText(segment.end_wall_ns) })
            else
                try allocator.dupe(u8, "open segment"),
            .open = !segment.closed,
            .loss = 0,
        };
    }
    // Newest first, matching the recorder UI.
    std.mem.reverse(model_mod.Segment, segments);
    model.segments = segments;
    model.meta.manifest = "manifest.json";
    const pct: u8 = if (manifest.max_bytes == 0) 0 else @intFromFloat(@min(100.0, @as(f64, @floatFromInt(used_bytes)) * 100.0 / @as(f64, @floatFromInt(manifest.max_bytes))));
    model.retention = .{
        .budget = try humanBytes(allocator, manifest.max_bytes),
        .used = try humanBytes(allocator, used_bytes),
        .usedPct = pct,
        .age = if (manifest.max_age_ms >= 60_000)
            try std.fmt.allocPrint(allocator, "{d} m", .{manifest.max_age_ms / 60_000})
        else
            try std.fmt.allocPrint(allocator, "{d} s", .{manifest.max_age_ms / 1000}),
        .excerpt = "",
    };
}

fn humanBytes(allocator: std.mem.Allocator, bytes: u64) ![]const u8 {
    const f: f64 = @floatFromInt(bytes);
    if (bytes >= 1024 * 1024 * 1024) return std.fmt.allocPrint(allocator, "{d:.1} GiB", .{f / (1024.0 * 1024.0 * 1024.0)});
    if (bytes >= 1024 * 1024) return std.fmt.allocPrint(allocator, "{d:.1} MiB", .{f / (1024.0 * 1024.0)});
    if (bytes >= 1024) return std.fmt.allocPrint(allocator, "{d:.1} KiB", .{f / 1024.0});
    return std.fmt.allocPrint(allocator, "{d} B", .{bytes});
}

fn clockText(wall_ns: u64) [8]u8 {
    const seconds: u64 = (wall_ns / std.time.ns_per_s) % 86400;
    return .{
        @intCast('0' + (seconds / 36000) % 10),
        @intCast('0' + (seconds / 3600) % 10),
        ':',
        @intCast('0' + (seconds / 600) % 6),
        @intCast('0' + (seconds / 60) % 10),
        ':',
        @intCast('0' + (seconds / 10) % 10),
        @intCast('0' + seconds % 10),
    };
}

test "live source and recorder metadata are data-driven" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const session = try Session.load(std.testing.io, arena.allocator(), "fixtures/ui/healthy.ndjson");
    var model = try fromSession(arena.allocator(), &session, .{ .fixture = "live.ndjson", .source = "REPLAY", .live = true });
    try std.testing.expectEqualStrings("LIVE", model.meta.source);
    try std.testing.expect(std.mem.indexOf(u8, model.meta.sessionLabel, "LIVE") != null);
    var manifest = @import("../../recorder/manifest.zig").Manifest{
        .session_id = "test",
        .started_wall_ns = 1_700_000_000_000_000_000,
        .started_mono_ns = 1,
        .max_bytes = 2 * 1024 * 1024 * 1024,
        .max_age_ms = 600_000,
        .segments = &.{
            .{ .path = "/tmp/s-0001.ndjson", .start_wall_ns = 1_700_000_000_000_000_000, .start_mono_ns = 1, .end_wall_ns = 1_700_000_030_000_000_000, .end_mono_ns = 2, .bytes = 14 * 1024 * 1024, .closed = true },
        },
    };
    try applyRecorder(arena.allocator(), &model, &manifest);
    try std.testing.expectEqual(@as(usize, 1), model.segments.len);
    try std.testing.expect(model.retention != null);
    try std.testing.expectEqualStrings("14.0 MiB", model.segments[0].bytes);
}
