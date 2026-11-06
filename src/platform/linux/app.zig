//! Linux console surface state: draw/present, resize, pointer/key input, and
//! the monotonic idle tick. The X11/GLX plumbing lives in `x11.zig`; this file
//! owns everything that can be reasoned about without a window so the surface
//! stays small and the hidden `--smoke --resize` path exercises real code.

const std = @import("std");
const xsui = @import("xsui");
const gl = @import("xsui-gl");
const frame_mod = xsui.frame;
const console_app = @import("../../app/design/app.zig");
const focus_mod = @import("../../app/design/focus.zig");
const pointer_mod = @import("../../app/design/pointer.zig");
const options_mod = @import("../options.zig");
const recorder_mod = @import("../../app/design/recorder.zig");
const source_mod = @import("../../app/design/source.zig");
const live_mod = @import("../../app/design/live.zig");
const follow_source = @import("../follow_source.zig");
const session_mod = @import("../session.zig");
const state_paths = @import("../state_paths.zig");
const linux_live_source = @import("live_source.zig");
const events = @import("events.zig");
const xlib = @import("xlib.zig");

pub const App = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    x: xlib.X11,
    display: *xlib.Display,
    window: xlib.Window,
    context: *xlib.GLXContext,
    renderer: gl.Renderer,
    design: console_app.App,
    frame: frame_mod.Frame,
    canvas: xsui.Canvas,
    wm_delete: xlib.Atom,
    clipboard_atom: xlib.Atom,
    utf8_atom: xlib.Atom,
    targets_atom: xlib.Atom,
    clip_buf: [512]u8 = undefined,
    clip_len: usize = 0,
    /// Logical (1x) viewport. Retina/HiDPI is DEGRADED in this task.
    width: u32 = options_mod.default_width,
    height: u32 = options_mod.default_height,
    /// One present per idle iteration; input/resize/live mark it dirty.
    dirty: bool = true,
    last_tick_ns: i96 = 0,
    a11y: bool = false,
    a11y_dumped: bool = false,
    settings_loaded: bool = false,
    live_controller: ?live_mod.Controller = null,
    live_source: linux_live_source.Source = .{},
    follow_holder: follow_source.Source = .{},
    live_duration_ms: u32 = 0,
    live_preset_name: []const u8 = "scheduler",
    live_label: []const u8 = "live capture",
    live_dir_buf: [512]u8 = @splat(0),

    /// Draws the shared console and swaps. Clears per-frame hits first, so the
    /// tree and pointer hit test always describe the frame just drawn.
    pub fn present(self: *App) !void {
        self.frame.theme = self.design.theme();
        self.frame.list.clear();
        self.canvas.resetHits();
        try self.design.draw(&self.canvas);
        self.renderer.paint(
            self.frame.list.items.items,
            &self.frame.atlas,
            self.width,
            self.height,
            self.design.theme().bg,
        );
        self.x.swap_buffers(self.display, self.window);
        self.dirty = false;
    }

    /// Single resize path shared by ConfigureNotify, smoke injection, and
    /// future live/video paths. Returns true when the viewport changed.
    pub fn resize(self: *App, width: u32, height: u32) bool {
        if (width == 0 or height == 0) return false;
        const size = options_mod.clampSize(.{ .width = width, .height = height });
        if (size.width == self.width and size.height == self.height) return false;
        self.width = size.width;
        self.height = size.height;
        self.frame.resize(size.width, size.height);
        self.canvas.resetViewport();
        self.dirty = true;
        return true;
    }

    /// Monotonic frame delta (1..100 ms), so playback does not run at a fake
    /// fixed rate after a stall or a resize storm.
    pub fn tick(self: *App) void {
        const now = std.Io.Clock.now(.awake, self.io).nanoseconds;
        var delta_ms: u64 = 33;
        if (self.last_tick_ns != 0 and now > self.last_tick_ns) {
            const delta_ns = now - self.last_tick_ns;
            delta_ms = @intCast(@min(@divTrunc(delta_ns, std.time.ns_per_ms), 100));
            if (delta_ms == 0) delta_ms = 1;
        }
        self.last_tick_ns = now;
        self.design.tick(delta_ms);
        if (self.design.state.timeline_playing) self.dirty = true;
    }

    /// One idle step: monotonic tick, host-effect drain, and live poll. Blocking
    /// IO happens inside the bounded effect executor, never in a render path.
    pub fn idle(self: *App) !void {
        self.tick();
        self.drainEffects();
        self.pollLive();
        if (self.design.quit_requested) return;
    }

    fn ensureHits(self: *App) !void {
        if (!self.dirty) return;
        try self.present();
    }

    /// Translates one X event. Returns false when the window should close.
    pub fn handleEvent(self: *App, event: *const events.Event) !bool {
        switch (event.type) {
            events.key_press => return self.handleKeyPress(event),
            events.button_press => {
                const button = event.button.button;
                const px: f32 = @floatFromInt(event.button.x);
                const py: f32 = @floatFromInt(event.button.y);
                if (button == 4 or button == 5) {
                    self.design.scrollBy(if (button == 4) -120 else 120);
                    self.dirty = true;
                    return true;
                }
                try self.ensureHits();
                pointer_mod.pointerDown(&self.design, px, py);
                self.dirty = true;
            },
            events.button_release => {
                const px: f32 = @floatFromInt(event.button.x);
                const py: f32 = @floatFromInt(event.button.y);
                try self.ensureHits();
                pointer_mod.pointerUp(&self.design, &self.canvas, px, py);
                self.syncClipboard();
                self.dirty = true;
            },
            events.motion_notify => {
                const px: f32 = @floatFromInt(event.button.x);
                const py: f32 = @floatFromInt(event.button.y);
                pointer_mod.pointerMove(&self.design, px, py);
                self.dirty = true;
            },
            events.expose => self.dirty = true,
            events.configure_notify => {
                if (event.configure.width > 0 and event.configure.height > 0) {
                    _ = self.resize(@intCast(event.configure.width), @intCast(event.configure.height));
                }
            },
            events.selection_request => self.serveSelection(event.selection_request),
            events.client_message => {
                if (event.client.data.l[0] == @as(c_long, @intCast(self.wm_delete))) return false;
            },
            else => {},
        }
        if (self.design.quit_requested) return false;
        self.drainEffects();
        return true;
    }

    fn handleKeyPress(self: *App, event: *const events.Event) !bool {
        const sym = self.x.lookup_keysym(@ptrCast(&event.key), 0);
        const state = event.key.state;
        var cp: u21 = 0;
        switch (sym) {
            0xff1b => cp = 0x1b,
            0xff0d => cp = 0x0a,
            0xff09 => cp = 0x09,
            0xff08 => cp = 0x7f,
            0xff52 => cp = 0x11,
            0xff54 => cp = 0x12,
            0xff51 => cp = 0x13,
            0xff53 => cp = 0x14,
            else => {
                if (sym >= 32 and sym < 0x7f) cp = @intCast(sym);
            },
        }
        if ((state & 64) != 0 and (cp == 'q' or cp == 'Q')) return false;
        try self.ensureHits();
        const mods = console_app.Modifiers{
            .meta = (state & 64) != 0,
            .ctrl = (state & 4) != 0,
            .shift = (state & 1) != 0,
        };
        if (cp != 0 and !focus_mod.key(&self.design, &self.canvas, cp, mods.shift)) {
            self.design.handleKey(cp, mods);
        }
        self.syncClipboard();
        self.dirty = true;
        return true;
    }

    fn syncClipboard(self: *App) void {
        const text = self.design.copyText();
        if (text.len == 0) return;
        const len = @min(text.len, self.clip_buf.len);
        @memcpy(self.clip_buf[0..len], text[0..len]);
        self.clip_len = len;
        _ = self.x.set_selection_owner(self.display, self.clipboard_atom, self.window, 0);
        self.design.clearCopy();
    }

    fn serveSelection(self: *App, request: events.SelectionRequest) void {
        const property = if (request.property != 0) request.property else request.target;
        var utf8_list = [_]xlib.Atom{self.utf8_atom};
        if (request.target == self.targets_atom) {
            _ = self.x.change_property(self.display, request.requestor, property, 4, 32, 0, @ptrCast(&utf8_list), 1);
        } else if (self.clip_len > 0) {
            _ = self.x.change_property(self.display, request.requestor, property, self.utf8_atom, 8, 0, self.clip_buf[0..].ptr, @intCast(self.clip_len));
        }
        var notify = events.SelectionEvent{
            .type = 31,
            .serial = 0,
            .send_event = 0,
            .display = self.display,
            .requestor = request.requestor,
            .selection = request.selection,
            .target = request.target,
            .property = if (self.clip_len > 0 or request.target == self.targets_atom) property else 0,
            .time = request.time,
        };
        _ = self.x.send_event(self.display, request.requestor, 0, 0, @ptrCast(&notify));
        _ = self.x.flush(self.display);
    }

    /// Linux accessibility is JSON/DEGRADED: the design console's enriched tree
    /// is exported canonically, and this build ships no AT-SPI2 bridge.
    pub fn dumpA11y(self: *App) void {
        if (!self.a11y or self.a11y_dumped) return;
        self.a11y_dumped = true;
        const tree = self.design.accessibility();
        const json = self.design.accessibilityJson(self.allocator) catch {
            std.debug.print("a11y: DEGRADED reason=\"tree JSON failed\"\n", .{});
            return;
        };
        defer self.allocator.free(json);
        std.debug.print(
            "a11y: DEGRADED reason=\"no AT-SPI2 bridge in this build\" nodes={d} focusable={d} truncated={s}\n",
            .{ tree.len, tree.focusableCount(), if (tree.truncated) "true" else "false" },
        );
        std.debug.print("{s}\n", .{json});
    }

    pub fn sessionContext(self: *App) session_mod.Session {
        return .{
            .allocator = self.allocator,
            .io = self.io,
            .app = &self.design,
            .live = .{ .ctx = @ptrCast(self), .start = &liveStartThunk, .stop = &liveStopThunk },
        };
    }

    /// One-time startup: surface id, ui-settings.json, onboarding, CLI source.
    pub fn startSession(self: *App, opts: options_mod.Options) void {
        var session = self.sessionContext();
        session.start(opts, .linux);
        self.settings_loaded = true;
        if (opts.live) {
            const options = recorder_mod.Options{
                .duration_ms = @intCast(std.math.clamp(opts.duration_ms, 1000, 600_000)),
                .preset = recorder_mod.Preset.name(opts.preset) orelse .scheduler,
            };
            _ = self.liveStartBridge(self.io, self.allocator, options);
        } else if (opts.follow_recorder) |dir| {
            self.live_duration_ms = 0;
            self.follow_holder = .{ .dir = dir };
            _ = self.startController(self.follow_holder.source(), "recorder tail");
        }
    }

    /// Drains bounded host effects plus the open/reload flags. Called after
    /// input events and once per idle iteration.
    pub fn drainEffects(self: *App) void {
        var session = self.sessionContext();
        session.drain();
    }

    fn liveStartThunk(
        ctx: *anyopaque,
        io: std.Io,
        allocator: std.mem.Allocator,
        options: recorder_mod.Options,
    ) bool {
        const self: *App = @ptrCast(@alignCast(ctx));
        return self.liveStartBridge(io, allocator, options);
    }

    fn liveStopThunk(ctx: *anyopaque) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        self.stopLive();
    }

    pub fn liveStartBridge(
        self: *App,
        io: std.Io,
        allocator: std.mem.Allocator,
        options: recorder_mod.Options,
    ) bool {
        _ = io;
        self.live_duration_ms = options.duration_ms;
        self.live_preset_name = options.preset.label();
        // Recording mode when a recorder state dir is configured: one capture
        // (daemon writes compact segments) + tail for the live view. Empty dir
        // falls back to a view-only lab_worker stream.
        var dir_len: usize = 0;
        const configured = self.design.state.settings.recorderDirSlice();
        if (configured.len != 0) {
            dir_len = @min(configured.len, self.live_dir_buf.len);
            @memcpy(self.live_dir_buf[0..dir_len], configured[0..dir_len]);
        } else if (state_paths.recorderFallbackDir(allocator)) |fallback| {
            defer allocator.free(fallback);
            dir_len = @min(fallback.len, self.live_dir_buf.len);
            @memcpy(self.live_dir_buf[0..dir_len], fallback[0..dir_len]);
        } else |_| {}
        self.live_source = .{ .dir = self.live_dir_buf[0..dir_len] };
        return self.startController(self.live_source.source(), if (dir_len != 0) "live capture" else "live capture (view only)");
    }

    fn startController(self: *App, source: live_mod.Source, label: []const u8) bool {
        self.stopLive();
        // The live tail and the UI both use this allocator; it must be
        // thread-safe and freeing. The process arena used by the CLI is
        // neither, so a shared arena races under live catch-up/stop.
        self.live_controller = live_mod.Controller.init(std.heap.smp_allocator, self.io, .{});
        const controller = if (self.live_controller) |*value| value else return false;
        controller.attach(source, .{
            .duration_ms = self.live_duration_ms,
            .preset = self.live_preset_name,
        });
        self.live_label = label;
        if (!controller.start()) {
            const status = controller.statusView();
            const source_reason = self.live_source.reasonText();
            const reason = if (source_reason.len != 0)
                source_reason
            else if (status.reason.len != 0)
                status.reason
            else
                "live capture unavailable";
            self.design.recorderUnavailable(phaseFor(status.state), reason);
            controller.deinit();
            self.live_controller = null;
            return false;
        }
        self.design.setLive(true);
        self.design.state.source.kind = .live;
        self.design.state.source.path_len = 0;
        self.design.recorderStarted(label);
        return true;
    }

    pub fn stopLive(self: *App) void {
        if (self.live_controller) |*controller| {
            controller.stop();
            controller.deinit();
            self.live_controller = null;
        }
        self.design.setLive(false);
    }

    /// Polls the view-only live controller; never blocks the window loop.
    fn pollLive(self: *App) void {
        const controller = if (self.live_controller) |*value| value else return;
        const selection = live_mod.Selection{
            .slice = self.design.state.selected_slice,
            .event = self.design.state.events_selected,
        };
        const result = controller.poll(self.design.now_ms, selection);
        const status = controller.statusView();
        if (status.state == .stopped) {
            self.design.recorderStopped();
            self.stopLive();
            return;
        }
        if (status.state == .failed) {
            var reason = if (status.reason.len != 0) status.reason else "live capture failed";
            const source_reason = self.live_source.reasonText();
            if (source_reason.len != 0) reason = source_reason;
            self.design.noteSourceFailure(.failed, reason);
            self.design.recorderFailed(reason);
            self.stopLive();
            return;
        }
        if (!result.changed) return;
        const live_session = controller.sessionView() orelse return;
        const live_model = controller.view() orelse return;
        // The controller must stay alive while the console displays its model;
        // pollLive never stops it between frames, only on stop/finish/failure.
        self.design.applyLiveModel(live_session, live_model, result.selection.slice, result.selection.event);
        const stats = controller.statsView();
        self.design.state.recorder.events = stats.events;
        self.design.state.recorder.lost = stats.lost;
        self.design.state.recorder.window_ms = if (result.window_ms > 0) @intFromFloat(result.window_ms) else 0;
        // INTEGRATION HOOK: App.applyLiveModel(*const Session, *const Model,
        // LiveSelection) is not exposed by app.zig; recorder counters/status
        // stay honest until the Lead lands that API.
    }

    fn phaseFor(state: live_mod.State) source_mod.Phase {
        return switch (state) {
            .skip => .skipped,
            .failed => .failed,
            else => .refused,
        };
    }

    pub fn shutdownSession(self: *App) void {
        self.stopLive();
    }

    /// Hidden smoke for the live path: probe-gated capture or recorder tail,
    /// bounded controller, then one canonical status line. No window mapping.
    pub fn smokeLive(self: *App, opts: options_mod.Options) void {
        _ = opts;
        var iteration: usize = 0;
        while (iteration < 5) : (iteration += 1) {
            self.design.tick(120);
            self.pollLive();
            std.Io.sleep(self.io, .fromMilliseconds(120), .awake) catch {};
        }
        const controller = if (self.live_controller) |*value| value else {
            const unavailable = self.design.state.source;
            std.debug.print(
                "live smoke: state={s} reason=\"{s}\" indexed=0 rebuilt=0 lost=0\n",
                .{ @tagName(unavailable.phase), unavailable.reasonSlice() },
            );
            return;
        };
        const status = controller.statusView();
        const stats = controller.statsView();
        std.debug.print(
            "live smoke: state={s} reason=\"{s}\" source_events={d} indexed={d} rebuilt={d} lost={d}\n",
            .{ @tagName(status.state), status.reason, stats.source_events, stats.events, stats.rebuilds, stats.lost },
        );
        if (controller.view()) |model| {
            std.debug.print("live smoke: model events={d} window_ms={d:.3}\n", .{
                model.events.len,
                model.summary.windowMs,
            });
        }
    }
};
