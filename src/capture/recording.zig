//! One-shot and streaming recording wrappers over the long-lived capture.
//! The daemon and serve paths use recordStream so batches never accumulate.

const std = @import("std");
const live = @import("live.zig");
const event = @import("../core/event.zig");
const session_meta = @import("session_meta.zig");

pub const Result = live.Result;
pub const State = live.State;
pub const Options = live.Options;

/// Record for a bounded duration and return every event. Intended for tests
/// and short captures; long-lived callers use recordStream.
pub fn record(
    io: std.Io,
    allocator: std.mem.Allocator,
    duration_ms: u32,
) !Result {
    return recordWithOptions(io, allocator, duration_ms, .{});
}

pub fn recordWithOptions(
    io: std.Io,
    allocator: std.mem.Allocator,
    duration_ms: u32,
    opts: live.Options,
) !Result {
    if (!live.live_linux) {
        return .{ .state = .SKIP, .reason = "non-Linux host: perf_event_open unavailable" };
    }
    var probe_result = try live.probeWithOptions(io, allocator, opts);
    if (probe_result.state != .READY and probe_result.state != .DEGRADED) return probe_result;
    const root = live.tracefsRoot(io) orelse return .{
        .state = .REFUSE,
        .reason = "tracefs disappeared",
    };

    var capture = live.openReady(io, allocator, opts, root) catch |err| switch (err) {
        error.TracepointUnavailable => return .{
            .state = .REFUSE,
            .reason = "sched tracepoints unavailable",
        },
        error.NoEvents => return .{
            .state = .SKIP,
            .reason = "no perf events could be opened",
        },
        else => return err,
    };
    defer capture.deinit();

    const deadline = std.Io.Clock.now(.awake, io).nanoseconds +
        @as(i96, duration_ms) * std.time.ns_per_ms;
    var output: std.ArrayList(event.RawEvent) = .empty;
    errdefer output.deinit(allocator);
    const meta = session_meta.collect(io, allocator) catch &.{};
    try output.appendSlice(allocator, meta);
    const now_ns = @as(u64, @intCast(@max(0, std.Io.Clock.now(.awake, io).nanoseconds)));
    const coverage_events = capture.coverage.events(allocator, now_ns) catch &.{};
    try output.appendSlice(allocator, coverage_events);

    while (std.Io.Clock.now(.awake, io).nanoseconds < deadline) {
        const remaining_ns = deadline - std.Io.Clock.now(.awake, io).nanoseconds;
        const timeout_ms: u32 = @intCast(@min(
            @divTrunc(remaining_ns, std.time.ns_per_ms),
            std.math.maxInt(u32),
        ));
        _ = try capture.poll(@min(timeout_ms, capture.opts.poll_timeout_ms));
        var batch = try capture.take();
        defer batch.deinit();
        for (batch.events) |entry| {
            try output.append(allocator, try copyEvent(allocator, entry));
        }
    }

    probe_result.events = try output.toOwnedSlice(allocator);
    probe_result.lost = capture.lost;
    probe_result.cpus = capture.cpus;
    probe_result.duration_ms = duration_ms;
    probe_result.coverage = capture.coverage;
    if (capture.coverage.state() == .DEGRADED) probe_result.state = .DEGRADED;
    return probe_result;
}

/// Stream a capture to a sink. The sink must copy or serialize each event
/// before returning; the batch arena is released after the callback.
pub fn recordStream(
    io: std.Io,
    allocator: std.mem.Allocator,
    duration_ms: u32,
    opts: Options,
    sink: anytype,
) !Result {
    if (!live.live_linux) {
        return .{ .state = .SKIP, .reason = "non-Linux host: perf_event_open unavailable" };
    }
    var probe_result = try live.probeWithOptions(io, allocator, opts);
    if (probe_result.state != .READY and probe_result.state != .DEGRADED) return probe_result;
    const root = live.tracefsRoot(io) orelse return .{
        .state = .REFUSE,
        .reason = "tracefs disappeared",
    };

    var capture = live.openReady(io, allocator, opts, root) catch |err| switch (err) {
        error.TracepointUnavailable, error.NoEvents => return .{
            .state = .SKIP,
            .reason = "sched tracepoints unavailable",
        },
        else => return err,
    };
    defer capture.deinit();

    const meta = session_meta.collect(io, allocator) catch &.{};
    for (meta) |entry| try sink.emit(entry);
    const now_ns = @as(u64, @intCast(@max(0, std.Io.Clock.now(.awake, io).nanoseconds)));
    const coverage_events = capture.coverage.events(allocator, now_ns) catch &.{};
    for (coverage_events) |entry| try sink.emit(entry);

    const deadline = std.Io.Clock.now(.awake, io).nanoseconds +
        @as(i96, duration_ms) * std.time.ns_per_ms;
    while (std.Io.Clock.now(.awake, io).nanoseconds < deadline) {
        const remaining_ns = deadline - std.Io.Clock.now(.awake, io).nanoseconds;
        const timeout_ms: u32 = @intCast(@min(
            @divTrunc(remaining_ns, std.time.ns_per_ms),
            std.math.maxInt(u32),
        ));
        _ = try capture.poll(@min(timeout_ms, opts.poll_timeout_ms));
        var batch = try capture.take();
        defer batch.deinit();
        for (batch.events) |entry| try sink.emit(entry);
    }
    probe_result.lost = capture.lost;
    probe_result.cpus = capture.cpus;
    probe_result.duration_ms = duration_ms;
    probe_result.coverage = capture.coverage;
    if (capture.coverage.state() == .DEGRADED) probe_result.state = .DEGRADED;
    return probe_result;
}

fn copyEvent(allocator: std.mem.Allocator, source: event.RawEvent) !event.RawEvent {
    var copy = source;
    if (source.comm.len != 0) copy.comm = try allocator.dupe(u8, source.comm);
    if (source.detail.len != 0) copy.detail = try allocator.dupe(u8, source.detail);
    return copy;
}

// Checks that short recording still fails closed off Linux.
test "record fails closed off Linux" {
    if (!live.live_linux) {
        const result = try record(std.testing.io, std.testing.allocator, 1);
        if (result.events.len != 0) std.testing.allocator.free(result.events);
        try std.testing.expectEqual(State.SKIP, result.state);
        try std.testing.expectEqual(@as(usize, 0), result.events.len);
    }
}
