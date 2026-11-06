//! Source-selection model for the product shell: what the console is showing,
//! which time frame was requested, and the explicit failure state. Pure data;
//! loading is performed by App/effect executors.
//!
//! TODO(platform): live streaming is owned by the native-runtime task; this
//! module only models the selection so Home/analysis share one state machine.

const std = @import("std");

pub const max_reason = 192;
pub const max_label = 96;
pub const max_path = 512;

pub const Kind = enum {
    demo,
    replay,
    recorder_window,
    live,

    pub fn label(self: Kind) []const u8 {
        return switch (self) {
            .demo => "Bundled capture",
            .replay => "Replay journal",
            .recorder_window => "Recorder window",
            .live => "Live capture",
        };
    }

    pub fn tag(self: Kind) []const u8 {
        return switch (self) {
            .demo => "DEMO",
            .replay => "REPLAY",
            .recorder_window => "WINDOW",
            .live => "LIVE",
        };
    }

    pub fn isFileBacked(self: Kind) bool {
        return switch (self) {
            .demo => false,
            .replay => true,
            .recorder_window => false,
            .live => false,
        };
    }
};

pub const Phase = enum { idle, loading, ready, skipped, refused, failed };

pub const WindowPreset = enum {
    one_minute,
    five_minutes,
    ten_minutes,
    retained,
    custom,

    pub fn label(self: WindowPreset) []const u8 {
        return switch (self) {
            .one_minute => "last 1m",
            .five_minutes => "last 5m",
            .ten_minutes => "last 10m",
            .retained => "retained",
            .custom => "custom",
        };
    }

    pub fn lastMs(self: WindowPreset, custom_ms: u64) ?u64 {
        return switch (self) {
            .one_minute => 60 * 1000,
            .five_minutes => 5 * 60 * 1000,
            .ten_minutes => 10 * 60 * 1000,
            .retained => null,
            .custom => if (custom_ms > 0) custom_ms else null,
        };
    }
};

pub const window_presets = [_]WindowPreset{ .one_minute, .five_minutes, .ten_minutes, .retained, .custom };

pub const Window = struct {
    preset: WindowPreset = .five_minutes,
    custom_ms: u64 = 0,

    pub fn lastMs(self: Window) ?u64 {
        return self.preset.lastMs(self.custom_ms);
    }

    pub fn describe(self: Window) []const u8 {
        return self.preset.label();
    }
};

pub const State = struct {
    kind: ?Kind = null,
    phase: Phase = .idle,
    window: Window = .{},
    path: [max_path]u8 = @splat(0),
    path_len: usize = 0,
    label: [max_label]u8 = @splat(0),
    label_len: usize = 0,
    reason: [max_reason]u8 = @splat(0),
    reason_len: usize = 0,

    pub fn pathSlice(self: *const State) []const u8 {
        return self.path[0..self.path_len];
    }

    pub fn labelSlice(self: *const State) []const u8 {
        return self.label[0..self.label_len];
    }

    pub fn reasonSlice(self: *const State) []const u8 {
        return self.reason[0..self.reason_len];
    }

    pub fn setPath(self: *State, path: []const u8) void {
        self.path_len = @min(path.len, self.path.len);
        @memcpy(self.path[0..self.path_len], path[0..self.path_len]);
    }

    pub fn setLabel(self: *State, text: []const u8) void {
        self.label_len = @min(text.len, self.label.len);
        @memcpy(self.label[0..self.label_len], text[0..self.label_len]);
    }

    pub fn beginLoad(self: *State, kind: Kind, path: []const u8) void {
        self.kind = kind;
        self.phase = .loading;
        self.setPath(path);
        self.setLabel(if (kind == .recorder_window) kind.label() else path);
        self.reason_len = 0;
    }

    pub fn ready(self: *State, label: []const u8) void {
        self.phase = .ready;
        self.setLabel(label);
        self.reason_len = 0;
    }

    pub fn fail(self: *State, phase: Phase, reason: []const u8) void {
        self.phase = phase;
        self.reason_len = @min(reason.len, self.reason.len);
        @memcpy(self.reason[0..self.reason_len], reason[0..self.reason_len]);
    }

    pub fn clear(self: *State) void {
        self.* = .{};
    }

    pub fn tag(self: *const State) []const u8 {
        return if (self.kind) |kind| kind.tag() else "EMPTY";
    }
};

test "window presets map to durations" {
    try std.testing.expectEqual(@as(?u64, 60_000), WindowPreset.one_minute.lastMs(0));
    try std.testing.expectEqual(@as(?u64, 600_000), WindowPreset.ten_minutes.lastMs(0));
    try std.testing.expectEqual(@as(?u64, null), WindowPreset.retained.lastMs(0));
    try std.testing.expectEqual(@as(?u64, null), WindowPreset.custom.lastMs(0));
    try std.testing.expectEqual(@as(?u64, 4321), WindowPreset.custom.lastMs(4321));
}

test "source state records path and reason" {
    var state = State{};
    try std.testing.expectEqualStrings("EMPTY", state.tag());
    state.beginLoad(.replay, "fixtures/ui/healthy.ndjson");
    try std.testing.expectEqual(Phase.loading, state.phase);
    try std.testing.expectEqualStrings("fixtures/ui/healthy.ndjson", state.pathSlice());
    state.ready("healthy");
    try std.testing.expectEqualStrings("healthy", state.labelSlice());
    state.fail(.refused, "another recorder holds the state lock");
    try std.testing.expectEqualStrings("another recorder holds the state lock", state.reasonSlice());
    state.clear();
    try std.testing.expectEqual(Phase.idle, state.phase);
}
