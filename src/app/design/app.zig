//! Shared console application state: model ownership, input, dialogs,
//! playback, and hit dispatch. Surfaces only translate native/web events.

const std = @import("std");
const xsui = @import("xsui");
const model_mod = @import("model.zig");
const state_mod = @import("state.zig");
const derive = @import("derive.zig");
const view_mod = @import("view.zig");
const commands = @import("commands.zig");
const overlays = @import("overlays.zig");
const session_mod = @import("../../stream/session.zig");

const Model = model_mod.Model;
const State = state_mod.State;

pub const Modifiers = struct {
    meta: bool = false,
    ctrl: bool = false,
    shift: bool = false,
};

pub const App = struct {
    backing: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    session: ?session_mod.Session = null,
    model: Model = .{},
    state: State = .{},
    source_path: ?[]const u8 = null,
    recorder_dir: ?[]const u8 = null,
    open_requested: bool = false,
    reload_requested: bool = false,
    live: bool = false,
    now_ms: u64 = 0,
    viewport_w: u32 = 1440,
    viewport_h: u32 = 900,
    toast_buf: [96]u8 = undefined,

    pub fn init(backing: std.mem.Allocator) App {
        return .{
            .backing = backing,
            .arena = std.heap.ArenaAllocator.init(backing),
            .model = .{ .meta = .{ .host = "no source", .source = "EMPTY", .fixture = "open a journal" } },
        };
    }

    pub fn deinit(self: *App) void {
        self.arena.deinit();
        if (self.source_path) |path| self.backing.free(path);
    }

    pub fn setLive(self: *App, value: bool) void {
        self.live = value;
    }

    pub fn setRecorderDir(self: *App, dir: []const u8) void {
        self.recorder_dir = dir;
    }

    pub fn loadRecorderData(self: *App, data: []const u8) !void {
        const owned = try self.arena.allocator().dupe(u8, data);
        const manifest_mod = @import("../../recorder/manifest.zig");
        var manifest = try manifest_mod.parse(self.arena.allocator(), owned);
        try derive.applyRecorder(self.arena.allocator(), &self.model, &manifest);
    }

    pub fn theme(self: *const App) xsui.Theme {
        return xsui.themes.presets[self.state.theme_index % xsui.themes.presets.len].theme;
    }

    pub fn loadReplay(self: *App, io: std.Io, path: []const u8) !void {
        const stable_path = try self.backing.dupe(u8, path);
        self.arena.deinit();
        self.arena = std.heap.ArenaAllocator.init(self.backing);
        self.session = null;
        if (self.source_path) |old| self.backing.free(old);
        self.source_path = stable_path;
        errdefer {
            self.source_path = null;
            self.backing.free(stable_path);
        }
        const session = try session_mod.Session.load(io, self.arena.allocator(), stable_path);
        var model = try derive.fromSession(self.arena.allocator(), &session, .{
            .fixture = stable_path,
            .source = "REPLAY",
            .capture_window = "",
        });
        if (self.recorder_dir) |dir| {
            const manifest_path = try std.fmt.allocPrint(self.arena.allocator(), "{s}/manifest.json", .{dir});
            const manifest_mod = @import("../../recorder/manifest.zig");
            if (try manifest_mod.read(io, self.arena.allocator(), manifest_path)) |manifest| {
                try derive.applyRecorder(self.arena.allocator(), &model, &manifest);
            }
        }
        self.session = session;
        self.model = model;
        self.resetView();
    }

    pub fn loadJournalData(self: *App, data: []const u8, source: []const u8) !void {
        self.arena.deinit();
        self.arena = std.heap.ArenaAllocator.init(self.backing);
        self.session = null;
        if (self.source_path) |old| self.backing.free(old);
        self.source_path = null;
        // The web surface frees its upload buffer immediately after this call.
        // JSON/journal strings may borrow the source slice, so keep an
        // arena-owned copy for the lifetime of the model.
        const owned = try self.arena.allocator().dupe(u8, data);
        const session = try session_mod.Session.fromData(self.arena.allocator(), source, owned);
        const model = try derive.fromSession(self.arena.allocator(), &session, .{
            .fixture = source,
            .source = if (self.live) "LIVE" else "REPLAY",
            .live = self.live,
        });
        self.session = session;
        self.model = model;
        self.resetView();
    }

    pub fn loadDemoData(self: *App, data: []const u8) !void {
        self.arena.deinit();
        self.arena = std.heap.ArenaAllocator.init(self.backing);
        self.session = null;
        if (self.source_path) |old| self.backing.free(old);
        self.source_path = null;
        const owned = try self.arena.allocator().dupe(u8, data);
        self.model = try model_mod.parse(self.arena.allocator(), owned);
        self.resetView();
    }

    pub fn loadDemo(self: *App, io: std.Io, path: []const u8) !void {
        const stable_path = try self.backing.dupe(u8, path);
        self.arena.deinit();
        self.arena = std.heap.ArenaAllocator.init(self.backing);
        self.session = null;
        if (self.source_path) |old| self.backing.free(old);
        self.source_path = stable_path;
        errdefer {
            self.source_path = null;
            self.backing.free(stable_path);
        }
        self.model = try model_mod.loadDemo(io, self.arena.allocator(), stable_path);
        self.resetView();
    }

    pub fn clearSource(self: *App) void {
        self.arena.deinit();
        self.arena = std.heap.ArenaAllocator.init(self.backing);
        self.session = null;
        if (self.source_path) |old| self.backing.free(old);
        self.source_path = null;
        self.model = .{ .meta = .{ .host = "no source", .source = "EMPTY", .fixture = "open a journal" }, .summary = .{ .windowMs = 0 } };
        self.resetView();
    }

    fn resetView(self: *App) void {
        self.state.timeline_start = 0;
        self.state.timeline_end = self.model.summary.windowMs;
        self.state.timeline_playhead = 0;
        self.state.timeline_playing = false;
        self.state.scroll_y = 0;
        self.state.selected_slice = null;
        self.state.events_selected = null;
        self.state.advisor_filter = .all;
        self.state.events_type = "all";
        self.state.events_query_len = 0;
        self.state.events_query = self.state.events_query_buf[0..0];
        self.state.events_filter_focused = false;
        self.state.palette_query_len = 0;
        self.state.palette_index = 0;
    }

    pub fn draw(self: *App, canvas: *xsui.Canvas) !void {
        self.viewport_w = canvas.frame.width;
        self.viewport_h = canvas.frame.height;
        try view_mod.view(&self.model, &self.state, canvas);
    }

    pub fn scrollBy(self: *App, delta: f32) void {
        const stage_h: f32 = @as(f32, @floatFromInt(self.viewport_h)) - 82.0;
        const content_h: f32 = switch (self.state.screen) {
            .overview => if (self.viewport_w >= 1320) 1104.0 else 1600.0,
            .timeline => 640.0,
            .advisor => 1010.0,
            .events => 780.0,
            .capture => 900.0,
        };
        const max_scroll = @max(0.0, content_h - stage_h);
        self.state.scroll_y = std.math.clamp(self.state.scroll_y + delta, 0, max_scroll);
    }

    pub fn handleKey(self: *App, codepoint: u21, mods: Modifiers) void {
        if (self.state.dialog != .none) {
            self.handleDialogKey(codepoint, mods);
            return;
        }
        if ((mods.meta or mods.ctrl) and (codepoint == 'k' or codepoint == 'K')) {
            self.openPalette();
            return;
        }
        if (self.state.events_filter_focused) {
            if (codepoint == 0x1b) {
                self.state.events_filter_focused = false;
                self.state.events_query_len = 0;
                self.syncQuery();
                return;
            }
            if (codepoint == '\n' or codepoint == '\r') {
                self.state.events_filter_focused = false;
                return;
            }
            if (codepoint == 0x7f or codepoint == 0x08) {
                if (self.state.events_query_len > 0) self.state.events_query_len -= 1;
                self.syncQuery();
                return;
            }
            if (codepoint >= 32 and codepoint < 0x7f and self.state.events_query_len < self.state.events_query_buf.len) {
                self.state.events_query_buf[self.state.events_query_len] = @intCast(codepoint);
                self.state.events_query_len += 1;
                self.syncQuery();
                return;
            }
            return;
        }
        switch (codepoint) {
            '1' => self.setScreen(.overview),
            '2' => self.setScreen(.timeline),
            '3' => self.setScreen(.advisor),
            '4' => self.setScreen(.events),
            '5' => self.setScreen(.capture),
            '/' => {
                self.setScreen(.events);
                self.state.events_filter_focused = true;
                self.showToast("filter events by task", false);
            },
            '?' => self.openDialog(.help),
            'w', 'W' => self.openDialog(.appearance),
            'f', 'F' => self.fitTimeline(),
            ' ' => {
                if (self.state.screen != .timeline) self.setScreen(.timeline);
                self.state.timeline_playing = !self.state.timeline_playing;
            },
            't', 'T' => {
                if (self.state.screen != .timeline) self.setScreen(.timeline);
                self.state.timeline_playhead = self.state.viewEnd(self.model.summary.windowMs);
            },
            'c', 'C' => {
                if (self.state.selected_slice != null) self.showToast("slice summary copied", false);
            },
            '+', '=' => self.zoomTimeline(0.6),
            '-', '_' => self.zoomTimeline(1.7),
            0x1b => {
                self.state.dialog = .none;
                self.state.events_filter_focused = false;
                self.state.selected_slice = null;
                self.state.events_selected = null;
                self.state.toast = null;
            },
            else => {},
        }
    }

    fn handleDialogKey(self: *App, codepoint: u21, mods: Modifiers) void {
        _ = mods;
        switch (self.state.dialog) {
            .palette => {
                const count = commands.count(self.state.paletteQuery());
                switch (codepoint) {
                    0x1b => self.state.dialog = .none,
                    '\n', '\r' => {
                        if (commands.nth(self.state.paletteQuery(), self.state.palette_index)) |command| self.run(command.action);
                    },
                    'k', 'K' => {},
                    else => {
                        // Arrow keys arrive as private codepoints from surfaces:
                        // 0x11 up, 0x12 down.
                        if (codepoint == 0x11) {
                            if (self.state.palette_index > 0) self.state.palette_index -= 1;
                            return;
                        }
                        if (codepoint == 0x12) {
                            if (count > 0 and self.state.palette_index + 1 < count) self.state.palette_index += 1;
                            return;
                        }
                        if (codepoint == 0x7f or codepoint == 0x08) {
                            if (self.state.palette_query_len > 0) self.state.palette_query_len -= 1;
                            self.state.palette_index = 0;
                            return;
                        }
                        if (codepoint >= 32 and codepoint < 0x7f and self.state.palette_query_len < self.state.palette_query_buf.len) {
                            self.state.palette_query_buf[self.state.palette_query_len] = @intCast(codepoint);
                            self.state.palette_query_len += 1;
                            self.state.palette_index = 0;
                        }
                    },
                }
            },
            .appearance => {
                if (codepoint == 0x1b) {
                    self.state.dialog = .none;
                } else if (codepoint >= '1' and codepoint <= '6') {
                    self.applyTheme(@intCast(codepoint - '1'));
                } else if (codepoint == 0x11) {
                    const index = if (self.state.theme_index == 0) 5 else self.state.theme_index - 1;
                    self.applyTheme(index);
                } else if (codepoint == 0x12) {
                    self.applyTheme((self.state.theme_index + 1) % 6);
                }
            },
            .help => {
                if (codepoint == 0x1b or codepoint == '?') self.state.dialog = .none;
            },
            .none => {},
        }
    }

    fn openPalette(self: *App) void {
        self.state.dialog = .palette;
        self.state.palette_query_len = 0;
        self.state.palette_index = 0;
    }

    fn openDialog(self: *App, dialog: state_mod.Dialog) void {
        self.state.dialog = dialog;
    }

    fn setScreen(self: *App, screen: state_mod.Screen) void {
        self.state.screen = screen;
        self.state.scroll_y = 0;
        self.state.events_filter_focused = false;
    }

    fn run(self: *App, action: commands.Action) void {
        const from_palette = self.state.dialog == .palette;
        switch (action) {
            .screen => |screen| self.setScreen(screen),
            .open_journal => {
                self.state.dialog = .none;
                self.open_requested = true;
            },
            .reload => {
                self.state.dialog = .none;
                self.reload_requested = true;
            },
            .fit => self.fitTimeline(),
            .appearance => self.openDialog(.appearance),
            .theme => |index| self.applyTheme(index),
            .filter_events => {
                self.state.dialog = .none;
                self.setScreen(.events);
                self.state.events_filter_focused = true;
            },
            .help => self.openDialog(.help),
        }
        if (from_palette and self.state.dialog == .palette) self.state.dialog = .none;
    }

    fn applyTheme(self: *App, index: usize) void {
        if (index >= xsui.themes.presets.len) return;
        self.state.theme_index = index;
        var buf: [96]u8 = undefined;
        const name = xsui.themes.presets[index].name;
        self.showToast(std.fmt.bufPrint(&buf, "{s} theme", .{name}) catch "theme applied", false);
    }

    fn fitTimeline(self: *App) void {
        self.state.timeline_start = 0;
        self.state.timeline_end = self.model.summary.windowMs;
        self.state.timeline_playhead = 0;
        self.state.timeline_playing = false;
        if (self.state.screen != .timeline) self.setScreen(.timeline);
        self.showToast("full excerpt", false);
    }

    fn zoomTimeline(self: *App, factor: f64) void {
        if (self.state.screen != .timeline) self.setScreen(.timeline);
        const current_start = self.state.viewStart(self.model.summary.windowMs);
        const current_end = self.state.viewEnd(self.model.summary.windowMs);
        const center = if (self.state.timeline_playhead >= current_start and self.state.timeline_playhead <= current_end)
            self.state.timeline_playhead
        else
            (current_start + current_end) * 0.5;
        var span = @max(1.0, current_end - current_start);
        span = @max(300.0, @min(self.model.summary.windowMs, span * factor));
        var start = center - span * 0.5;
        if (start < 0) start = 0;
        if (start + span > self.model.summary.windowMs) start = @max(0, self.model.summary.windowMs - span);
        self.state.timeline_start = start;
        self.state.timeline_end = start + span;
    }

    fn showToast(self: *App, text_value: []const u8, is_error: bool) void {
        _ = is_error;
        const n = @min(text_value.len, self.toast_buf.len);
        @memcpy(self.toast_buf[0..n], text_value[0..n]);
        self.state.toast = self.toast_buf[0..n];
        self.state.toast_until_ms = self.now_ms + 1800;
    }

    fn syncQuery(self: *App) void {
        self.state.events_query = self.state.events_query_buf[0..self.state.events_query_len];
        self.state.events_selected = null;
    }

    pub fn tick(self: *App, delta_ms: u64) void {
        self.now_ms +|= delta_ms;
        if (self.state.toast != null and self.now_ms > self.state.toast_until_ms) self.state.toast = null;
        if (!self.state.timeline_playing or self.state.screen != .timeline) return;
        const start = self.state.viewStart(self.model.summary.windowMs);
        const end = self.state.viewEnd(self.model.summary.windowMs);
        const span = @max(1.0, end - start);
        self.state.timeline_playhead += @as(f64, @floatFromInt(delta_ms)) * span / 14000.0;
        if (self.state.timeline_playhead > end) self.state.timeline_playhead = start;
        if (self.state.timeline_playhead < start) self.state.timeline_playhead = start;
    }

    pub fn click(self: *App, canvas: *xsui.Canvas, x: f32, y: f32) void {
        if (canvas.hitAt(x, y)) |id| {
            if (id >= 700 and id < 720) {
                if (commands.nth(self.state.paletteQuery(), id - 700)) |command| self.run(command.action);
                return;
            }
            if (id >= 720 and id < 740) {
                self.applyTheme(id - 720);
                return;
            }
            if (id >= 100 and id < 105) {
                if (self.state.dialog != .none) return;
                const screens = [_]state_mod.Screen{ .overview, .timeline, .advisor, .events, .capture };
                self.setScreen(screens[id - 100]);
                return;
            }
            if (self.state.dialog != .none) return;
            switch (id) {
                200 => self.openPalette(),
                201 => self.openDialog(.appearance),
                202 => self.openDialog(.help),
                203 => self.open_requested = true,
                204 => self.reload_requested = true,
                300 => self.zoomTimeline(1.5),
                301 => self.zoomTimeline(0.75),
                302 => self.fitTimeline(),
                303 => self.state.timeline_playing = !self.state.timeline_playing,
                304 => self.setScreen(.advisor),
                400, 401, 402, 403, 404 => self.state.advisor_filter = @fromBackingInt(@intCast(id - 400)),
                520 => {
                    self.state.events_filter_focused = true;
                },
                600 => self.state.events_type = "all",
                601 => self.state.events_type = "sched_switch",
                602 => self.state.events_type = "sched_wakeup",
                603 => self.state.events_type = "sched_migrate",
                604 => self.state.events_type = "page_fault",
                605 => self.state.events_type = "cache_miss",
                606 => self.state.events_type = "loss",
                else => {
                    if (id >= 500 and id < 520 and id - 500 < self.model.events.len) {
                        self.state.events_selected = id - 500;
                    }
                },
            }
        }
    }
};

test "app boots with explicit empty source" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    try std.testing.expect(app.model.events.len == 0);
    app.handleKey('2', .{});
    try std.testing.expectEqual(state_mod.Screen.timeline, app.state.screen);
    app.handleKey('w', .{});
    try std.testing.expectEqual(state_mod.Dialog.appearance, app.state.dialog);
    app.handleKey(0x1b, .{});
    try std.testing.expectEqual(state_mod.Dialog.none, app.state.dialog);
}

test "app loads demo and plays timeline" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    try app.loadDemo(std.testing.io, "fixtures/ui/design/demo.json");
    try std.testing.expect(app.model.events.len > 1000);
    app.handleKey('2', .{});
    app.handleKey(' ', .{});
    app.tick(1000);
    try std.testing.expect(app.state.timeline_playhead > 0);
    app.handleKey('f', .{});
    try std.testing.expect(app.state.timeline_end == app.model.summary.windowMs);
}

test "live journal reload changes the displayed numbers" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    app.setLive(true);
    const first = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "fixtures/ui/healthy.ndjson", std.testing.allocator, .limited(4 * 1024 * 1024));
    defer std.testing.allocator.free(first);
    const second = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "fixtures/real/scheduler-mix.ndjson", std.testing.allocator, .limited(8 * 1024 * 1024));
    defer std.testing.allocator.free(second);
    try app.loadJournalData(first, "live sample");
    const first_switches = app.model.summary.switches;
    try std.testing.expectEqualStrings("LIVE", app.model.meta.source);
    try app.loadJournalData(second, "live sample");
    try std.testing.expect(app.model.summary.switches != first_switches);
    try std.testing.expectEqual(@as(u32, 4574), app.model.summary.switches);
    try std.testing.expect(app.model.slices.len > 100);
    try std.testing.expect(app.model.events.len == 12000);
}

test "stage scrolling clamps and resets on navigation" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    try app.loadDemo(std.testing.io, "fixtures/ui/design/demo.json");
    app.viewport_w = 1440;
    app.viewport_h = 900;
    app.scrollBy(100000);
    try std.testing.expect(app.state.scroll_y > 0);
    const clamped = app.state.scroll_y;
    app.scrollBy(100000);
    try std.testing.expectEqual(clamped, app.state.scroll_y);
    app.handleKey('2', .{});
    try std.testing.expectEqual(@as(f32, 0), app.state.scroll_y);
    app.scrollBy(-100000);
    try std.testing.expectEqual(@as(f32, 0), app.state.scroll_y);
}
