//! Synthetic-feed tests for the live controller: no capture, no window.
//! Kept beside live.zig (imported from its test block) so the controller
//! stays inside the repository line limit.

const std = @import("std");
const event_mod = @import("../../core/event.zig");
const live_feed = @import("../../stream/live_feed.zig");
const live = @import("live.zig");

const Controller = live.Controller;
const State = live.State;
const Selection = live.Selection;
const Unavailable = live.Unavailable;
const StartResult = live.StartResult;
const Source = live.Source;
const SourceOptions = live.SourceOptions;
const SourceStats = live.SourceStats;
const VTable = live.VTable;

const FakeSource = struct {
    feed: ?*live_feed.Store = null,
    unavailable: ?Unavailable = null,
    failed: bool = false,
    ts_ns: u64 = 0,
    emitted: u64 = 0,
    batch: u32 = 0,

    fn source(self: *FakeSource) Source {
        return .{ .context = @ptrCast(self), .vtable = &fake_vtable };
    }

    fn emit(self: *FakeSource, count: usize) void {
        const feed = self.feed orelse return;
        var index: usize = 0;
        while (index < count) : (index += 1) {
            self.ts_ns += std.time.ns_per_ms;
            const odd = (self.emitted % 2) == 1;
            var buffer: [512]u8 = undefined;
            var writer = std.Io.Writer.fixed(&buffer);
            event_mod.writeJson(&writer, .{
                .kind = .sched_switch,
                .ts_ns = self.ts_ns,
                .cpu = 0,
                .pid = if (odd) 0 else 7,
                .tid = if (odd) 0 else 7,
                .a = if (odd) 0 else 7,
                .b = if (odd) 7 else 0,
                .comm = if (odd) "idle" else "worker",
            }) catch return;
            writer.writeByte('\n') catch return;
            feed.append(writer.buffered());
            self.emitted += 1;
        }
    }
};

fn fakeStart(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    io: std.Io,
    feed: *live_feed.Store,
    options: SourceOptions,
) StartResult {
    _ = allocator;
    _ = io;
    _ = options;
    const self: *FakeSource = @ptrCast(@alignCast(ctx));
    if (self.unavailable) |unavailable| return .{ .unavailable = unavailable };
    self.feed = feed;
    return .running;
}

fn fakeStop(ctx: *anyopaque) void {
    const self: *FakeSource = @ptrCast(@alignCast(ctx));
    self.feed = null;
}

fn fakeTick(ctx: *anyopaque, io: std.Io) void {
    _ = io;
    const self: *FakeSource = @ptrCast(@alignCast(ctx));
    if (self.batch == 0) return;
    self.emit(self.batch);
    self.batch = 0;
}

fn fakeStats(ctx: *anyopaque) SourceStats {
    const self: *FakeSource = @ptrCast(@alignCast(ctx));
    return .{ .events = self.emitted, .failed = self.failed };
}

const fake_vtable: VTable = .{
    .start = &fakeStart,
    .stop = &fakeStop,
    .tick = &fakeTick,
    .stats = &fakeStats,
};

test "live controller indexes synthetic feed, rebuilds, and remaps selection" {
    var controller = Controller.init(std.testing.allocator, std.testing.io, .{ .rebuild_interval_ms = 0 });
    defer controller.deinit();
    var fake = FakeSource{};
    controller.attach(fake.source(), .{});
    try std.testing.expect(controller.start());
    try std.testing.expectEqual(State.ready, controller.statusView().state);

    fake.emit(4);
    const first = controller.poll(10, .{ .slice = 1 });
    try std.testing.expect(first.changed);
    const model = controller.view() orelse return error.TestUnexpectedResult;
    try std.testing.expect(model.events.len >= 4);
    try std.testing.expectEqualStrings("LIVE", model.meta.source);
    try std.testing.expect(model.slices.len >= 2);

    fake.emit(2);
    const second = controller.poll(500, .{ .slice = 1, .event = 0 });
    try std.testing.expect(second.changed);
    const next_model = controller.view() orelse return error.TestUnexpectedResult;
    if (second.selection.slice) |selected| {
        try std.testing.expect(selected < next_model.slices.len);
    }
    if (second.selection.event) |selected| try std.testing.expect(selected < next_model.events.len);
    try std.testing.expect(controller.statsView().rebuilds >= 2);
    try std.testing.expect(second.window_ms >= second.previous_window_ms);
}

test "unavailable source stays fail-closed and publishes a capability" {
    var controller = Controller.init(std.testing.allocator, std.testing.io, .{});
    defer controller.deinit();
    var fake = FakeSource{ .unavailable = .{ .state = .skip, .reason = "no perf permission" } };
    controller.attach(fake.source(), .{});
    try std.testing.expect(!controller.start());
    try std.testing.expectEqual(State.skip, controller.statusView().state);
    try std.testing.expectEqualStrings("no perf permission", controller.statusView().reason);
    const result = controller.poll(100, .{});
    try std.testing.expect(!result.changed);
    try std.testing.expect(controller.view() == null);
    try std.testing.expect(controller.index.capabilities.items.len == 1);
}

test "feed trim emits an explicit loss marker" {
    var controller = Controller.init(std.testing.allocator, std.testing.io, .{ .rebuild_interval_ms = 0 });
    defer controller.deinit();
    var fake = FakeSource{};
    controller.attach(fake.source(), .{});
    try std.testing.expect(controller.start());
    fake.emit(4);
    _ = controller.poll(10, .{});
    controller.feed.max_bytes = 256;
    fake.emit(8);
    const result = controller.poll(500, .{});
    try std.testing.expect(result.changed);
    const model = controller.view() orelse return error.TestUnexpectedResult;
    try std.testing.expect(model.summary.lost > 0);
}

test "event cap stays bounded and reports DEGRADED" {
    var controller = Controller.init(std.testing.allocator, std.testing.io, .{
        .rebuild_interval_ms = 0,
        .max_events = 4,
    });
    defer controller.deinit();
    var fake = FakeSource{};
    controller.attach(fake.source(), .{});
    try std.testing.expect(controller.start());
    fake.emit(10);
    const result = controller.poll(10, .{});
    try std.testing.expect(result.changed);
    const model = controller.view() orelse return error.TestUnexpectedResult;
    // 4 indexed data events plus one loss marker; the cap never grows silently.
    try std.testing.expect(model.events.len <= 5);
    try std.testing.expect(model.summary.lost > 0);
    try std.testing.expectEqual(State.degraded, controller.statusView().state);
}

test "restart clears the pipeline and can start again" {
    var controller = Controller.init(std.testing.allocator, std.testing.io, .{ .rebuild_interval_ms = 0 });
    defer controller.deinit();
    var fake = FakeSource{};
    controller.attach(fake.source(), .{});
    try std.testing.expect(controller.start());
    fake.emit(4);
    _ = controller.poll(10, .{});
    try std.testing.expect(controller.view() != null);

    try std.testing.expect(controller.restart());
    try std.testing.expect(controller.view() == null);
    try std.testing.expectEqual(@as(u64, 0), controller.statsView().rebuilds);
    try std.testing.expectEqual(State.ready, controller.statusView().state);
    fake.emit(2);
    const result = controller.poll(20, .{});
    try std.testing.expect(result.changed);

    controller.stop();
    try std.testing.expectEqual(State.stopped, controller.statusView().state);
}

test "failed worker flips the controller state" {
    var controller = Controller.init(std.testing.allocator, std.testing.io, .{});
    defer controller.deinit();
    var fake = FakeSource{};
    controller.attach(fake.source(), .{});
    try std.testing.expect(controller.start());
    fake.failed = true;
    const result = controller.poll(10, .{});
    try std.testing.expect(!result.changed);
    try std.testing.expectEqual(State.failed, controller.statusView().state);
}

test "store full stops ingest once and leaves the store untouched" {
    var controller = Controller.init(std.testing.allocator, std.testing.io, .{
        .rebuild_interval_ms = 0,
        .max_store_bytes = 64,
    });
    defer controller.deinit();
    var fake = FakeSource{};
    controller.attach(fake.source(), .{});
    try std.testing.expect(controller.start());
    fake.emit(4);
    const result = controller.poll(10, .{});
    try std.testing.expect(!result.changed);
    try std.testing.expectEqual(State.degraded, controller.statusView().state);
    try std.testing.expectEqualStrings("live store full; ingest stopped", controller.statusView().reason);
    try std.testing.expect(!controller.started);
    // The failed append is all-or-nothing: nothing was retained.
    try std.testing.expectEqual(@as(usize, 0), controller.store.eventCount());
    try std.testing.expectEqual(@as(usize, 0), controller.store.byteCount());
    try std.testing.expectEqual(@as(usize, 0), controller.store.pending.items.len);
    try std.testing.expect(controller.index.events.items.len == 1);
    try std.testing.expectEqual(@as(u64, 1), controller.lossView().markers);

    // Repeated polls cannot re-append the rejected chunk or repeat markers.
    var iteration: usize = 0;
    while (iteration < 10) : (iteration += 1) _ = controller.poll(100 + iteration, .{});
    try std.testing.expectEqual(@as(u64, 1), controller.rejected);
    try std.testing.expectEqual(@as(u64, 1), controller.lossView().markers);
    try std.testing.expect(controller.index.events.items.len == 1);
    try std.testing.expectEqual(@as(usize, 0), controller.store.pending.items.len);
    try std.testing.expectEqual(@as(usize, 0), controller.store.eventCount());
    try std.testing.expectEqualStrings("live store full; ingest stopped", controller.statusView().reason);
}

test "corrupt journal stops ingest without a partial commit" {
    var controller = Controller.init(std.testing.allocator, std.testing.io, .{ .rebuild_interval_ms = 0 });
    defer controller.deinit();
    var fake = FakeSource{};
    controller.attach(fake.source(), .{});
    try std.testing.expect(controller.start());
    // One valid line and one corrupt line arrive in the same drained chunk.
    fake.emit(1);
    controller.feed.append("{\"schema\":\"nope\"}\n");
    const result = controller.poll(10, .{});
    try std.testing.expect(!result.changed);
    try std.testing.expectEqual(State.degraded, controller.statusView().state);
    try std.testing.expectEqualStrings("live journal corrupt; ingest stopped", controller.statusView().reason);
    try std.testing.expect(!controller.started);
    try std.testing.expectEqual(@as(usize, 0), controller.store.eventCount());
    try std.testing.expectEqual(@as(usize, 0), controller.store.byteCount());
    try std.testing.expectEqual(@as(usize, 0), controller.store.pending.items.len);
    try std.testing.expect(controller.index.events.items.len == 1);

    // Frozen pipeline: no retry, no extra loss marker.
    var iteration: usize = 0;
    while (iteration < 10) : (iteration += 1) _ = controller.poll(100 + iteration, .{});
    try std.testing.expectEqual(@as(u64, 1), controller.rejected);
    try std.testing.expectEqual(@as(u64, 1), controller.lossView().markers);
    try std.testing.expect(controller.index.events.items.len == 1);

    // InvalidJournal is terminal for this pipeline, but a clean restart works.
    try std.testing.expect(controller.restart());
    try std.testing.expectEqual(State.ready, controller.statusView().state);
    fake.emit(2);
    const after = controller.poll(200, .{});
    try std.testing.expect(after.changed);
    try std.testing.expectEqual(@as(usize, 2), controller.store.eventCount());
}

test "loss markers are capped with aggregate loss reported outside the cap" {
    var controller = Controller.init(std.testing.allocator, std.testing.io, .{
        .rebuild_interval_ms = 0,
        .max_feed_bytes = 256,
        .max_loss_markers = 2,
    });
    defer controller.deinit();
    var fake = FakeSource{};
    controller.attach(fake.source(), .{});
    try std.testing.expect(controller.start());
    var iteration: usize = 0;
    while (iteration < 6) : (iteration += 1) {
        fake.emit(4);
        _ = controller.poll(10 + iteration * 10, .{});
    }
    // Feed trims keep arriving; only the cap becomes marker events.
    try std.testing.expectEqual(@as(u64, 2), controller.lossView().markers);
    try std.testing.expect(controller.lossView().aggregate > 0);
    try std.testing.expect(controller.index.events.items.len <= controller.indexed_events + 2);
    try std.testing.expectEqual(
        @as(u64, controller.index.lost) +| controller.lossView().aggregate,
        controller.statsView().lost,
    );
    const model = controller.view() orelse return error.TestUnexpectedResult;
    try std.testing.expect(model.summary.lost > 0);
}

const follow_source = @import("../../platform/follow_source.zig");

test "recorder tail reaches the controller and reports retention gaps" {
    var controller = Controller.init(std.testing.allocator, std.testing.io, .{ .rebuild_interval_ms = 0 });
    defer controller.deinit();
    var follow = follow_source.Source{ .dir = "fixtures/ui/design/recorder" };
    controller.attach(follow.source(), .{});
    try std.testing.expect(controller.start());
    var iteration: usize = 0;
    while (iteration < 20 and controller.statsView().lost == 0) : (iteration += 1) {
        _ = controller.poll(@as(u64, @intCast(iteration)) * 50, .{});
        std.Io.sleep(std.testing.io, .fromMilliseconds(50), .awake) catch {};
    }
    controller.stop();
    try std.testing.expect(controller.statsView().lost > 0);
    try std.testing.expectEqual(State.stopped, controller.statusView().state);
}

const segment_mod = @import("../../recorder/segment.zig");
const manifest_mod = @import("../../recorder/manifest.zig");
const journal_mod = @import("../../stream/journal.zig");

test "follow source decodes compact recorder segments into canonical ndjson" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const pwd = std.c.getenv("PWD") orelse return error.SkipZigTest;
    const root = try std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/live-follow-{d}", .{
        std.mem.span(pwd), std.testing.random_seed,
    });
    defer allocator.free(root);
    const segments = try std.fmt.allocPrint(allocator, "{s}/segments", .{root});
    defer allocator.free(segments);
    std.Io.Dir.cwd().createDirPath(io, segments) catch return error.SkipZigTest;
    defer {
        std.Io.Dir.deleteDirAbsolute(io, segments) catch {};
        std.Io.Dir.deleteDirAbsolute(io, root) catch {};
    }

    const wall: u64 = 1_700_000_000_000_000_000;
    var writer = try segment_mod.Writer.create(io, allocator, root, 0, wall, 1);
    var ts: u64 = 1_000_000_000;
    var index: usize = 0;
    while (index < 4) : (index += 1) {
        ts += std.time.ns_per_ms;
        try writer.writeEvent(.{
            .kind = .sched_switch,
            .ts_ns = ts,
            .cpu = 0,
            .pid = 7,
            .tid = 7,
            .a = 7,
            .b = 0,
            .comm = "worker",
        });
    }
    const events_written = writer.eventCount();
    try writer.close();
    writer.deinit();

    const segment_path = try std.fmt.allocPrint(allocator, "segments/{d}-0.xsraw", .{wall});
    defer allocator.free(segment_path);
    const manifest_path = try std.fmt.allocPrint(allocator, "{s}/manifest.json", .{root});
    defer allocator.free(manifest_path);
    try manifest_mod.writeAtomic(io, allocator, manifest_path, .{
        .session_id = "live-follow-test",
        .state = .stopped,
        .started_wall_ns = wall,
        .started_mono_ns = 1,
        .updated_wall_ns = wall + 10,
        .segments = &.{.{
            .path = segment_path,
            .start_wall_ns = wall,
            .start_mono_ns = 1,
            .end_wall_ns = wall + 10,
            .end_mono_ns = 2,
            .bytes = 512,
            .events = events_written,
            .closed = true,
        }},
    });

    var store = live_feed.Store.init();
    defer store.deinit();
    var follow = follow_source.Source{ .dir = root };
    try std.testing.expect(follow.begin(allocator, io, &store, root));
    var iteration: usize = 0;
    while (iteration < 30 and store.endOffset() == 0) : (iteration += 1) {
        std.Io.sleep(io, .fromMilliseconds(20), .awake) catch {};
    }
    follow.stop();
    const data = try store.snapshot(allocator);
    defer allocator.free(data);
    try std.testing.expect(data.len > 0);
    // parseData allocates per-event strings; a test arena owns them.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parsed = try journal_mod.parseData(arena.allocator(), data);
    try std.testing.expectEqual(@as(usize, 4), parsed.len);
    try std.testing.expectEqual(event_mod.Kind.sched_switch, parsed[0].kind);
    try std.testing.expect(std.mem.indexOf(u8, data, "host_mutation\":false") != null);
}
