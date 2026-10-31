//! Off-thread bounded capture for the GUI lab. The worker owns one
//! `live.Capture`, serializes canonical NDJSON into a `live_feed.Store`, and
//! never mutates host policy. The UI only reads atomics and feed offsets.

const std = @import("std");
const builtin = @import("builtin");
const live = @import("live.zig");
const event = @import("../core/event.zig");
const live_feed = @import("../stream/live_feed.zig");

pub const Options = struct {
    duration_ms: u32 = 1000,
    preset: live.Preset = .scheduler,
};

pub const Stats = struct {
    events: u64 = 0,
    lost: u64 = 0,
    finished: bool = false,
    failed: bool = false,
};

pub const Unavailable = struct {
    state: live.State,
    reason: []const u8,
};

pub const Start = union(enum) {
    running: *Worker,
    unavailable: Unavailable,
};

pub const Worker = struct {
    allocator: std.mem.Allocator,
    feed: *live_feed.Store,
    capture: *live.Capture,
    options: Options,
    thread: ?std.Thread = null,
    stop_flag: std.atomic.Value(bool) = .init(false),
    events: std.atomic.Value(u64) = .init(0),
    lost: std.atomic.Value(u64) = .init(0),
    finished: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),

    pub fn start(
        io: std.Io,
        allocator: std.mem.Allocator,
        feed: *live_feed.Store,
        options: Options,
    ) !Start {
        if (builtin.os.tag != .linux) {
            return .{ .unavailable = .{
                .state = .SKIP,
                .reason = "non-Linux host: perf_event_open unavailable",
            } };
        }
        const probe = try live.probe(io, allocator);
        if (probe.state != .READY) {
            return .{ .unavailable = .{ .state = probe.state, .reason = probe.reason } };
        }
        const root = live.tracefsRoot(io) orelse {
            return .{ .unavailable = .{ .state = .REFUSE, .reason = "tracefs sched events unreadable" } };
        };
        const capture = try allocator.create(live.Capture);
        capture.* = live.openReady(io, allocator, live.presetOptions(options.preset), root) catch |err| {
            allocator.destroy(capture);
            return .{ .unavailable = .{
                .state = if (err == error.TracepointUnavailable) .REFUSE else .SKIP,
                .reason = switch (err) {
                    error.TracepointUnavailable => "sched tracepoints unavailable",
                    error.NoEvents => "no perf events could be opened",
                    else => "capture could not start",
                },
            } };
        };
        const worker = allocator.create(Worker) catch |err| {
            capture.deinit();
            allocator.destroy(capture);
            return err;
        };
        worker.* = .{
            .allocator = allocator,
            .feed = feed,
            .capture = capture,
            .options = options,
        };
        worker.thread = std.Thread.spawn(.{}, run, .{ worker, io }) catch |err| {
            capture.deinit();
            allocator.destroy(capture);
            allocator.destroy(worker);
            return err;
        };
        return .{ .running = worker };
    }

    pub fn stop(self: *Worker) Stats {
        self.stop_flag.store(true, .release);
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        return self.stats();
    }

    pub fn stats(self: *const Worker) Stats {
        return .{
            .events = self.events.load(.acquire),
            .lost = self.lost.load(.acquire),
            .finished = self.finished.load(.acquire),
            .failed = self.failed.load(.acquire),
        };
    }

    pub fn destroy(self: *Worker) void {
        _ = self.stop();
        self.capture.deinit();
        self.allocator.destroy(self.capture);
        self.allocator.destroy(self);
    }

    fn run(self: *Worker, io: std.Io) void {
        defer self.finished.store(true, .release);
        var batch: std.ArrayList(u8) = .empty;
        defer batch.deinit(self.allocator);
        const deadline = std.Io.Clock.now(.awake, io).nanoseconds +
            @as(i96, @intCast(self.options.duration_ms)) * std.time.ns_per_ms;
        while (!self.stop_flag.load(.acquire)) {
            const now = std.Io.Clock.now(.awake, io).nanoseconds;
            if (now >= deadline) break;
            const remaining_ns = deadline - now;
            const timeout_ms: u32 = @intCast(@min(
                @divTrunc(remaining_ns, std.time.ns_per_ms),
                self.capture.opts.poll_timeout_ms,
            ));
            _ = self.capture.poll(@max(1, timeout_ms)) catch {
                self.failed.store(true, .release);
                return;
            };
            var taken = self.capture.take() catch {
                self.failed.store(true, .release);
                return;
            };
            defer taken.deinit();
            for (taken.events) |entry| {
                if (!appendEvent(&batch, self.allocator, entry)) {
                    self.failed.store(true, .release);
                    return;
                }
                _ = self.events.fetchAdd(1, .monotonic);
                if (batch.items.len >= 64 * 1024) flush(self.feed, &batch);
            }
            if (taken.lost != 0) {
                var detail_buf: [96]u8 = undefined;
                const detail = std.fmt.bufPrint(
                    &detail_buf,
                    "sample_loss lab_worker lost={d}",
                    .{taken.lost},
                ) catch "sample_loss lab_worker";
                if (!appendEvent(&batch, self.allocator, .{
                    .kind = .marker,
                    .ts_ns = @intCast(std.Io.Clock.now(.awake, io).nanoseconds),
                    .cpu = -1,
                    .detail = detail,
                })) {
                    self.failed.store(true, .release);
                    return;
                }
                _ = self.lost.fetchAdd(taken.lost, .monotonic);
            }
        }
        flush(self.feed, &batch);
        self.lost.store(self.capture.lost, .release);
    }
};

fn appendEvent(
    batch: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    entry: event.RawEvent,
) bool {
    var line_buffer: [2048]u8 = undefined;
    var line = std.Io.Writer.fixed(&line_buffer);
    event.writeJson(&line, entry) catch return false;
    line.writeByte('\n') catch return false;
    batch.appendSlice(allocator, line.buffered()) catch return false;
    return true;
}

fn flush(feed: *live_feed.Store, batch: *std.ArrayList(u8)) void {
    if (batch.items.len == 0) return;
    feed.append(batch.items);
    batch.clearRetainingCapacity();
}

// Checks that a lab worker fails closed off Linux.
test "capture worker reports SKIP off Linux" {
    if (builtin.os.tag != .linux) {
        var feed = live_feed.Store.init();
        defer feed.deinit();
        const result = try Worker.start(
            std.testing.io,
            std.testing.allocator,
            &feed,
            .{ .duration_ms = 10 },
        );
        switch (result) {
            .unavailable => |unavailable| {
                try std.testing.expectEqual(live.State.SKIP, unavailable.state);
                try std.testing.expect(unavailable.reason.len != 0);
            },
            .running => |worker| {
                worker.destroy();
                return error.TestUnexpectedResult;
            },
        }
    }
}
