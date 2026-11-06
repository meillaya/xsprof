//! Pure recorder-management state machine for the Recorder screen and the
//! Home recorder strip. The executor (platform layer) owns the actual capture
//! worker; this module only decides transitions and emits commands.
//!
//! TODO(platform): wire Effect.start_capture/stop_capture/extract_window to
//! src/capture/lab_worker.zig + live_feed.Store (native Linux) and fail closed
//! elsewhere. Restart of an externally owned recorder is attach-only.

const std = @import("std");

pub const max_reason = 192;
pub const max_label = 96;

pub const Preset = enum {
    scheduler,
    memory,
    deep,

    pub fn label(self: Preset) []const u8 {
        return switch (self) {
            .scheduler => "scheduler",
            .memory => "memory",
            .deep => "deep",
        };
    }

    pub fn name(text: []const u8) ?Preset {
        inline for (@typeInfo(Preset).@"enum".field_names) |field| {
            if (std.ascii.eqlIgnoreCase(text, field)) return @field(Preset, field);
        }
        return null;
    }
};

pub const Options = struct {
    duration_ms: u32 = 5000,
    preset: Preset = .scheduler,
};

pub const Phase = enum {
    idle,
    starting,
    running,
    stopping,
    skipped,
    refused,
    failed,

    pub fn label(self: Phase) []const u8 {
        return switch (self) {
            .idle => "IDLE",
            .starting => "STARTING",
            .running => "RECORDING",
            .stopping => "STOPPING",
            .skipped => "SKIP",
            .refused => "REFUSE",
            .failed => "FAILED",
        };
    }

    pub fn isBusy(self: Phase) bool {
        return self == .starting or self == .stopping;
    }

    pub fn isActive(self: Phase) bool {
        return self == .starting or self == .running or self == .stopping;
    }
};

pub const Command = enum { start, stop, restart, extract, attach, export_journal, export_trace, export_report, export_incident };

pub const Decision = union(enum) {
    none,
    run: Command,
    refuse: struct { code: []const u8, reason: []const u8 },
};

pub const State = struct {
    phase: Phase = .idle,
    options: Options = .{},
    events: u64 = 0,
    lost: u64 = 0,
    window_ms: u64 = 0,
    session_label: [max_label]u8 = @splat(0),
    session_label_len: usize = 0,
    reason: [max_reason]u8 = @splat(0),
    reason_len: usize = 0,
    /// True when this UI process owns the capture worker.
    owned: bool = false,
    /// True when attached to an externally managed recorder state dir.
    external: bool = false,
    /// Set when a restart is waiting for the stop completion.
    restart_pending: bool = false,
    retained_ms: u64 = 0,
    cap_ms: u64 = 0,
    segments: u32 = 0,

    pub fn reasonSlice(self: *const State) []const u8 {
        return self.reason[0..self.reason_len];
    }

    pub fn sessionSlice(self: *const State) []const u8 {
        return self.session_label[0..self.session_label_len];
    }

    pub fn begin(self: *State, options: Options) Decision {
        if (self.phase.isActive()) {
            return .{ .refuse = .{ .code = "capture.busy", .reason = "a capture is already active" } };
        }
        self.options = options;
        self.phase = .starting;
        self.events = 0;
        self.lost = 0;
        self.window_ms = 0;
        self.reason_len = 0;
        self.owned = true;
        self.external = false;
        return .{ .run = .start };
    }

    pub fn started(self: *State, label: []const u8) void {
        self.phase = .running;
        self.reason_len = 0;
        self.session_label_len = @min(label.len, self.session_label.len);
        @memcpy(self.session_label[0..self.session_label_len], label[0..self.session_label_len]);
    }

    pub fn progress(self: *State, events: u64, lost: u64, window_ms: u64) void {
        if (!self.phase.isActive()) return;
        self.events = events;
        self.lost = lost;
        self.window_ms = window_ms;
    }

    pub fn requestStop(self: *State) Decision {
        if (!self.phase.isActive()) {
            return .{ .refuse = .{ .code = "capture.not_running", .reason = "no capture is running" } };
        }
        if (self.phase == .stopping) return .none;
        self.phase = .stopping;
        return .{ .run = .stop };
    }

    pub fn stopped(self: *State) void {
        self.phase = .idle;
        self.owned = false;
    }

    /// Stop completion handshake: true when the caller should start again.
    pub fn takeRestart(self: *State) bool {
        const pending = self.restart_pending;
        self.restart_pending = false;
        return pending;
    }

    pub fn requestRestart(self: *State) Decision {
        if (!self.owned and self.external) {
            return .{ .refuse = .{ .code = "capture.external", .reason = "recorder is managed externally; restart it with its service manager or CLI" } };
        }
        if (self.phase.isActive()) {
            self.phase = .stopping;
            self.restart_pending = true;
            return .{ .run = .stop };
        }
        return self.begin(self.options);
    }

    pub fn extract(self: *State) Decision {
        if (self.phase.isActive()) {
            return .{ .refuse = .{ .code = "capture.busy", .reason = "stop the capture before extracting a window" } };
        }
        return .{ .run = .extract };
    }

    pub fn requestExport(self: *State, command: Command) Decision {
        if (command != .export_journal and command != .export_trace and
            command != .export_report and command != .export_incident)
        {
            return .none;
        }
        if (self.phase.isActive()) {
            return .{ .refuse = .{ .code = "capture.busy", .reason = "stop the capture before exporting" } };
        }
        return .{ .run = command };
    }

    pub fn skip(self: *State, reason: []const u8) void {
        self.phase = .skipped;
        self.reason_len = @min(reason.len, self.reason.len);
        @memcpy(self.reason[0..self.reason_len], reason[0..self.reason_len]);
    }

    pub fn refuse(self: *State, reason: []const u8) void {
        self.phase = .refused;
        self.reason_len = @min(reason.len, self.reason.len);
        @memcpy(self.reason[0..self.reason_len], reason[0..self.reason_len]);
    }

    pub fn fail(self: *State, reason: []const u8) void {
        self.phase = .failed;
        self.reason_len = @min(reason.len, self.reason.len);
        @memcpy(self.reason[0..self.reason_len], reason[0..self.reason_len]);
    }

    pub fn coverageText(self: *const State, buf: []u8) []const u8 {
        const covered = if (self.window_ms > 0) self.window_ms else self.retained_ms;
        return std.fmt.bufPrint(buf, "{d}.{d}s / cap {d}.{d}m", .{
            covered / 1000,
            (covered % 1000) / 100,
            self.cap_ms / 60_000,
            (self.cap_ms % 60_000) / 6_000,
        }) catch "window unavailable";
    }
};

test "recorder lifecycle transitions" {
    var state = State{};
    try std.testing.expectEqual(Phase.idle, state.phase);
    switch (state.begin(.{ .duration_ms = 1000 })) {
        .run => |cmd| try std.testing.expectEqual(Command.start, cmd),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(Phase.starting, state.phase);
    state.started("live capture");
    try std.testing.expectEqualStrings("live capture", state.sessionSlice());
    state.progress(10, 0, 250);
    switch (state.requestStop()) {
        .run => |cmd| try std.testing.expectEqual(Command.stop, cmd),
        else => return error.TestUnexpectedResult,
    }
    state.stopped();
    try std.testing.expectEqual(Phase.idle, state.phase);
}

test "external recorder restart fails closed" {
    var state = State{ .external = true, .phase = .idle };
    switch (state.requestRestart()) {
        .refuse => |refusal| {
            try std.testing.expectEqualStrings("capture.external", refusal.code);
            try std.testing.expect(refusal.reason.len != 0);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "extract and export refuse while capture is active" {
    var state = State{ .phase = .running };
    switch (state.extract()) {
        .refuse => |r| try std.testing.expectEqualStrings("capture.busy", r.code),
        else => return error.TestUnexpectedResult,
    }
    switch (state.requestExport(.export_trace)) {
        .refuse => |r| try std.testing.expectEqualStrings("capture.busy", r.code),
        else => return error.TestUnexpectedResult,
    }
    state.phase = .idle;
    switch (state.requestExport(.export_trace)) {
        .run => |cmd| try std.testing.expectEqual(Command.export_trace, cmd),
        else => return error.TestUnexpectedResult,
    }
}
