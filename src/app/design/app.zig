//! Shared console application: model ownership, source loading, the effect
//! queue, and delegation into the input/click adapters. Surfaces only
//! translate native events and drain effects.

const std = @import("std");
const xsui = @import("xsui");
const model_mod = @import("model.zig");
const state_mod = @import("state.zig");
const derive = @import("derive.zig");
const view_mod = @import("view.zig");
const effect = @import("effect.zig");
const action_mod = @import("action.zig");
const dispatch = @import("dispatch.zig");
const commands = @import("commands.zig");
const input_mod = @import("input.zig");
const click_mod = @import("click.zig");
const settings_mod = @import("settings.zig");
const audit_mod = @import("audit.zig");
const design_a11y = @import("a11y.zig");
const source_mod = @import("source.zig");
const session_mod = @import("../../stream/session.zig");
const extract = @import("../../recorder/extract.zig");
const recorder_window = @import("../../recorder/window.zig");
const manifest_mod = @import("../../recorder/manifest.zig");

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
    /// Stable labels/roles for the current frame. The canvas hits below point
    /// into this tree until the next draw, so native a11y bridges never borrow
    /// a freed frame arena.
    a11y_tree: design_a11y.Tree = .{},
    source_path: ?[]const u8 = null,
    recorder_dir: ?[]const u8 = null,
    open_requested: bool = false,
    reload_requested: bool = false,
    quit_requested: bool = false,
    live: bool = false,
    now_ms: u64 = 0,
    viewport_w: u32 = 1440,
    viewport_h: u32 = 900,
    surface: effect.Surface = .snapshot,
    host_effects: [effect.max_effects]effect.Effect = @splat(.none),
    host_effect_count: u8 = 0,
    host_effects_overflow: bool = false,
    toast_buf: [96]u8 = undefined,
    copy_buf: [512]u8 = undefined,
    copy_len: usize = 0,

    pub fn init(backing: std.mem.Allocator) App {
        return .{
            .backing = backing,
            .arena = std.heap.ArenaAllocator.init(backing),
            .model = .{ .meta = .{ .host = "no source", .source = "EMPTY", .fixture = "" } },
        };
    }

    pub fn deinit(self: *App) void {
        self.arena.deinit();
        if (self.source_path) |path| self.backing.free(path);
    }

    pub fn setSurface(self: *App, surface: effect.Surface) void {
        self.surface = surface;
    }

    pub fn setLive(self: *App, value: bool) void {
        self.live = value;
    }

    pub fn copyText(self: *const App) []const u8 {
        return self.copy_buf[0..self.copy_len];
    }

    pub fn clearCopy(self: *App) void {
        self.copy_len = 0;
    }

    pub fn requestCopy(self: *App, text_value: []const u8) void {
        const len = @min(text_value.len, self.copy_buf.len);
        @memcpy(self.copy_buf[0..len], text_value[0..len]);
        self.copy_len = len;
    }

    pub fn setRecorderDir(self: *App, dir: []const u8) void {
        self.recorder_dir = dir;
        self.state.settings.setRecorderDir(dir);
    }

    pub fn loadRecorderData(self: *App, data: []const u8) !void {
        const owned = try self.arena.allocator().dupe(u8, data);
        var manifest = try manifest_mod.parse(self.arena.allocator(), owned);
        try derive.applyRecorder(self.arena.allocator(), &self.model, &manifest);
        self.state.recorder.external = true;
        self.state.recorder.retained_ms = 0;
        self.state.recorder.cap_ms = manifest.max_age_ms;
        self.state.recorder.segments = @intCast(@min(manifest.segments.len, std.math.maxInt(u32)));
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
            if (try manifest_mod.read(io, self.arena.allocator(), manifest_path)) |manifest| {
                try derive.applyRecorder(self.arena.allocator(), &model, &manifest);
            }
        }
        self.session = session;
        self.model = model;
        self.resetView();
        self.state.source.ready(path);
    }

    /// Recorder-window source: extract the last N ms from a recorder state dir,
    /// then derive the console model from the extracted journal.
    /// TODO(platform): called by the Linux recorder executor in response to an
    /// Effect.extract_window; non-Linux surfaces must fail closed before reaching it.
    pub fn loadRecorderWindow(self: *App, io: std.Io, dir: []const u8, last_ms: u64) !void {
        self.arena.deinit();
        self.arena = std.heap.ArenaAllocator.init(self.backing);
        self.session = null;
        if (self.source_path) |old| self.backing.free(old);
        self.source_path = null;
        const bounded = try recorder_window.load(io, self.arena.allocator(), .{
            .dir = dir,
            .last_ms = last_ms,
            .max_events = 200_000,
            .max_bytes = 64 * 1024 * 1024,
        });
        const label = if (bounded.truncated)
            try std.fmt.allocPrint(self.arena.allocator(), "{s} last={d}ms sampled={d} truncated", .{ dir, last_ms, bounded.events })
        else
            try std.fmt.allocPrint(self.arena.allocator(), "{s} last={d}ms events={d}", .{ dir, last_ms, bounded.events });
        const session = try session_mod.Session.fromData(self.arena.allocator(), label, bounded.data);
        self.state.recorder.retained_ms = bounded.covered_ms;
        self.state.recorder.events = bounded.events;
        self.state.recorder.segments = bounded.segments;
        var model = try derive.fromSession(self.arena.allocator(), &session, .{
            .fixture = dir,
            .source = "WINDOW",
            .capture_window = label,
        });
        const manifest_path = try std.fmt.allocPrint(self.arena.allocator(), "{s}/manifest.json", .{dir});
        if (try manifest_mod.read(io, self.arena.allocator(), manifest_path)) |manifest| {
            try derive.applyRecorder(self.arena.allocator(), &model, &manifest);
            self.state.recorder.cap_ms = manifest.max_age_ms;
            self.state.recorder.segments = @intCast(@min(manifest.segments.len, std.math.maxInt(u32)));
        }
        self.session = session;
        self.model = model;
        self.resetView();
        self.state.source.ready(label);
    }

    pub fn loadJournalData(self: *App, data: []const u8, source: []const u8) !void {
        self.arena.deinit();
        self.arena = std.heap.ArenaAllocator.init(self.backing);
        self.session = null;
        if (self.source_path) |old| self.backing.free(old);
        self.source_path = null;
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
        self.state.source.ready(source);
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
        self.state.source.ready("bundled capture");
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
        self.state.source.ready(path);
    }

    pub fn clearSource(self: *App) void {
        self.arena.deinit();
        self.arena = std.heap.ArenaAllocator.init(self.backing);
        self.session = null;
        if (self.source_path) |old| self.backing.free(old);
        self.source_path = null;
        self.model = .{ .meta = .{ .host = "no source", .source = "EMPTY", .fixture = "" }, .summary = .{ .windowMs = 0 } };
        self.state.source.clear();
        self.resetView();
    }

    fn resetView(self: *App) void {
        self.state.resetView(self.model.summary.windowMs);
    }

    pub fn draw(self: *App, canvas: *xsui.Canvas) !void {
        self.viewport_w = canvas.frame.width;
        self.viewport_h = canvas.frame.height;
        try view_mod.view(&self.model, &self.state, canvas);
        self.enrichA11y(canvas);
    }

    /// Give the canvas hit pass the same semantic labels as the accessibility
    /// tree. The canvas remains the single source for pointer, focus, and AX.
    fn enrichA11y(self: *App, canvas: *xsui.Canvas) void {
        design_a11y.build(&self.model, &self.state, canvas, &self.a11y_tree);
        for (canvas.hits.items) |*hit| {
            const node = self.a11y_tree.find(hit.id) orelse continue;
            hit.role = mapRole(node.role);
            hit.label = node.labelSlice();
            hit.value = node.valueSlice();
            hit.flags = .{
                .interactive = node.focusable,
                .focusable = node.focusable,
                .disabled = node.disabled,
                .selected = node.selected,
                .expanded = node.expanded,
            };
        }
    }

    fn mapRole(role: design_a11y.Role) xsui.a11y.Role {
        return switch (role) {
            .window => .window,
            .tablist => .tab_list,
            .tab => .tab,
            .tabpanel => .group,
            .button => .button,
            .textbox => .text_field,
            .list => .list,
            .listitem => .list_item,
            .dialog => .dialog,
            .status => .status,
            .heading => .static_text,
            .progressbar => .status,
        };
    }

    pub fn scrollBy(self: *App, delta: f32) void {
        const stage_h: f32 = @as(f32, @floatFromInt(self.viewport_h)) - 82.0;
        const compact = self.viewport_w <= 780;
        const content_h: f32 = switch (self.state.screen) {
            .home => if (compact) 1500.0 else 980.0,
            .overview => if (compact) 2460.0 else if (self.viewport_w >= 1320) 1104.0 else 1600.0,
            .timeline => if (self.viewport_w <= 1140) 1120.0 else 640.0,
            .advisor => if (self.viewport_w <= 1024) 1710.0 else 1010.0,
            .events => if (self.viewport_w <= 1140) 1510.0 else 780.0,
            .capture => if (self.viewport_w <= 1024) 1484.0 else 964.0,
            .audit => if (compact) 1700.0 else 1080.0,
            .settings => if (compact) 1900.0 else 1180.0,
        };
        const max_scroll = @max(0.0, content_h - stage_h);
        self.state.scroll_y = std.math.clamp(self.state.scroll_y + delta, 0, max_scroll);
    }

    /// Single dispatch entry used by keys, clicks and tests.
    pub fn applyAction(self: *App, act: action_mod.Action) void {
        switch (act) {
            .copy_selection => return self.copySelection(),
            .fit => return self.fitTimeline(),
            .zoom => |factor| return self.zoomTimeline(factor),
            .jump_end => return self.jumpTimelineEnd(),
            else => {},
        }
        const was_palette = self.state.dialog == .palette;
        const batch = dispatch.reduce(&self.state, self.surface, act);
        self.absorb(batch);
        if (was_palette and self.state.dialog == .palette) self.applyAction(.close_dialog);
    }

    /// Palette rows resolve to the same actions as keys and clicks.
    pub fn runPaletteCommand(self: *App, index: usize) void {
        if (commands.nth(self.state.paletteQuery(), index)) |command| self.applyAction(command.action);
    }

    fn absorb(self: *App, batch: effect.Batch) void {
        for (batch.slice()) |item| {
            switch (item) {
                .none => {},
                .notify => |notice| self.showToast(notice.text.slice(), notice.is_error),
                .copy_text => |text| self.requestCopy(text.slice()),
                .refusal => |refusal| {
                    self.showToast(refusal.reason, true);
                    self.recordAudit("action.refused", .refused, refusal.code);
                },
                .append_audit => |entry| {
                    self.state.audit.entries[self.state.audit.head] = entry;
                    self.state.audit.head = (self.state.audit.head + 1) % audit_mod.max_entries;
                    if (self.state.audit.len < audit_mod.max_entries) self.state.audit.len += 1;
                },
                .open_journal => self.open_requested = true,
                .reload_source => self.reload_requested = true,
                .save_settings, .verify_recorder => self.pushEffect(item),
                .load_path, .load_demo, .list_dir, .start_capture, .stop_capture, .extract_window, .export_file, .export_audit => self.pushEffect(item),
            }
        }
    }

    fn pushEffect(self: *App, item: effect.Effect) void {
        if (self.host_effect_count >= effect.max_effects) {
            self.host_effects_overflow = true;
            self.showToast("host effect queue is full", true);
            return;
        }
        self.host_effects[self.host_effect_count] = item;
        self.host_effect_count += 1;
    }

    /// Surfaces drain effects FIFO; unsupported effects must be converted to a
    /// fail-closed refusal by the surface executor.
    pub fn takeEffect(self: *App) ?effect.Effect {
        if (self.host_effect_count == 0) return null;
        const item = self.host_effects[0];
        var index: usize = 1;
        while (index < self.host_effect_count) : (index += 1) {
            self.host_effects[index - 1] = self.host_effects[index];
        }
        self.host_effect_count -= 1;
        self.host_effects[self.host_effect_count] = .none;
        return item;
    }

    pub fn pendingEffectCount(self: *const App) usize {
        return self.host_effect_count;
    }

    pub fn recordAudit(self: *App, action: []const u8, outcome: audit_mod.Outcome, code: []const u8) void {
        const kind = if (self.state.source.kind) |source_kind| source_kind.tag() else "none";
        self.state.audit.append(self.now_ms, action, outcome, code, kind);
    }

    pub fn applySettingsJson(self: *App, data: []const u8) !void {
        var scratch = std.heap.ArenaAllocator.init(self.backing);
        defer scratch.deinit();
        const parsed = try settings_mod.parse(scratch.allocator(), data);
        self.state.settings = parsed;
        self.state.theme_index = parsed.theme_index;
        self.state.onboarding.completed_version = parsed.onboarding_version;
        if (self.state.source.kind) |kind| self.state.settings.last_source = kind;
        self.recordAudit("settings.load", .ok, "");
    }

    pub fn settingsJson(self: *App, allocator: std.mem.Allocator) ![]u8 {
        var out = std.Io.Writer.Allocating.init(allocator);
        errdefer out.deinit();
        try settings_mod.writeJson(&out.writer, &self.state.settings);
        return out.toOwnedSlice();
    }

    pub fn maybeBeginOnboarding(self: *App) void {
        self.state.onboarding.beginIfDue();
        if (self.state.onboarding.active) self.state.dialog = .onboarding;
    }

    pub fn noteSourceFailure(self: *App, phase: source_mod.Phase, reason: []const u8) void {
        self.state.source.fail(phase, reason);
    }

    pub fn recorderStarted(self: *App, label: []const u8) void {
        self.state.recorder.started(label);
        self.state.source.ready(label);
        self.showToast("capture started", false);
    }

    /// Adopt a live controller model without resetting the view. The model and
    /// session are shallow views into the controller arena; the platform calls
    /// this immediately after every successful poll on the UI thread, before
    /// the next draw and before the controller rebuilds again. The controller
    /// must stay alive while the console displays this model.
    pub fn applyLiveModel(
        self: *App,
        live_session: *const session_mod.Session,
        live_model: *const Model,
        selected_slice: ?u32,
        selected_event: ?usize,
    ) void {
        const previous_window = self.model.summary.windowMs;
        self.model = live_model.*;
        self.session = live_session.*;
        self.live = true;
        self.state.source.kind = .live;
        self.state.source.ready("live capture");
        if (self.state.timeline_end <= previous_window) self.state.timeline_end = self.model.summary.windowMs;
        if (self.state.timeline_start > self.state.timeline_end) self.state.timeline_start = 0;
        self.state.selected_slice = selected_slice;
        self.state.events_selected = selected_event;
    }

    pub fn recorderStopped(self: *App) void {
        const restart = self.state.recorder.takeRestart();
        self.state.recorder.stopped();
        if (restart) {
            switch (self.state.recorder.begin(self.state.recorder.options)) {
                .run => self.pushEffect(.{ .start_capture = self.state.recorder.options }),
                .refuse => |refusal| self.showToast(refusal.reason, true),
                .none => {},
            }
            self.showToast("capture restarted", false);
        } else {
            self.showToast("capture stopped", false);
        }
    }

    pub fn recorderFailed(self: *App, reason: []const u8) void {
        self.state.recorder.fail(reason);
        self.showToast(reason, true);
        self.recordAudit("capture.failed", .failed, reason);
    }

    /// Probe or worker unavailability. A missing capability or an external
    /// ownership conflict is SKIP/REFUSE, not a failed recording attempt.
    pub fn recorderUnavailable(self: *App, phase: source_mod.Phase, reason: []const u8) void {
        switch (phase) {
            .skipped => self.state.recorder.skip(reason),
            .refused => self.state.recorder.refuse(reason),
            else => self.state.recorder.fail(reason),
        }
        self.state.source.fail(phase, reason);
        self.showToast(reason, true);
        self.recordAudit("capture.unavailable", .failed, reason);
    }

    pub fn showToast(self: *App, text_value: []const u8, is_error: bool) void {
        const n = @min(text_value.len, self.toast_buf.len);
        @memcpy(self.toast_buf[0..n], text_value[0..n]);
        self.state.toast = self.toast_buf[0..n];
        self.state.toast_error = is_error;
        self.state.toast_until_ms = self.now_ms + 2400;
    }

    fn copySelection(self: *App) void {
        if (self.state.selected_slice) |id| {
            if (id < self.model.slices.len) {
                const slice = self.model.slices[id];
                const text_value = std.fmt.bufPrint(&self.copy_buf, "{s} pid {d} cpu{d} {d:.2} ms", .{ slice.comm, slice.pid, slice.cpu, slice.dur }) catch return;
                self.copy_len = text_value.len;
                self.showToast("slice summary copied", false);
            }
        }
    }

    fn fitTimeline(self: *App) void {
        self.state.timeline_start = 0;
        self.state.timeline_end = self.model.summary.windowMs;
        self.state.timeline_playhead = 0;
        self.state.timeline_playing = false;
        if (self.state.screen != .timeline) self.state.screen = .timeline;
        self.showToast("full excerpt", false);
    }

    fn zoomTimeline(self: *App, factor: f64) void {
        if (self.state.screen != .timeline) self.state.screen = .timeline;
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

    fn jumpTimelineEnd(self: *App) void {
        if (self.state.screen != .timeline) self.state.screen = .timeline;
        self.state.timeline_playhead = self.state.viewEnd(self.model.summary.windowMs);
    }

    pub fn handleKey(self: *App, codepoint: u21, mods: Modifiers) void {
        input_mod.handleKey(self, codepoint, mods);
    }

    pub fn click(self: *App, canvas: *xsui.Canvas, x: f32, y: f32) void {
        click_mod.handle(self, canvas, x, y);
    }

    /// The last frame's accessibility tree. The macOS bridge and snapshots
    /// consume this; it is rebuilt by draw() and owns bounded label copies.
    pub fn accessibility(self: *App) *const design_a11y.Tree {
        return &self.a11y_tree;
    }

    pub fn accessibilityJson(self: *App, allocator: std.mem.Allocator) ![]u8 {
        var out = std.Io.Writer.Allocating.init(allocator);
        errdefer out.deinit();
        try design_a11y.writeJson(&out.writer, &self.a11y_tree);
        return out.toOwnedSlice();
    }

    pub fn tick(self: *App, delta_ms: u64) void {
        self.now_ms +|= delta_ms;
        self.state.now_ms = self.now_ms;
        if (self.state.toast != null and self.now_ms > self.state.toast_until_ms) self.state.toast = null;
        if (!self.state.timeline_playing or self.state.screen != .timeline) return;
        const start = self.state.viewStart(self.model.summary.windowMs);
        const end = self.state.viewEnd(self.model.summary.windowMs);
        const span = @max(1.0, end - start);
        self.state.timeline_playhead += @as(f64, @floatFromInt(delta_ms)) * span / 14000.0;
        if (self.state.timeline_playhead > end) self.state.timeline_playhead = start;
        if (self.state.timeline_playhead < start) self.state.timeline_playhead = start;
    }
};
