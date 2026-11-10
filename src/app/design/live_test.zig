//! Synthetic-batch tests for the live controller: no capture, no window.
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
    allocator: std.mem.Allocator = std.testing.allocator,
    queue: ?*live_feed.Queue = null,
    unavailable: ?Unavailable = null,
    failed: bool = false,
    ts_ns: u64 = 0,
    emitted: u64 = 0,
    batch: u32 = 0,

    fn source(self: *FakeSource) Source {
        return .{ .context = @ptrCast(self), .vtable = &fake_vtable };
    }

    /// Push one batch of synthetic switch events; a batch is the unit the real
    /// tail produces too.
    fn emit(self: *FakeSource, count: usize) void {
        const queue = self.queue orelse return;
        const batch = live_feed.Batch.create(self.allocator) catch return;
        var index: usize = 0;
        while (index < count) : (index += 1) {
            self.ts_ns += std.time.ns_per_ms;
            const odd = (self.emitted % 2) == 1;
            batch.push(.{
                .kind = .sched_switch,
                .ts_ns = self.ts_ns,
                .cpu = 0,
                .pid = if (odd) 0 else 7,
                .tid = if (odd) 0 else 7,
                .a = if (odd) 0 else 7,
                .b = if (odd) 7 else 0,
                .comm = if (odd) "idle" else "worker",
            }) catch {
                batch.deinit();
                return;
            };
            self.emitted += 1;
        }
        queue.push(batch);
    }
};

fn fakeStart(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    io: std.Io,
    queue: *live_feed.Queue,
    options: SourceOptions,
) StartResult {
    _ = io;
    _ = options;
    const self: *FakeSource = @ptrCast(@alignCast(ctx));
    if (self.unavailable) |unavailable| return .{ .unavailable = unavailable };
    self.allocator = allocator;
    self.queue = queue;
    return .running;
}

fn fakeStop(ctx: *anyopaque) void {
    const self: *FakeSource = @ptrCast(@alignCast(ctx));
    self.queue = null;
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

test "live controller indexes synthetic batches, rebuilds, and remaps selection" {
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

test "feed trim emits one explicit loss marker" {
    var controller = Controller.init(std.testing.allocator, std.testing.io, .{ .rebuild_interval_ms = 0 });
    defer controller.deinit();
    var fake = FakeSource{};
    controller.attach(fake.source(), .{});
    try std.testing.expect(controller.start());
    fake.emit(4);
    _ = controller.poll(10, .{});
    // A one-batch handoff budget evicts the oldest complete batch; the controller
    // must report that trim exactly once as a feed_trim marker while still
    // committing the surviving batch.
    controller.feed.max_batches = 1;
    fake.emit(4);
    fake.emit(4);
    const result = controller.poll(500, .{});
    try std.testing.expect(result.changed);
    const model = controller.view() orelse return error.TestUnexpectedResult;
    try std.testing.expect(model.summary.lost > 0);
    try std.testing.expectEqual(@as(u64, 1), controller.lossView().markers);
    try std.testing.expectEqual(@as(u64, 0), controller.lossView().aggregate);
    try std.testing.expect(controller.index.events.items.len > 4);
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
    // The refusal is published as one loss marker, so the console repaints with
    // the degraded state instead of silently keeping the last frame.
    try std.testing.expect(result.changed);
    try std.testing.expectEqual(State.degraded, controller.statusView().state);
    try std.testing.expectEqualStrings("live store full; ingest stopped", controller.statusView().reason);
    try std.testing.expect(!controller.started);
    // The refused batch is all-or-nothing: nothing was retained.
    try std.testing.expectEqual(@as(usize, 0), controller.store.eventCount());
    try std.testing.expectEqual(@as(usize, 0), controller.store.byteCount());
    try std.testing.expectEqual(@as(usize, 0), controller.store.arenas.items.len);
    try std.testing.expect(controller.index.events.items.len == 1);
    try std.testing.expectEqual(@as(u64, 1), controller.lossView().markers);

    // Repeated polls cannot re-append the rejected batch or repeat markers.
    var iteration: usize = 0;
    while (iteration < 10) : (iteration += 1) _ = controller.poll(100 + iteration, .{});
    try std.testing.expectEqual(@as(u64, 1), controller.rejected);
    try std.testing.expectEqual(@as(u64, 1), controller.lossView().markers);
    try std.testing.expect(controller.index.events.items.len == 1);
    try std.testing.expectEqual(@as(usize, 0), controller.store.eventCount());
    try std.testing.expectEqualStrings("live store full; ingest stopped", controller.statusView().reason);
}

test "loss markers are capped with aggregate loss reported outside the cap" {
    var controller = Controller.init(std.testing.allocator, std.testing.io, .{
        .rebuild_interval_ms = 0,
        .max_loss_markers = 2,
    });
    defer controller.deinit();
    var fake = FakeSource{};
    controller.attach(fake.source(), .{});
    try std.testing.expect(controller.start());
    fake.emit(4);
    _ = controller.poll(10, .{});
    // From here on every batch exceeds the handoff budget; trims keep arriving
    // but only the cap becomes marker events.
    controller.feed.max_bytes = 1;
    var iteration: usize = 0;
    while (iteration < 6) : (iteration += 1) {
        fake.emit(4);
        _ = controller.poll(20 + iteration * 10, .{});
    }
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
const segment_mod = @import("../../recorder/segment.zig");
const manifest_mod = @import("../../recorder/manifest.zig");
const compact = @import("../../recorder/compact.zig");
const recorder_window = @import("../../recorder/window.zig");
const session_mod = @import("../../stream/session.zig");
const journal_mod = @import("../../stream/journal.zig");
const derive = @import("derive.zig");
const model_mod = @import("model.zig");
const Model = model_mod.Model;

const live_context: derive.Context = .{
    .host = "live",
    .source = "LIVE",
    .fixture = "live stream",
    .live = true,
};

/// Manifest writes are absolute-path only, so tests own an absolute state dir.
fn createDir(allocator: std.mem.Allocator, tag: []const u8) ![]u8 {
    const io = std.testing.io;
    const root = try std.fmt.allocPrint(allocator, "/tmp/xsprof-live-a2-{s}", .{tag});
    cleanupDir(io, allocator, root);
    const segments = try std.fmt.allocPrint(allocator, "{s}/segments", .{root});
    defer allocator.free(segments);
    std.Io.Dir.cwd().createDirPath(io, segments) catch return error.TestUnexpectedResult;
    return root;
}

fn cleanupDir(io: std.Io, allocator: std.mem.Allocator, root: []const u8) void {
    const segments = std.fmt.allocPrint(allocator, "{s}/segments", .{root}) catch return;
    defer allocator.free(segments);
    if (std.Io.Dir.openDirAbsolute(io, segments, .{ .iterate = true })) |dir_value| {
        var dir = dir_value;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| dir.deleteFile(io, entry.name) catch {};
    } else |_| {}
    std.Io.Dir.deleteDirAbsolute(io, segments) catch {};
    const manifest = std.fmt.allocPrint(allocator, "{s}/manifest.json", .{root}) catch return;
    defer allocator.free(manifest);
    std.Io.Dir.deleteFileAbsolute(io, manifest) catch {};
    const temp = std.fmt.allocPrint(allocator, "{s}/manifest.json.tmp", .{root}) catch return;
    defer allocator.free(temp);
    std.Io.Dir.deleteFileAbsolute(io, temp) catch {};
    std.Io.Dir.deleteDirAbsolute(io, root) catch {};
}

fn wallNow(io: std.Io) u64 {
    return @intCast(@max(0, std.Io.Clock.now(.real, io).nanoseconds));
}

const TestEvent = event_mod.RawEvent;

/// Write one stopped compact segment plus its manifest; returns the event count.
fn writeCompactRecording(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    wall_ns: u64,
    events: []const TestEvent,
) !void {
    var writer = try segment_mod.Writer.create(io, allocator, root, 0, wall_ns, 1);
    var written: u64 = 0;
    for (events) |entry| {
        try writer.writeEvent(entry);
        written += 1;
    }
    try writer.close();
    const segment_path = try std.fmt.allocPrint(allocator, "segments/{d}-0.xsraw", .{wall_ns});
    defer allocator.free(segment_path);
    const manifest_path = try std.fmt.allocPrint(allocator, "{s}/manifest.json", .{root});
    defer allocator.free(manifest_path);
    try manifest_mod.writeAtomic(io, allocator, manifest_path, .{
        .session_id = "live-a2-test",
        .state = .stopped,
        .started_wall_ns = wall_ns,
        .started_mono_ns = 1,
        .updated_wall_ns = wall_ns + 60 * std.time.ns_per_s,
        .segments = &.{.{
            .path = segment_path,
            .start_wall_ns = wall_ns,
            .start_mono_ns = 1,
            .end_wall_ns = wall_ns + 60 * std.time.ns_per_s,
            .end_mono_ns = 2,
            .bytes = 512,
            .events = written,
            .closed = true,
        }},
    });
    writer.deinit();
}

fn writeLegacyRecording(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    lines: []const []const u8,
) !void {
    const segment_path = "segments/legacy-0.ndjson";
    const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, segment_path });
    defer allocator.free(full);
    const file = try std.Io.Dir.cwd().createFile(io, full, .{});
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    for (lines) |line| {
        try writer.interface.writeAll(line);
        try writer.interface.writeByte('\n');
    }
    try writer.interface.flush();
    file.close(io);
    const manifest_path = try std.fmt.allocPrint(allocator, "{s}/manifest.json", .{root});
    defer allocator.free(manifest_path);
    try manifest_mod.writeAtomic(io, allocator, manifest_path, .{
        .session_id = "live-a2-legacy",
        .state = .stopped,
        .started_wall_ns = 1,
        .started_mono_ns = 1,
        .updated_wall_ns = 2,
        .segments = &.{.{
            .path = segment_path,
            .start_wall_ns = 1,
            .start_mono_ns = 1,
            .end_wall_ns = 2,
            .end_mono_ns = 2,
            .events = @intCast(lines.len),
            .closed = true,
        }},
    });
}

fn pollUntilIndexed(controller: *Controller, expected: usize, timeout_iterations: usize) !void {
    var iteration: usize = 0;
    while (iteration < timeout_iterations) : (iteration += 1) {
        _ = controller.poll(@intCast(iteration * 10), .{});
        if (controller.index.events.items.len >= expected) return;
        std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake) catch {};
    }
    return error.TestUnexpectedResult;
}

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

test "follow source decodes compact segments into decoded event batches" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const root = try createDir(allocator, "follow-compact");
    defer allocator.free(root);
    defer cleanupDir(io, allocator, root);

    var events: [4]TestEvent = undefined;
    var ts: u64 = 1_000_000_000;
    for (&events, 0..) |*entry, index| {
        ts += std.time.ns_per_ms;
        entry.* = .{
            .kind = .sched_switch,
            .ts_ns = ts,
            .cpu = 0,
            .pid = 7,
            .tid = 7,
            .a = @intCast(index),
            .comm = "worker",
        };
    }
    try writeCompactRecording(io, allocator, root, wallNow(io) - 120 * std.time.ns_per_s, &events);

    var queue = live_feed.Queue.init(allocator, io);
    defer queue.deinit();
    var follow = follow_source.Source{ .dir = root };
    try std.testing.expect(follow.begin(allocator, io, &queue, root));
    var iteration: usize = 0;
    while (iteration < 30 and queue.eventCount() == 0) : (iteration += 1) {
        std.Io.sleep(io, .fromMilliseconds(20), .awake) catch {};
    }
    follow.stop();
    try std.testing.expectEqual(@as(usize, 4), queue.eventCount());
    // Strings point into each batch's arena, so the batches stay alive until the
    // assertions are done (the controller keeps them by adopting the arena).
    var batches: [8]*live_feed.Batch = @splat(undefined);
    var batch_count: usize = 0;
    while (queue.pop()) |batch| {
        if (batch_count >= batches.len) {
            batch.deinit();
            continue;
        }
        batches[batch_count] = batch;
        batch_count += 1;
    }
    defer for (batches[0..batch_count]) |batch| batch.deinit();
    var count: usize = 0;
    for (batches[0..batch_count]) |batch| count += batch.events.items.len;
    try std.testing.expectEqual(@as(usize, 4), count);
    try std.testing.expectEqual(1, batch_count);
    const decoded = batches[0].events.items;
    try std.testing.expectEqual(event_mod.Kind.sched_switch, decoded[0].kind);
    try std.testing.expectEqualStrings("worker", decoded[0].comm);
    try std.testing.expectEqual(@as(u64, 3), decoded[3].a);
    // Batch strings are copied into the batch arena, not borrowed from the
    // reader's reusable block buffer.
    try std.testing.expectEqualStrings("worker", decoded[3].comm);
}

test "follow source parses legacy ndjson once and marks corrupt lines" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const root = try createDir(allocator, "follow-legacy");
    defer allocator.free(root);
    defer cleanupDir(io, allocator, root);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var valid: std.Io.Writer.Allocating = .init(scratch);
    try event_mod.writeJson(&valid.writer, .{ .kind = .sched_switch, .ts_ns = 1, .cpu = 0, .pid = 7, .comm = "worker" });
    var second: std.Io.Writer.Allocating = .init(scratch);
    try event_mod.writeJson(&second.writer, .{ .kind = .page_fault, .ts_ns = 2, .cpu = 1, .pid = 7, .a = 3 });
    const lines = [_][]const u8{
        valid.writer.buffered(),
        "{\"schema\":\"xsprof/event/v1\",\"event\":\"marker\",\"host_mutation\":true}",
        second.writer.buffered(),
        "not an event line",
    };
    try writeLegacyRecording(io, allocator, root, &lines);

    var queue = live_feed.Queue.init(allocator, io);
    defer queue.deinit();
    var follow = follow_source.Source{ .dir = root };
    try std.testing.expect(follow.begin(allocator, io, &queue, root));
    var iteration: usize = 0;
    while (iteration < 30 and queue.eventCount() == 0) : (iteration += 1) {
        std.Io.sleep(io, .fromMilliseconds(20), .awake) catch {};
    }
    follow.stop();
    var data_events: usize = 0;
    var corrupt_markers: usize = 0;
    while (queue.pop()) |batch| {
        defer batch.deinit();
        for (batch.events.items) |entry| {
            if (entry.kind == .marker) {
                if (std.mem.indexOf(u8, entry.detail, "corrupt_line") != null) corrupt_markers += 1;
            } else {
                data_events += 1;
            }
        }
    }
    // The mutation-bearing line is rejected at the boundary as a loss marker;
    // the non-event line is ignored; the healthy events still decode.
    try std.testing.expectEqual(@as(usize, 2), data_events);
    try std.testing.expectEqual(@as(usize, 1), corrupt_markers);
    try std.testing.expect(follow.stats().lost >= 1);
}

test "corrupt compact segment is reported once, not every poll" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const root = try createDir(allocator, "corrupt");
    defer allocator.free(root);
    defer cleanupDir(io, allocator, root);

    var events: [2]TestEvent = .{
        .{ .kind = .sched_switch, .ts_ns = 1_000_000_000, .cpu = 0, .pid = 7, .tid = 7, .a = 7, .comm = "worker" },
        .{ .kind = .page_fault, .ts_ns = 1_000_000_001, .cpu = 0, .pid = 7, .tid = 7, .a = 1 },
    };
    const wall_ns = wallNow(io) - 120 * std.time.ns_per_s;
    try writeCompactRecording(io, allocator, root, wall_ns, &events);
    // Flip one payload byte: the block CRC check must reject the segment.
    const segment_path = try std.fmt.allocPrint(allocator, "{s}/segments/{d}-0.xsraw", .{ root, wall_ns });
    defer allocator.free(segment_path);
    var bytes = try std.Io.Dir.cwd().readFileAlloc(io, segment_path, allocator, .limited(1024 * 1024));
    defer allocator.free(bytes);
    bytes[compact.header_bytes + compact.block_header_bytes + 2] ^= 0xff;
    {
        const file = try std.Io.Dir.createFileAbsolute(io, segment_path, .{ .truncate = true });
        defer file.close(io);
        try file.writeStreamingAll(io, bytes);
    }

    var queue = live_feed.Queue.init(allocator, io);
    defer queue.deinit();
    var follow = follow_source.Source{ .dir = root };
    try std.testing.expect(follow.begin(allocator, io, &queue, root));
    // Cover several 100 ms tail polls; the corruption is a single gap.
    var iteration: usize = 0;
    while (iteration < 8) : (iteration += 1) {
        std.Io.sleep(io, .fromMilliseconds(50), .awake) catch {};
    }
    follow.stop();
    try std.testing.expectEqual(@as(u64, 1), follow.stats().lost);
    var markers: usize = 0;
    while (queue.pop()) |batch| {
        defer batch.deinit();
        for (batch.events.items) |entry| {
            if (std.mem.indexOf(u8, entry.detail, "corrupt_segment") != null) markers += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), markers);
}

/// Fields the live model and the replay model must agree on for the same
/// recording. Source labels are excluded: they are product metadata, not data.
fn expectModelsEqual(expected: *const Model, actual: *const Model) !void {
    try std.testing.expectEqualStrings(expected.meta.host, actual.meta.host);
    try std.testing.expectEqualStrings(expected.meta.fixture, actual.meta.fixture);
    try std.testing.expectEqual(expected.mode, actual.mode);
    try std.testing.expectEqual(expected.summary.events, actual.summary.events);
    try std.testing.expectEqual(expected.summary.switches, actual.summary.switches);
    try std.testing.expectEqual(expected.summary.migrations, actual.summary.migrations);
    try std.testing.expectEqual(expected.summary.wakeups, actual.summary.wakeups);
    try std.testing.expectEqual(expected.summary.faults, actual.summary.faults);
    try std.testing.expectEqual(expected.summary.lost, actual.summary.lost);
    try std.testing.expectEqual(expected.summary.cpus, actual.summary.cpus);
    try std.testing.expectEqual(expected.summary.selfSwitches, actual.summary.selfSwitches);
    try std.testing.expectEqual(expected.summary.windowMs, actual.summary.windowMs);
    try std.testing.expectEqual(expected.summary.switchRate, actual.summary.switchRate);
    try std.testing.expectEqual(expected.summary.selfShare, actual.summary.selfShare);
    try std.testing.expectEqual(expected.windowMs, actual.windowMs);

    try std.testing.expectEqual(expected.capabilities.len, actual.capabilities.len);
    for (expected.capabilities, actual.capabilities) |a, b| {
        try std.testing.expectEqualStrings(a.name, b.name);
        try std.testing.expectEqualStrings(a.state, b.state);
        try std.testing.expectEqualStrings(a.detail, b.detail);
    }
    try std.testing.expectEqual(expected.typeCounts.len, actual.typeCounts.len);
    for (expected.typeCounts, actual.typeCounts) |a, b| {
        try std.testing.expectEqualStrings(a.kind, b.kind);
        try std.testing.expectEqual(a.count, b.count);
    }
    try std.testing.expectEqual(expected.threads.len, actual.threads.len);
    for (expected.threads, actual.threads) |a, b| {
        try std.testing.expectEqualStrings(a.comm, b.comm);
        try std.testing.expectEqual(a.pid, b.pid);
        try std.testing.expectEqual(a.switches, b.switches);
        try std.testing.expectEqual(a.migrations, b.migrations);
        try std.testing.expectEqual(a.lane, b.lane);
    }
    try std.testing.expectEqual(expected.slices.len, actual.slices.len);
    for (expected.slices, actual.slices) |a, b| {
        try std.testing.expectEqual(a.cpu, b.cpu);
        try std.testing.expectEqual(a.pid, b.pid);
        try std.testing.expectEqualStrings(a.comm, b.comm);
        try std.testing.expectEqual(a.lane, b.lane);
        try std.testing.expectEqual(a.start, b.start);
        try std.testing.expectEqual(a.dur, b.dur);
    }
    try std.testing.expectEqual(expected.events.len, actual.events.len);
    for (expected.events, actual.events) |a, b| {
        try std.testing.expectEqual(a.ts, b.ts);
        try std.testing.expectEqualStrings(a.type, b.type);
        try std.testing.expectEqual(a.cpu, b.cpu);
        try std.testing.expectEqual(a.pid, b.pid);
        try std.testing.expectEqualStrings(a.comm, b.comm);
        try std.testing.expectEqualStrings(a.detail, b.detail);
        try std.testing.expectEqual(a.loss, b.loss);
    }
    try std.testing.expectEqual(expected.lostAt.len, actual.lostAt.len);
    for (expected.lostAt, actual.lostAt) |a, b| try std.testing.expectEqual(a, b);
}

fn parityEvents() [14]TestEvent {
    const base: u64 = 1_000_000_000;
    return .{
        .{ .kind = .sched_switch, .ts_ns = base, .cpu = 0, .pid = 7, .tid = 7, .a = 7, .comm = "worker" },
        .{ .kind = .sched_switch, .ts_ns = base + 1, .cpu = 0, .pid = 0, .tid = 0, .a = 0, .b = 7, .comm = "idle" },
        .{ .kind = .sched_switch, .ts_ns = base + 2, .cpu = 1, .pid = 7, .tid = 7, .a = 7, .b = 0, .comm = "worker" },
        .{ .kind = .page_fault, .ts_ns = base + 3, .cpu = 1, .pid = 7, .tid = 7, .a = 3 },
        .{ .kind = .sched_wakeup, .ts_ns = base + 4, .cpu = 0, .pid = 9, .tid = 9, .a = 7, .comm = "waker" },
        .{ .kind = .sched_migrate, .ts_ns = base + 5, .cpu = 2, .pid = 7, .tid = 7, .a = 0, .b = 1, .comm = "worker" },
        .{ .kind = .marker, .ts_ns = base + 6, .cpu = -1, .detail = "sample_loss live_follow dropped=2 reason=test" },
        .{ .kind = .marker, .ts_ns = base + 7, .cpu = -1, .detail = "ui_host=parity-test-host" },
        .{ .kind = .capability, .ts_ns = base + 8, .cpu = -1, .detail = "live_capture:READY:available" },
        .{ .kind = .refusal, .ts_ns = base + 9, .cpu = -1, .detail = "bpf:REFUSE:vm-gated" },
        .{ .kind = .sched_switch, .ts_ns = base + 10, .cpu = 3, .pid = 11, .tid = 11, .a = 11, .comm = "overlong-comm-name-abcdef" },
        .{ .kind = .marker, .ts_ns = base + 11, .cpu = -1, .detail = "token=supersecret pid=7" },
        .{ .kind = .sched_switch, .ts_ns = base + 12, .cpu = 2, .pid = 12, .tid = 12, .a = 12, .comm = "qu\"ote\\back" },
        .{ .kind = .incident, .ts_ns = base + 13, .cpu = -1, .detail = "incident:test" },
    };
}

test "live model matches the replay model for the same recording" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try createDir(allocator, "parity");
    defer cleanupDir(io, allocator, root);

    const events = parityEvents();
    const wall_ns = wallNow(io) - 120 * std.time.ns_per_s;
    try writeCompactRecording(io, allocator, root, wall_ns, &events);

    // Live leg: the console tail decodes the compact segment directly.
    var controller = Controller.init(allocator, io, .{ .rebuild_interval_ms = 0 });
    defer controller.deinit();
    var follow = follow_source.Source{ .dir = root };
    controller.attach(follow.source(), .{});
    try std.testing.expect(controller.start());
    try pollUntilIndexed(&controller, events.len, 100);
    _ = controller.poll(2_000, .{});
    controller.stop();
    const live_session = controller.sessionView() orelse return error.TestUnexpectedResult;
    const live_model = controller.view() orelse return error.TestUnexpectedResult;

    // Replay leg: the canonical extract path turns the same recording into
    // NDJSON, then the ordinary replay/derive pipeline builds the model.
    var window = try recorder_window.load(io, allocator, .{ .dir = root, .last_ms = 600_000 });
    defer window.deinit(allocator);
    // The recording carries one explicit loss marker; replay must report it.
    try std.testing.expectEqual(@as(u64, 2), window.sample_loss);
    var replay_session = try session_mod.Session.fromData(allocator, "replay", window.data);
    var replay_model = try derive.fromSession(allocator, &replay_session, live_context);

    try std.testing.expectEqual(live_session.events.len, replay_session.events.len);
    try std.testing.expectEqual(live_session.switches, replay_session.switches);
    try std.testing.expectEqual(live_session.first_us, replay_session.first_us);
    try std.testing.expectEqual(live_session.last_us, replay_session.last_us);
    try expectModelsEqual(&replay_model, live_model);
}

test "committed compact golden matches its canonical extract through the live path" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try createDir(allocator, "golden");
    defer cleanupDir(io, allocator, root);

    // Stage the committed .xsraw golden under a temp state dir with a stopped
    // manifest; the tail can only read a recorder directory, never the repo.
    const golden_segment = "tests/golden/recorder/segments/segment_v1_golden.xsraw";
    const canonical = "tests/golden/recorder/segment_v1_golden.ndjson";
    const segment_bytes = try std.Io.Dir.cwd().readFileAlloc(io, golden_segment, allocator, .limited(1024 * 1024));
    const segment_path = "segments/segment_v1_golden.xsraw";
    const staged = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, segment_path });
    {
        const file = try std.Io.Dir.createFileAbsolute(io, staged, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, segment_bytes);
    }
    const wall_ns = wallNow(io) - 120 * std.time.ns_per_s;
    const manifest_path = try std.fmt.allocPrint(allocator, "{s}/manifest.json", .{root});
    try manifest_mod.writeAtomic(io, allocator, manifest_path, .{
        .session_id = "live-a2-golden",
        .state = .stopped,
        .started_wall_ns = wall_ns,
        .started_mono_ns = 1,
        .updated_wall_ns = wall_ns + 60 * std.time.ns_per_s,
        .segments = &.{.{
            .path = segment_path,
            .start_wall_ns = wall_ns,
            .start_mono_ns = 1,
            .end_wall_ns = wall_ns + 60 * std.time.ns_per_s,
            .end_mono_ns = 2,
            .bytes = @intCast(segment_bytes.len),
            .events = 20,
            .closed = true,
        }},
    });

    var controller = Controller.init(allocator, io, .{ .rebuild_interval_ms = 0 });
    defer controller.deinit();
    var follow = follow_source.Source{ .dir = root };
    controller.attach(follow.source(), .{});
    try std.testing.expect(controller.start());
    try pollUntilIndexed(&controller, 20, 100);
    _ = controller.poll(2_000, .{});
    controller.stop();
    const live_model = controller.view() orelse return error.TestUnexpectedResult;

    // Replay leg: the committed canonical extract is exactly what the extract
    // command produces from that segment.
    const extract = try std.Io.Dir.cwd().readFileAlloc(io, canonical, allocator, .limited(1024 * 1024));
    var replay_session = try session_mod.Session.fromData(allocator, "replay", extract);
    var replay_model = try derive.fromSession(allocator, &replay_session, live_context);
    try expectModelsEqual(&replay_model, live_model);
}

test "live path contains no NDJSON re-serialization" {
    const production_files = [_][]const u8{
        @embedFile("live.zig"),
        @embedFile("../../stream/live_feed.zig"),
        @embedFile("../../platform/follow_source.zig"),
        @embedFile("../../platform/linux/live_source.zig"),
    };
    for (production_files) |source| {
        try std.testing.expect(std.mem.indexOf(u8, source, "writeJson") == null);
        try std.testing.expect(std.mem.indexOf(u8, source, "parseData") == null);
    }
}
