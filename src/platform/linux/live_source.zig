//! Linux live source for the native console.
//!
//! Preferred mode (recorder state dir configured): one in-process recorder
//! daemon thread writes compact `.xsraw` segments for the requested duration
//! (`recorder/daemon.zig` `stop` flag, no signal handlers), while a
//! `follow_source` tail re-serializes those segments into the bounded live feed
//! for the view-only controller. Stop sets the flag, joins the daemon, then
//! stops the tail. This is one capture producing both a recording and a live
//! view; nothing silently claims recording when the daemon cannot start.
//!
//! Fallback mode (no recorder dir): `capture/lab_worker` bounded chunks feed
//! the same store, view-only. That is reported to the user as view-only.

const std = @import("std");
const builtin = @import("builtin");
const live = @import("../../capture/live.zig");
const lab_worker = @import("../../capture/lab_worker.zig");
const recorder_daemon = @import("../../recorder/daemon.zig");
const live_feed = @import("../../stream/live_feed.zig");
const live_mod = @import("../../app/design/live.zig");
const follow_source = @import("../follow_source.zig");

pub const Source = struct {
    allocator: std.mem.Allocator = undefined,
    io: std.Io = undefined,
    feed: ?*live_feed.Store = null,
    options: live_mod.SourceOptions = .{},
    /// Non-empty enables recording mode (daemon + tail); empty is view-only.
    dir: []const u8 = "",
    view_only: bool = true,
    worker: ?*lab_worker.Worker = null,
    daemon_thread: ?std.Thread = null,
    daemon_stop: std.atomic.Value(bool) = .init(false),
    daemon_done: std.atomic.Value(bool) = .init(false),
    daemon_failed: std.atomic.Value(bool) = .init(false),
    stopping: bool = false,
    follow: follow_source.Source = .{},
    totals_events: u64 = 0,
    totals_lost: u64 = 0,
    failed: bool = false,
    /// View-only chunk size (lab_worker has no unbounded mode).
    chunk_ms: u32 = 5000,
    /// Recorder duration: null means "until stop" (never silently 5 s).
    daemon_duration: ?u32 = null,
    reason_buf: [192]u8 = @splat(0),

    pub fn source(self: *Source) live_mod.Source {
        return .{ .context = @ptrCast(self), .vtable = &vtable };
    }

    pub fn reasonText(self: *const Source) []const u8 {
        const len = std.mem.indexOfScalar(u8, &self.reason_buf, 0) orelse self.reason_buf.len;
        return self.reason_buf[0..len];
    }

    fn copyReason(self: *Source, text: []const u8) void {
        @memset(&self.reason_buf, 0);
        const len = @min(text.len, self.reason_buf.len - 1);
        @memcpy(self.reason_buf[0..len], text[0..len]);
    }

    fn startImpl(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        io: std.Io,
        feed: *live_feed.Store,
        options: live_mod.SourceOptions,
    ) live_mod.StartResult {
        const self: *Source = @ptrCast(@alignCast(ctx));
        self.allocator = allocator;
        self.io = io;
        self.feed = feed;
        self.options = options;
        self.failed = false;
        self.view_only = self.dir.len == 0;
        self.stopping = false;
        self.daemon_done.store(false, .release);
        self.daemon_failed.store(false, .release);
        if (builtin.os.tag != .linux) {
            return .{ .unavailable = .{
                .state = .skip,
                .reason = "non-Linux host: perf_event_open unavailable",
            } };
        }
        const probe = live.probe(io, allocator) catch {
            return .{ .unavailable = .{ .state = .refuse, .reason = self.copyReasonText("live probe failed") } };
        };
        if (probe.state != .READY) return .{ .unavailable = .{
            .state = mapState(probe.state),
            .reason = self.copyReasonText(probe.reason),
        } };
        self.chunk_ms = if (options.duration_ms == 0) 5000 else options.duration_ms;
        self.daemon_duration = if (options.duration_ms == 0)
            null
        else
            @intCast(std.math.clamp(options.duration_ms, 1000, 600_000));
        if (!self.view_only) return self.startRecording();
        return self.startViewOnly();
    }

    fn copyReasonText(self: *Source, text: []const u8) []const u8 {
        self.copyReason(text);
        return self.reasonText();
    }

    fn startRecording(self: *Source) live_mod.StartResult {
        const feed = self.feed orelse return .{ .unavailable = .{ .state = .refuse, .reason = "no live feed" } };
        if (!self.follow.begin(self.allocator, self.io, feed, self.dir)) {
            return .{ .unavailable = .{
                .state = .refuse,
                .reason = self.copyReasonText("recorder tail could not start"),
            } };
        }
        self.daemon_stop.store(false, .release);
        self.daemon_thread = std.Thread.spawn(.{}, runDaemon, .{self}) catch {
            self.follow.stop();
            self.feed = null;
            return .{ .unavailable = .{
                .state = .refuse,
                .reason = self.copyReasonText("recorder worker thread failed"),
            } };
        };
        return .running;
    }

    fn runDaemon(self: *Source) void {
        const preset = live.parsePreset(self.options.preset) orelse .scheduler;
        const result = recorder_daemon.run(self.io, std.heap.smp_allocator, .{
            .dir = self.dir,
            .duration_ms = self.daemon_duration,
            .stop = &self.daemon_stop,
            .live_options = live.presetOptions(preset),
        }) catch |err| {
            self.copyReason(@errorName(err));
            self.daemon_failed.store(true, .release);
            self.daemon_done.store(true, .release);
            return;
        };
        if (result.state != .READY) {
            self.copyReason(if (result.reason.len != 0) result.reason else "recorder daemon refused to run");
            self.daemon_failed.store(true, .release);
        }
        self.daemon_done.store(true, .release);
    }

    fn startViewOnly(self: *Source) live_mod.StartResult {
        const feed = self.feed orelse return .{ .unavailable = .{ .state = .refuse, .reason = "no live feed" } };
        const preset = live.parsePreset(self.options.preset) orelse .scheduler;
        const result = lab_worker.Worker.start(self.io, self.allocator, feed, .{
            .duration_ms = self.chunk_ms,
            .preset = preset,
        }) catch {
            return .{ .unavailable = .{
                .state = .refuse,
                .reason = self.copyReasonText("capture worker failed to start"),
            } };
        };
        switch (result) {
            .running => |worker| {
                self.worker = worker;
                return .running;
            },
            .unavailable => |unavailable| return .{ .unavailable = .{
                .state = mapState(unavailable.state),
                .reason = self.copyReasonText(unavailable.reason),
            } },
        }
    }

    fn destroyWorker(self: *Source) void {
        const worker = self.worker orelse return;
        const stats = worker.stats();
        self.totals_events += stats.events;
        self.totals_lost += stats.lost;
        if (stats.failed) self.failed = true;
        worker.destroy();
        self.worker = null;
    }

    fn stopRecording(self: *Source) void {
        self.stopping = true;
        self.daemon_stop.store(true, .release);
        if (self.daemon_thread) |thread| {
            thread.join();
            self.daemon_thread = null;
        }
        self.follow.stop();
    }

    fn stopImpl(ctx: *anyopaque) void {
        const self: *Source = @ptrCast(@alignCast(ctx));
        if (!self.view_only) self.stopRecording() else self.destroyWorker();
        self.stopping = false;
        self.feed = null;
    }

    fn tickImpl(ctx: *anyopaque, io: std.Io) void {
        _ = io;
        const self: *Source = @ptrCast(@alignCast(ctx));
        if (!self.view_only) {
            if (self.daemon_failed.load(.acquire)) self.failed = true;
            return;
        }
        const worker = self.worker orelse return;
        const stats = worker.stats();
        if (!stats.finished) return;
        if (stats.failed) self.failed = true;
        self.destroyWorker();
        if (self.failed) return;
        const result = self.startViewOnly();
        switch (result) {
            .running => {},
            .unavailable => self.failed = true,
        }
    }

    fn statsImpl(ctx: *anyopaque) live_mod.SourceStats {
        const self: *Source = @ptrCast(@alignCast(ctx));
        if (!self.view_only) {
            const follow_stats = self.follow.stats();
            return .{
                .events = follow_stats.events,
                .lost = follow_stats.lost,
                .failed = self.failed or self.daemon_failed.load(.acquire),
                .finished = self.daemon_done.load(.acquire) and
                    !self.daemon_failed.load(.acquire) and !self.stopping,
            };
        }
        var events = self.totals_events;
        var lost = self.totals_lost;
        if (self.worker) |worker| {
            const stats = worker.stats();
            events += stats.events;
            lost += stats.lost;
            if (stats.failed) self.failed = true;
        }
        return .{ .events = events, .lost = lost, .failed = self.failed };
    }
};

fn mapState(state: live.State) live_mod.State {
    return switch (state) {
        .READY => .ready,
        .DEGRADED => .degraded,
        .SKIP => .skip,
        .REFUSE => .refuse,
    };
}

const vtable: live_mod.VTable = .{
    .start = &Source.startImpl,
    .stop = &Source.stopImpl,
    .tick = &Source.tickImpl,
    .stats = &Source.statsImpl,
};
