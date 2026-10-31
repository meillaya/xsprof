//! Platform-facing executor for GUI lab effects. The controller owns source
//! storage, the capture worker, and the bounded live feed; the reducer stays
//! pure and only receives completions.

const std = @import("std");
const action = @import("action.zig");
const state_mod = @import("state.zig");
const source_mod = @import("source.zig");
const live_feed = @import("../../stream/live_feed.zig");
const lab_worker = @import("../../capture/lab_worker.zig");
const live = @import("../../capture/live.zig");
const chrome_trace = @import("../../viz/chrome_trace.zig");

pub const Controller = struct {
    allocator: std.mem.Allocator,
    store: source_mod.SourceStore,
    compare_store: source_mod.SourceStore,
    feed: live_feed.Store = .{},
    worker: ?*lab_worker.Worker = null,

    pub fn init(allocator: std.mem.Allocator) Controller {
        return .{
            .allocator = allocator,
            .store = source_mod.SourceStore.init(allocator),
            .compare_store = source_mod.SourceStore.init(allocator),
        };
    }

    pub fn deinit(self: *Controller) void {
        if (self.worker) |worker| {
            worker.destroy();
            self.worker = null;
        }
        self.feed.deinit();
        self.store.deinit();
        self.compare_store.deinit();
    }

    pub fn apply(
        self: *Controller,
        io: std.Io,
        lab: *state_mod.LabState,
        effects: []const action.Effect,
    ) !void {
        for (effects) |effect| {
            switch (effect) {
                .none => {},
                .load_source => |request| self.load(io, lab, request.kind, request.path),
                .load_compare => |request| self.loadCompare(io, lab, request.kind, request.path),
                .clear_compare => self.compare_store.clear(),
                .start_capture => |request| try self.start(io, lab, request.duration_ms, request.preset),
                .stop_capture => self.stop(lab),
                .exports => |request| try self.exportFile(io, lab, request.kind, request.path),
                .open_loopback => {},
            }
        }
    }

    pub fn poll(self: *Controller, lab: *state_mod.LabState) !void {
        const worker = self.worker orelse return;
        const stats = worker.stats();
        if (stats.finished) {
            const finished = worker.stop();
            worker.destroy();
            self.worker = null;
            _ = try lab.apply(.{ .completion = .{ .capture_finished = .{
                .outcome = if (finished.failed) .failed else .stopped,
                .events = finished.events,
                .lost = finished.lost,
                .reason = if (finished.failed) "capture worker failed" else "capture finished",
            } } });
            return;
        }
        _ = try lab.apply(.{ .completion = .{ .capture_progress = .{
            .events = stats.events,
            .lost = stats.lost,
            .cpu_bp = 0,
            .rss_kb = 0,
        } } });
    }

    fn load(
        self: *Controller,
        io: std.Io,
        lab: *state_mod.LabState,
        kind: action.SourceKind,
        path: []const u8,
    ) void {
        if (kind == .live) return;
        const session = (switch (kind) {
            .recorder => self.store.loadRecorder(io, path, 10 * 60 * 1000),
            else => self.store.loadReplay(io, path),
        }) catch |err| {
            _ = lab.apply(.{ .completion = .{ .source_failed = .{ .reason = @errorName(err) } } }) catch {};
            return;
        };
        _ = lab.apply(.{ .completion = .{ .source_ready = .{ .session = session } } }) catch {};
    }

    fn loadCompare(
        self: *Controller,
        io: std.Io,
        lab: *state_mod.LabState,
        kind: action.SourceKind,
        path: []const u8,
    ) void {
        if (kind == .live) {
            _ = lab.apply(.{ .completion = .{ .compare_failed = .{ .reason = "live compare is unsupported" } } }) catch {};
            return;
        }
        const session = (switch (kind) {
            .recorder => self.compare_store.loadRecorder(io, path, 10 * 60 * 1000),
            else => self.compare_store.loadReplay(io, path),
        }) catch |err| {
            _ = lab.apply(.{ .completion = .{ .compare_failed = .{ .reason = @errorName(err) } } }) catch {};
            return;
        };
        _ = lab.apply(.{ .completion = .{ .compare_ready = .{ .session = session } } }) catch {};
    }

    fn start(
        self: *Controller,
        io: std.Io,
        lab: *state_mod.LabState,
        duration_ms: u32,
        preset: action.CapturePreset,
    ) !void {
        if (self.worker) |worker| {
            worker.destroy();
            self.worker = null;
        }
        const result = try lab_worker.Worker.start(io, self.allocator, &self.feed, .{
            .duration_ms = duration_ms,
            .preset = switch (preset) {
                .scheduler => .scheduler,
                .memory => .memory,
                .deep => .deep,
            },
        });
        switch (result) {
            .running => |worker| {
                self.worker = worker;
                _ = try lab.apply(.{ .completion = .capture_started });
            },
            .unavailable => |unavailable| {
                _ = try lab.apply(.{ .completion = .{ .capture_finished = .{
                    .outcome = if (unavailable.state == .READY) .failed else if (unavailable.state == .REFUSE) .refused else .skipped,
                    .events = 0,
                    .lost = 0,
                    .reason = unavailable.reason,
                } } });
            },
        }
    }

    fn stop(self: *Controller, lab: *state_mod.LabState) void {
        const worker = self.worker orelse return;
        const stats = worker.stop();
        worker.destroy();
        self.worker = null;
        _ = lab.apply(.{ .completion = .{ .capture_finished = .{
            .outcome = if (stats.failed) .failed else .stopped,
            .events = stats.events,
            .lost = stats.lost,
            .reason = if (stats.failed) "capture worker failed" else "capture stopped",
        } } }) catch {};
    }

    fn exportFile(
        self: *Controller,
        io: std.Io,
        lab: *state_mod.LabState,
        kind: action.ExportKind,
        path: []const u8,
    ) !void {
        if (kind != .trace) {
            _ = try lab.apply(.{ .completion = .{ .export_failed = .{
                .kind = kind,
                .reason = "export kind is not wired yet",
            } } });
            return;
        }
        const file = if (path.len != 0 and path[0] == '/')
            std.Io.Dir.createFileAbsolute(io, path, .{}) catch {
                _ = try lab.apply(.{ .completion = .{ .export_failed = .{
                    .kind = kind,
                    .reason = "cannot open export path",
                } } });
                return;
            }
        else
            std.Io.Dir.cwd().createFile(io, path, .{}) catch {
                _ = try lab.apply(.{ .completion = .{ .export_failed = .{
                    .kind = kind,
                    .reason = "cannot open export path",
                } } });
                return;
            };
        defer file.close(io);
        var buffer: [64 * 1024]u8 = undefined;
        var writer = file.writer(io, &buffer);
        chrome_trace.writeTimeline(
            &writer.interface,
            self.allocator,
            lab.view.session.events,
            null,
            null,
        ) catch {
            _ = try lab.apply(.{ .completion = .{ .export_failed = .{
                .kind = kind,
                .reason = "cannot write trace",
            } } });
            return;
        };
        writer.interface.flush() catch {};
        _ = try lab.apply(.{ .completion = .{ .export_done = .{ .kind = kind, .path = path } } });
    }
};

test "controller loads a replay and reports capture SKIP off Linux" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lab = try state_mod.LabState.init(arena.allocator());
    defer lab.deinit();
    var controller = Controller.init(arena.allocator());
    defer controller.deinit();

    const open = try lab.apply(.{ .intent = .{ .open_source = .{
        .kind = .replay,
        .path = "fixtures/ui/healthy.ndjson",
    } } });
    try controller.apply(std.testing.io, &lab, open.slice());
    try std.testing.expectEqual(state_mod.SourcePhase.ready, lab.source.phase);
    try std.testing.expect(lab.view.session.events.len > 1000);

    const compare = try lab.apply(.{ .intent = .set_compare });
    try controller.apply(std.testing.io, &lab, compare.slice());
    try std.testing.expectEqual(action.ComparePhase.ready, lab.compare.phase);
    try std.testing.expect(lab.compare.session != null);

    const start = try lab.apply(.{ .intent = .{ .start_capture = .{
        .duration_ms = 10,
        .preset = .scheduler,
    } } });
    try controller.apply(std.testing.io, &lab, start.slice());
    if (@import("builtin").os.tag != .linux) {
        try std.testing.expect(lab.capture.phase == .skipped or lab.capture.phase == .refused);
    }
}
