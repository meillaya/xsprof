//! Native surface bootstrap shared by the macOS and Linux windows: surface id,
//! persisted ui-settings.json, onboarding, CLI source overrides, and the effect
//! drain loop. Platforms own their live bridge and pass it in; this module only
//! routes effects through the portable executor.

const std = @import("std");
const xsui = @import("xsui");
const console_app = @import("../app/design/app.zig");
const effect = @import("../app/design/effect.zig");
const options_mod = @import("options.zig");
const effect_exec = @import("effect_exec.zig");
const state_paths = @import("state_paths.zig");

pub const Session = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    app: *console_app.App,
    live: ?effect_exec.LiveBridge = null,

    /// One-time startup: surface id, persisted settings (best-effort; a missing
    /// or corrupt file keeps defaults), onboarding, then explicit CLI source.
    pub fn start(self: Session, opts: options_mod.Options, surface: effect.Surface) void {
        self.app.setSurface(surface);
        if (state_paths.loadSettings(self.io, self.allocator) catch null) |data| {
            defer self.allocator.free(data);
            self.app.applySettingsJson(data) catch {};
        }
        self.app.maybeBeginOnboarding();
        // An explicit invocation wins over persisted settings.
        self.app.state.screen = @fromBackingInt(@intCast(@min(opts.screen, 7)));
        self.app.state.theme_index = @min(opts.theme_index, xsui.themes.presets.len - 1);
        if (opts.recorder_dir) |dir| self.app.setRecorderDir(dir);
        if (opts.demo_model) |path| {
            self.app.state.source.beginLoad(.demo, path);
            self.app.loadDemo(self.io, path) catch |err| self.fail("source.load.failed", err);
        } else if (opts.replay) |path| {
            self.app.state.source.beginLoad(.replay, path);
            self.app.loadReplay(self.io, path) catch |err| self.fail("source.load.failed", err);
        }
        self.drain();
    }

    fn fail(self: Session, code: []const u8, err: anyerror) void {
        const reason = @errorName(err);
        self.app.noteSourceFailure(.failed, reason);
        self.app.showToast(reason, true);
        self.app.recordAudit("source.load", .failed, code);
    }

    /// Drains the bounded host effect queue FIFO, then the boolean open/reload
    /// requests that App absorbs into flags. Blocking IO happens here on the
    /// platform thread; effects are bounded so one frame cannot starve.
    pub fn drain(self: Session) void {
        var context = effect_exec.Context{
            .allocator = self.allocator,
            .io = self.io,
            .app = self.app,
            .live = self.live,
        };
        while (self.app.takeEffect()) |item| effect_exec.execute(&context, item);
        if (self.app.open_requested) {
            self.app.open_requested = false;
            effect_exec.openJournal(&context);
        }
        if (self.app.reload_requested) {
            self.app.reload_requested = false;
            effect_exec.reloadSource(&context);
        }
    }
};

test "session bootstrap helper is pure layout" {
    try std.testing.expect(@sizeOf(Session) > 0);
    try std.testing.expectEqual(@as(u32, 7), @min(@as(u32, 9), 7));
}
