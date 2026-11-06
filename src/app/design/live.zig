//! OS-free live controller for native view-only streaming.
//!
//! The controller owns a bounded NDJSON feed, an incremental `stream/index`
//! index, and a rebuild cadence; sources are injected through a vtable so this
//! file never imports capture/OS code:
//!   - Linux `src/platform/linux/live_source.zig` wraps `capture/lab_worker`
//!     (bounded duration chunks, probe-gated READY/SKIP/REFUSE).
//!   - `src/platform/follow_source.zig` tails a recorder directory on any OS.
//!
//! Integration hook for the app shell (ui-arch owns app.zig): construct this in
//! App after the canvas, call `start()` on an explicit user action (never
//! automatically), call `poll(now_ms, Selection)` from the tick, and apply the
//! returned `Selection`/window deltas. `view()` borrows the current model until
//! the next rebuild; copy or re-read it each frame, never store the pointer.
//! Selection is remapped inside the rebuild while the old model is still
//! alive, which is why `poll` takes and returns it.

const std = @import("std");
const event_mod = @import("../../core/event.zig");
const live_feed = @import("../../stream/live_feed.zig");
const stream_store = @import("../../stream/store.zig");
const stream_index = @import("../../stream/index.zig");
const session_mod = @import("../../stream/session.zig");
const derive = @import("derive.zig");
const model_mod = @import("model.zig");

const Model = model_mod.Model;
const Session = session_mod.Session;

pub const State = enum { off, probing, starting, ready, stopped, degraded, skip, refuse, failed };

pub const Status = struct {
    state: State = .off,
    reason: []const u8 = "",
};

pub const SourceStats = struct {
    events: u64 = 0,
    lost: u64 = 0,
    failed: bool = false,
    /// A bounded source (for example a recording capture) finished on its own;
    /// the controller reports `stopped` instead of leaving the UI on RUNNING.
    finished: bool = false,
};

pub const Unavailable = struct {
    state: State,
    reason: []const u8,
};

pub const StartResult = union(enum) {
    running,
    unavailable: Unavailable,
};

pub const SourceOptions = struct {
    /// 0 = continuous bounded chunks (source chooses). A non-zero value bounds
    /// a smoke/test capture.
    duration_ms: u32 = 0,
    preset: []const u8 = "scheduler",
};

pub const VTable = struct {
    start: *const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        io: std.Io,
        feed: *live_feed.Store,
        options: SourceOptions,
    ) StartResult,
    stop: *const fn (ctx: *anyopaque) void,
    /// Called once per controller poll. Sources that chain bounded workers
    /// (lab_worker has no unbounded mode) restart here.
    tick: *const fn (ctx: *anyopaque, io: std.Io) void,
    stats: *const fn (ctx: *anyopaque) SourceStats,
};

pub const Source = struct {
    context: *anyopaque,
    vtable: *const VTable,
};

pub const Options = struct {
    max_feed_bytes: usize = 8 * 1024 * 1024,
    max_store_bytes: usize = 64 * 1024 * 1024,
    /// Hard cap on indexed events; beyond it the controller stops indexing and
    /// emits one loss marker (never silently truncates).
    max_events: usize = 200_000,
    rebuild_interval_ms: u64 = 250,
};

pub const Selection = struct {
    slice: ?u32 = null,
    event: ?usize = null,
};

pub const PollResult = struct {
    changed: bool = false,
    selection: Selection = .{},
    previous_window_ms: f64 = 0,
    window_ms: f64 = 0,
};

pub const Controller = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
    feed: live_feed.Store,
    store: stream_store.Store,
    index: stream_index.Index,
    arena: std.heap.ArenaAllocator,
    model: ?Model = null,
    session: ?Session = null,
    source: ?Source = null,
    source_options: SourceOptions = .{},
    status: Status = .{},
    started: bool = false,
    feed_offset: u64 = 0,
    indexed_events: usize = 0,
    pending_rebuild: bool = false,
    overflow_marker_sent: bool = false,
    last_rebuild_ms: u64 = 0,
    rebuilds: u64 = 0,
    source_events: u64 = 0,
    source_lost: u64 = 0,
    rejected: u64 = 0,
    loss_allocations: std.ArrayList([]u8) = .empty,
    capability_allocations: std.ArrayList([]u8) = .empty,
    loss_buf: [128]u8 = @splat(0),

    pub fn init(allocator: std.mem.Allocator, io: std.Io, options: Options) Controller {
        var feed = live_feed.Store.init();
        feed.max_bytes = options.max_feed_bytes;
        var store = stream_store.Store.init(allocator);
        store.max_bytes = options.max_store_bytes;
        return .{
            .allocator = allocator,
            .io = io,
            .options = options,
            .feed = feed,
            .store = store,
            .index = stream_index.Index.init(allocator),
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *Controller) void {
        self.stop();
        self.freeAllocations(&self.loss_allocations);
        self.freeAllocations(&self.capability_allocations);
        self.feed.deinit();
        self.store.deinit();
        self.index.deinit();
        self.arena.deinit();
    }

    fn freeAllocations(self: *Controller, list: *std.ArrayList([]u8)) void {
        for (list.items) |owned| self.allocator.free(owned);
        list.deinit(self.allocator);
    }

    pub fn attach(self: *Controller, source: Source, source_options: SourceOptions) void {
        self.source = source;
        self.source_options = source_options;
    }

    /// Explicit start only. A source that cannot run reports SKIP/REFUSE and
    /// publishes a canonical capability marker for the console.
    pub fn start(self: *Controller) bool {
        if (self.started) return true;
        const source = self.source orelse {
            self.status = .{ .state = .failed, .reason = "no live source attached" };
            return false;
        };
        self.status = .{ .state = .starting };
        const result = source.vtable.start(
            source.context,
            self.allocator,
            self.io,
            &self.feed,
            self.source_options,
        );
        switch (result) {
            .running => {
                self.started = true;
                self.status = .{ .state = .ready, .reason = "live capture running" };
                return true;
            },
            .unavailable => |unavailable| {
                self.started = false;
                self.status = .{ .state = unavailable.state, .reason = unavailable.reason };
                self.publishCapability(unavailable.state, unavailable.reason);
                return false;
            },
        }
    }

    pub fn stop(self: *Controller) void {
        if (self.source) |source| source.vtable.stop(source.context);
        if (self.started) self.status = .{ .state = .stopped, .reason = "live capture stopped" };
        self.started = false;
    }

    /// Restarts from a clean bounded state; the caller keeps UI view/selection.
    pub fn restart(self: *Controller) bool {
        self.stop();
        self.resetPipeline();
        return self.start();
    }

    fn resetPipeline(self: *Controller) void {
        self.freeAllocations(&self.loss_allocations);
        self.loss_allocations = .empty;
        self.freeAllocations(&self.capability_allocations);
        self.capability_allocations = .empty;
        self.feed.deinit();
        self.feed = live_feed.Store.init();
        self.feed.max_bytes = self.options.max_feed_bytes;
        self.store.deinit();
        self.store = stream_store.Store.init(self.allocator);
        self.store.max_bytes = self.options.max_store_bytes;
        self.index.deinit();
        self.index = stream_index.Index.init(self.allocator);
        self.arena.deinit();
        self.arena = std.heap.ArenaAllocator.init(self.allocator);
        self.model = null;
        self.session = null;
        self.feed_offset = 0;
        self.indexed_events = 0;
        self.pending_rebuild = false;
        self.overflow_marker_sent = false;
        self.last_rebuild_ms = 0;
        self.rebuilds = 0;
        self.source_events = 0;
        self.source_lost = 0;
        self.rejected = 0;
        self.status = .{};
    }

    /// Borrowed model for the current frame (valid until the next rebuild).
    pub fn view(self: *Controller) ?*const Model {
        if (self.model) |*model| return model;
        return null;
    }

    pub fn sessionView(self: *Controller) ?*const Session {
        if (self.session) |*session| return session;
        return null;
    }

    pub fn statusView(self: *const Controller) Status {
        return self.status;
    }

    pub fn statsView(self: *const Controller) struct { events: u64, lost: u64, rebuilds: u64, source_events: u64 } {
        return .{
            .events = self.index.events.items.len,
            .lost = self.index.lost,
            .rebuilds = self.rebuilds,
            .source_events = self.source_events,
        };
    }

    /// Consumes the feed, indexes new events, and rebuilds at most every
    /// `rebuild_interval_ms`. Returns the remapped selection when the model
    /// changed, so the shell can apply both atomically.
    pub fn poll(self: *Controller, now_ms: u64, selection: Selection) PollResult {
        var result = PollResult{ .selection = selection };
        if (!self.started) return result;
        if (self.source) |source| source.vtable.tick(source.context, self.io);
        self.consume();
        if (self.source) |source| {
            const stats = source.vtable.stats(source.context);
            self.source_events = stats.events;
            self.source_lost = stats.lost;
            if (stats.failed) {
                self.status = .{ .state = .failed, .reason = "capture worker failed" };
                self.started = false;
            } else if (stats.finished and self.status.state == .ready) {
                self.status = .{ .state = .stopped, .reason = "live source finished" };
                self.started = false;
            }
        }
        if (!self.pending_rebuild) {
            result.window_ms = if (self.model) |model| model.summary.windowMs else 0;
            result.previous_window_ms = result.window_ms;
            return result;
        }
        if (self.rebuilds != 0 and now_ms < self.last_rebuild_ms + self.options.rebuild_interval_ms) {
            result.window_ms = if (self.model) |model| model.summary.windowMs else 0;
            result.previous_window_ms = result.window_ms;
            return result;
        }
        return self.rebuild(now_ms, selection);
    }

    fn consume(self: *Controller) void {
        const snapshot = self.feed.since(self.allocator, self.feed_offset) catch return;
        defer self.allocator.free(snapshot.data);
        if (snapshot.reset) {
            const gap = if (snapshot.start > self.feed_offset) snapshot.start - self.feed_offset else 1;
            _ = self.emitLoss(gap, "feed_trim");
            self.feed_offset = snapshot.start;
        }
        if (snapshot.data.len == 0) return;
        _ = self.store.append(snapshot.data) catch |err| {
            self.feed_offset = snapshot.end;
            self.rejected += 1;
            switch (err) {
                error.InvalidJournal => {
                    _ = self.emitLoss(1, "corrupt_line");
                },
                error.StoreFull => {
                    self.status = .{ .state = .degraded, .reason = "live store full; indexing stopped" };
                    _ = self.emitLoss(1, "store_full");
                },
                else => self.status = .{ .state = .degraded, .reason = "live store append failed" },
            }
            return;
        };
        self.feed_offset = snapshot.end;

        if (self.indexed_events >= self.store.events.items.len) return;
        const new_events = self.store.events.items[self.indexed_events..];
        const remaining = self.options.max_events -| self.indexed_events;
        const take = @min(new_events.len, remaining);
        if (take != 0) {
            self.index.append(new_events[0..take]) catch {
                self.status = .{ .state = .degraded, .reason = "live index append failed" };
                return;
            };
            self.indexed_events += take;
            self.pending_rebuild = true;
        }
        if (take < new_events.len) {
            if (!self.overflow_marker_sent) {
                self.overflow_marker_sent = true;
                _ = self.emitLoss(new_events.len - take, "event_cap");
                if (self.status.state == .ready) {
                    self.status = .{ .state = .degraded, .reason = "live event cap reached; index is bounded" };
                }
            }
            self.indexed_events = self.store.events.items.len;
        }
    }

    fn rebuild(self: *Controller, now_ms: u64, selection: Selection) PollResult {
        var result = PollResult{ .selection = selection };
        var next = std.heap.ArenaAllocator.init(self.allocator);
        const arena = next.allocator();
        var session = self.index.snapshot(arena, "live capture") catch {
            next.deinit();
            self.status = .{ .state = .degraded, .reason = "live snapshot failed" };
            self.last_rebuild_ms = now_ms;
            return result;
        };
        const model = derive.fromSession(arena, &session, .{
            .host = "live",
            .source = "LIVE",
            .fixture = "live stream",
            .live = true,
        }) catch {
            next.deinit();
            self.status = .{ .state = .degraded, .reason = "live model rebuild failed" };
            self.last_rebuild_ms = now_ms;
            return result;
        };
        const previous_window = if (self.model) |previous| previous.summary.windowMs else 0;
        if (self.model) |*previous| {
            result.selection = .{
                .slice = remapSlice(previous, selection.slice, &model),
                .event = remapEvent(previous, selection.event, &model),
            };
        }
        self.arena.deinit();
        self.arena = next;
        self.model = model;
        self.session = session;
        self.rebuilds += 1;
        self.last_rebuild_ms = now_ms;
        self.pending_rebuild = false;
        result.changed = true;
        result.previous_window_ms = previous_window;
        result.window_ms = model.summary.windowMs;
        return result;
    }

    fn emitLoss(self: *Controller, dropped: u64, reason: []const u8) bool {
        const text = std.fmt.bufPrint(
            &self.loss_buf,
            "sample_loss live_ui dropped={d} reason={s}",
            .{ dropped, reason },
        ) catch "sample_loss live_ui dropped=1";
        const owned = self.allocator.dupe(u8, text) catch return false;
        self.loss_allocations.append(self.allocator, owned) catch {
            self.allocator.free(owned);
            return false;
        };
        self.index.append(&.{event_mod.RawEvent{
            .kind = .marker,
            .ts_ns = @intCast(@max(0, std.Io.Clock.now(.awake, self.io).nanoseconds)),
            .cpu = -1,
            .detail = owned,
        }}) catch return false;
        return true;
    }

    fn publishCapability(self: *Controller, state: State, reason: []const u8) void {
        var buffer: [256]u8 = undefined;
        const text = std.fmt.bufPrint(
            &buffer,
            "live_capture:{s}:{s}",
            .{ @tagName(state), if (reason.len == 0) "unavailable" else reason },
        ) catch "live_capture:SKIP:unavailable";
        const owned = self.allocator.dupe(u8, text) catch return;
        self.capability_allocations.append(self.allocator, owned) catch {
            self.allocator.free(owned);
            return;
        };
        self.index.append(&.{event_mod.RawEvent{
            .kind = .capability,
            .ts_ns = @intCast(@max(0, std.Io.Clock.now(.awake, self.io).nanoseconds)),
            .cpu = -1,
            .detail = owned,
        }}) catch {};
    }
};

/// Stable-key remap for slice selection; ids are positional and the index
/// unstable-sorts slices, so only the tuple is trusted.
pub fn remapSlice(previous: *const Model, selection: ?u32, next: *const Model) ?u32 {
    const index = selection orelse return null;
    if (index >= previous.slices.len) return null;
    const old = previous.slices[index];
    for (next.slices, 0..) |candidate, at| {
        if (candidate.cpu != old.cpu) continue;
        if (candidate.pid != old.pid) continue;
        if (candidate.start != old.start) continue;
        if (candidate.dur != old.dur) continue;
        if (!std.mem.eql(u8, candidate.comm, old.comm)) continue;
        return @intCast(at);
    }
    return null;
}

pub fn remapEvent(previous: *const Model, selection: ?usize, next: *const Model) ?usize {
    const index = selection orelse return null;
    if (index >= previous.events.len) return null;
    const old = previous.events[index];
    for (next.events, 0..) |candidate, at| {
        if (candidate.ts != old.ts) continue;
        if (candidate.cpu != old.cpu) continue;
        if (candidate.pid != old.pid) continue;
        if (!std.mem.eql(u8, candidate.type, old.type)) continue;
        if (!std.mem.eql(u8, candidate.comm, old.comm)) continue;
        return at;
    }
    return null;
}

test {
    _ = @import("live_test.zig");
}
