//! Pure GUI lab state. The reducer owns no file handles, threads, or renderer
//! state; it only updates bounded fields and returns effects for an executor.

const std = @import("std");
const action = @import("action.zig");
const app_state = @import("../app_state.zig");
const session_mod = @import("../../stream/session.zig");

pub const max_path = 1024;
pub const max_reason = 256;
pub const max_toast = 128;
pub const max_query = 64;

pub const SourcePhase = enum { none, loading, ready, failed };
pub const CapturePhase = enum { idle, starting, running, stopping, skipped, refused, failed };
pub const ToastKind = enum { none, info, success, toast_error };
pub const ScenarioStatus = enum { none, ready, running, passed, failed };

pub const SourceState = struct {
    kind: action.SourceKind = .replay,
    phase: SourcePhase = .none,
    path: [max_path]u8 = @splat(0),
    path_len: usize = 0,
    reason: [max_reason]u8 = @splat(0),
    reason_len: usize = 0,

    pub fn pathSlice(self: *const SourceState) []const u8 {
        return self.path[0..self.path_len];
    }

    pub fn reasonSlice(self: *const SourceState) []const u8 {
        return self.reason[0..self.reason_len];
    }
};

pub const CaptureState = struct {
    phase: CapturePhase = .idle,
    preset: action.CapturePreset = .scheduler,
    duration_ms: u32 = 0,
    events: u64 = 0,
    lost: u64 = 0,
    cpu_bp: u32 = 0,
    rss_kb: u64 = 0,
    reason: [max_reason]u8 = @splat(0),
    reason_len: usize = 0,

    pub fn reasonSlice(self: *const CaptureState) []const u8 {
        return self.reason[0..self.reason_len];
    }
};

pub const TransportState = struct {
    playing: bool = false,
    speed: f32 = 1.0,
    cursor_us: u64 = 0,
    follow: bool = true,
};

pub const PaletteState = struct {
    open: bool = false,
    query: [max_query]u8 = @splat(0),
    query_len: usize = 0,
    selected: usize = 0,
};

pub const ScenarioState = struct {
    id: [64]u8 = @splat(0),
    id_len: usize = 0,
    step: usize = 0,
    total: usize = 0,
    status: ScenarioStatus = .none,
    failed_assertion: [max_reason]u8 = @splat(0),
    failed_len: usize = 0,

    pub fn idSlice(self: *const ScenarioState) []const u8 {
        return self.id[0..self.id_len];
    }

    pub fn failedSlice(self: *const ScenarioState) []const u8 {
        return self.failed_assertion[0..self.failed_len];
    }
};

fn copyBounded(dest: []u8, text: []const u8) usize {
    const len = @min(dest.len, text.len);
    @memcpy(dest[0..len], text[0..len]);
    return len;
}

pub const LabState = struct {
    allocator: std.mem.Allocator,
    empty_arena: std.heap.ArenaAllocator,
    empty_session: *session_mod.Session,
    view: app_state.State,
    source: SourceState = .{},
    capture: CaptureState = .{},
    transport: TransportState = .{},
    scenario: ScenarioState = .{},
    palette: PaletteState = .{},
    focus: action.Focus = .screen,
    active_panel: action.LabPanel = .source,
    input_focus: action.InputField = .none,
    source_input: [max_path]u8 = @splat(0),
    source_input_len: usize = 0,
    export_input: [max_path]u8 = @splat(0),
    export_input_len: usize = 0,
    rail_open: bool = true,
    host_controls: bool = true,
    quit_requested: bool = false,
    toast: [max_toast]u8 = @splat(0),
    toast_len: usize = 0,
    toast_kind: ToastKind = .none,

    pub fn init(allocator: std.mem.Allocator) !LabState {
        var empty_arena = std.heap.ArenaAllocator.init(allocator);
        errdefer empty_arena.deinit();
        const empty = try allocator.create(session_mod.Session);
        errdefer allocator.destroy(empty);
        empty.* = try session_mod.Session.fromData(empty_arena.allocator(), "no source", "");
        return .{
            .allocator = allocator,
            .empty_arena = empty_arena,
            .empty_session = empty,
            .view = .{ .session = empty },
        };
    }

    pub fn deinit(self: *LabState) void {
        self.empty_arena.deinit();
        self.allocator.destroy(self.empty_session);
    }

    pub fn toastSlice(self: *const LabState) []const u8 {
        return self.toast[0..self.toast_len];
    }

    pub fn sourceInputSlice(self: *const LabState) []const u8 {
        return self.source_input[0..self.source_input_len];
    }

    pub fn exportInputSlice(self: *const LabState) []const u8 {
        return self.export_input[0..self.export_input_len];
    }

    pub fn apply(self: *LabState, msg: action.Msg) !action.EffectBatch {
        return switch (msg) {
            .intent => |intent| try self.applyIntent(intent),
            .completion => |completion| try self.applyCompletion(completion),
        };
    }

    fn setToast(self: *LabState, kind: ToastKind, text: []const u8) void {
        self.toast_len = copyBounded(&self.toast, text);
        self.toast_kind = kind;
    }

    fn endUs(self: *const LabState) u64 {
        return @max(self.view.session.last_us, self.view.session.first_us + 1);
    }

    fn focusWindow(self: *LabState) u64 {
        const full_start = self.view.session.first_us;
        const full_end = self.endUs();
        const span = @max(
            @as(u64, 1000),
            @min(@as(u64, 2_000_000), (full_end - full_start) / 4),
        );
        var start = self.transport.cursor_us;
        if (start < full_start) start = full_start;
        if (start >= full_end) start = full_start;
        var end = start + span;
        if (end > full_end) {
            end = full_end;
            start = end -| span;
            if (start < full_start) start = full_start;
        }
        self.view.window = .{ .start_us = start, .end_us = end };
        return start;
    }

    /// Advances playback for a native frame or timer tick. The web and Linux
    /// shells call this only while `transport.playing` is true.
    pub fn advance(self: *LabState, delta_us: u64) void {
        if (!self.transport.playing or self.view.session.events.len == 0) return;
        const full_start = self.view.session.first_us;
        const full_end = self.endUs();
        const scaled: u64 = @intFromFloat(@as(f64, @floatFromInt(delta_us)) * self.transport.speed);
        self.transport.cursor_us +|= scaled;
        if (self.transport.cursor_us >= full_end) self.transport.cursor_us = full_start;
        self.transport.cursor_us = self.focusWindow();
    }

    fn requestSource(
        self: *LabState,
        kind: action.SourceKind,
        path: []const u8,
        batch: *action.EffectBatch,
    ) !void {
        if (path.len == 0 or path.len > max_path) {
            self.setToast(.toast_error, "source path is empty or too long");
            self.source.phase = .failed;
            self.source.reason_len = copyBounded(&self.source.reason, "invalid source path");
            return;
        }
        if (self.capture.phase == .starting or self.capture.phase == .running) {
            self.setToast(.toast_error, "stop the capture before opening a source");
            return;
        }
        self.source.kind = kind;
        self.source.phase = .loading;
        self.source.path_len = copyBounded(&self.source.path, path);
        self.source.reason_len = 0;
        self.scenario.status = .none;
        batch.add(.{ .load_source = .{ .kind = kind, .path = self.source.pathSlice() } });
    }

    fn appendInput(self: *LabState, field: action.InputField, text: []const u8) void {
        const buffer = switch (field) {
            .source_path => &self.source_input,
            .export_path => &self.export_input,
            else => return,
        };
        const length = switch (field) {
            .source_path => &self.source_input_len,
            .export_path => &self.export_input_len,
            else => return,
        };
        if (length.* + text.len > buffer.len) {
            self.setToast(.toast_error, "input is too long");
            return;
        }
        @memcpy(buffer[length.*..][0..text.len], text);
        length.* += text.len;
    }

    fn backspaceInput(self: *LabState, field: action.InputField) void {
        switch (field) {
            .source_path => {
                if (self.source_input_len != 0) self.source_input_len -= 1;
            },
            .export_path => {
                if (self.export_input_len != 0) self.export_input_len -= 1;
            },
            else => {},
        }
    }

    fn applyIntent(self: *LabState, intent: action.Intent) !action.EffectBatch {
        var batch = action.EffectBatch{};
        switch (intent) {
            .screen => |screen| {
                self.view.screen = screen;
                self.focus = .screen;
            },
            .toggle_rail => self.rail_open = !self.rail_open,
            .panel => |panel| {
                self.active_panel = panel;
                self.rail_open = true;
                self.focus = .rail;
            },
            .palette_open => {
                self.palette.open = true;
                self.palette.query_len = 0;
                self.focus = .palette;
            },
            .palette_close => {
                self.palette.open = false;
                self.focus = .screen;
            },
            .open_source => |request| try self.requestSource(request.kind, request.path, &batch),
            .focus_input => |field| {
                self.input_focus = field;
                self.focus = .text_field;
            },
            .text_input => |input| self.appendInput(input.field, input.text),
            .backspace_input => |field| self.backspaceInput(field),
            .submit_input => |field| switch (field) {
                .source_path => try self.requestSource(.replay, self.sourceInputSlice(), &batch),
                .export_path => {
                    if (self.exportInputSlice().len == 0) {
                        self.setToast(.toast_error, "export path is empty");
                    } else {
                        batch.add(.{ .exports = .{
                            .kind = .trace,
                            .path = self.exportInputSlice(),
                        } });
                    }
                },
                else => {},
            },
            .cancel_input => {
                self.input_focus = .none;
                self.focus = .rail;
            },
            .close_source => {
                self.source.phase = .none;
                self.source.path_len = 0;
                self.source.reason_len = 0;
                self.transport.cursor_us = 0;
                self.view.window = null;
                self.view.session = self.empty_session;
                if (self.capture.phase == .starting or self.capture.phase == .running) {
                    self.capture.phase = .stopping;
                    batch.add(.stop_capture);
                }
            },
            .start_capture => |request| {
                if (request.duration_ms == 0) {
                    self.setToast(.toast_error, "capture duration must be positive");
                    return batch;
                }
                if (self.capture.phase == .starting or self.capture.phase == .running or
                    self.capture.phase == .stopping)
                {
                    self.setToast(.toast_error, "a capture is already active");
                    return batch;
                }
                self.capture.preset = request.preset;
                self.capture.duration_ms = request.duration_ms;
                self.capture.events = 0;
                self.capture.lost = 0;
                self.capture.reason_len = 0;
                self.capture.phase = .starting;
                self.source.kind = .live;
                batch.add(.{ .start_capture = .{
                    .duration_ms = request.duration_ms,
                    .preset = request.preset,
                } });
            },
            .stop_capture => {
                if (self.capture.phase != .starting and self.capture.phase != .running) return batch;
                self.capture.phase = .stopping;
                batch.add(.stop_capture);
            },
            .filter_comm => |comm| {
                self.view.filter.comm = null;
                if (comm.len != 0) {
                    for (self.view.session.events) |entry| {
                        if (std.mem.eql(u8, entry.comm, comm)) {
                            self.view.filter.comm = entry.comm;
                            break;
                        }
                    }
                }
            },
            .select_pid => |pid| {
                self.view.selection = null;
                for (self.view.session.events) |entry| {
                    if (entry.pid == pid and entry.comm.len != 0) {
                        self.view.selection = .{ .pid = pid, .comm = entry.comm };
                        break;
                    }
                }
            },
            .transport => |transport| switch (transport) {
                .play => {
                    self.transport.playing = true;
                    if (self.view.window == null) self.transport.cursor_us = self.focusWindow();
                },
                .pause => self.transport.playing = false,
                .step_forward => {
                    self.transport.playing = false;
                    self.transport.cursor_us +|= 1000;
                    self.transport.cursor_us = @min(self.transport.cursor_us, self.endUs());
                    _ = self.focusWindow();
                },
                .step_back => {
                    self.transport.playing = false;
                    self.transport.cursor_us = self.transport.cursor_us -| 1000;
                    _ = self.focusWindow();
                },
                .fit => {
                    self.transport.playing = false;
                    self.transport.cursor_us = self.view.session.first_us;
                    self.view.window = null;
                },
                .follow_on => self.transport.follow = true,
                .follow_off => self.transport.follow = false,
            },
            .exports => |request| {
                if (request.path.len == 0 or request.path.len > max_path) {
                    self.setToast(.toast_error, "export path is empty or too long");
                    return batch;
                }
                batch.add(.{ .exports = .{
                    .kind = request.kind,
                    .path = request.path,
                } });
            },
            .quit => self.quit_requested = true,
            .dismiss_error => {
                self.toast_kind = .none;
                self.toast_len = 0;
                self.source.reason_len = 0;
                self.capture.reason_len = 0;
            },
        }
        return batch;
    }

    fn applyCompletion(self: *LabState, completion: action.Completion) !action.EffectBatch {
        switch (completion) {
            .source_ready => |ready| {
                self.source.phase = .ready;
                self.view.session = ready.session;
                self.transport.cursor_us = ready.session.first_us;
                self.view.window = null;
                self.focus = .screen;
                self.setToast(.success, "source ready");
            },
            .source_failed => |failed| {
                self.source.phase = .failed;
                self.source.reason_len = copyBounded(&self.source.reason, failed.reason);
                self.setToast(.toast_error, failed.reason);
            },
            .capture_started => {
                self.capture.phase = .running;
                self.setToast(.info, "capture running");
            },
            .capture_progress => |progress| {
                self.capture.phase = .running;
                self.capture.events = progress.events;
                self.capture.lost = progress.lost;
                self.capture.cpu_bp = progress.cpu_bp;
                self.capture.rss_kb = progress.rss_kb;
            },
            .capture_finished => |finished| {
                self.capture.phase = switch (finished.outcome) {
                    .stopped => .idle,
                    .failed => .failed,
                    .refused => .refused,
                    .skipped => .skipped,
                };
                self.capture.events = finished.events;
                self.capture.lost = finished.lost;
                self.capture.reason_len = copyBounded(&self.capture.reason, finished.reason);
                self.setToast(
                    if (finished.outcome == .stopped) .success else .toast_error,
                    finished.reason,
                );
            },
            .export_done => |done| {
                self.setToast(.success, done.path);
            },
            .export_failed => |failed| {
                self.setToast(.toast_error, failed.reason);
            },
            .capture_worker_missing => {
                self.capture.phase = .skipped;
                self.capture.reason_len = copyBounded(
                    &self.capture.reason,
                    "capture is native only",
                );
                self.setToast(.toast_error, "capture is native only");
            },
        }
        return .{};
    }
};

test "lab reducer opens sources and tracks capture lifecycle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const session = try session_mod.Session.load(
        std.testing.io,
        arena.allocator(),
        "fixtures/ui/healthy.ndjson",
    );
    var lab = try LabState.init(std.testing.allocator);
    defer lab.deinit();

    var batch = try lab.apply(.{ .intent = .{ .open_source = .{
        .kind = .replay,
        .path = "fixtures/ui/healthy.ndjson",
    } } });
    try std.testing.expectEqual(@as(u8, 1), batch.len);
    try std.testing.expectEqual(SourcePhase.loading, lab.source.phase);

    _ = try lab.apply(.{ .completion = .{ .source_ready = .{ .session = &session } } });
    try std.testing.expectEqual(SourcePhase.ready, lab.source.phase);
    try std.testing.expect(lab.view.session == &session);

    batch = try lab.apply(.{ .intent = .{ .start_capture = .{
        .duration_ms = 500,
        .preset = .scheduler,
    } } });
    try std.testing.expectEqual(CapturePhase.starting, lab.capture.phase);
    try std.testing.expectEqual(@as(u8, 1), batch.len);
    _ = try lab.apply(.{ .completion = .capture_started });
    _ = try lab.apply(.{ .completion = .{ .capture_progress = .{
        .events = 10,
        .lost = 2,
        .cpu_bp = 100,
        .rss_kb = 2048,
    } } });
    try std.testing.expectEqual(@as(u64, 10), lab.capture.events);
    _ = try lab.apply(.{ .completion = .{ .capture_finished = .{
        .outcome = .stopped,
        .events = 10,
        .lost = 2,
        .reason = "recording stopped",
    } } });
    try std.testing.expectEqual(CapturePhase.idle, lab.capture.phase);

    _ = try lab.apply(.{ .intent = .close_source });
    try std.testing.expect(lab.view.session == lab.empty_session);
}

test "lab reducer refuses a second capture and long paths" {
    var lab = try LabState.init(std.testing.allocator);
    defer lab.deinit();
    _ = try lab.apply(.{ .intent = .{ .start_capture = .{
        .duration_ms = 100,
        .preset = .deep,
    } } });
    _ = try lab.apply(.{ .completion = .capture_started });
    const batch = try lab.apply(.{ .intent = .{ .start_capture = .{
        .duration_ms = 100,
        .preset = .scheduler,
    } } });
    try std.testing.expectEqual(@as(u8, 0), batch.len);
    try std.testing.expectEqual(ToastKind.toast_error, lab.toast_kind);

    var long_path: [max_path + 1]u8 = @splat('x');
    const failed = try lab.apply(.{ .intent = .{ .open_source = .{
        .kind = .replay,
        .path = &long_path,
    } } });
    try std.testing.expectEqual(@as(u8, 0), failed.len);
    try std.testing.expectEqual(SourcePhase.failed, lab.source.phase);
}

test "transport advances and fits the timeline window" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const session = try session_mod.Session.load(
        std.testing.io,
        arena.allocator(),
        "fixtures/ui/healthy.ndjson",
    );
    var lab = try LabState.init(std.testing.allocator);
    defer lab.deinit();
    _ = try lab.apply(.{ .completion = .{ .source_ready = .{ .session = &session } } });
    _ = try lab.apply(.{ .intent = .{ .transport = .play } });
    lab.advance(50_000);
    try std.testing.expect(lab.view.window != null);
    try std.testing.expect(lab.transport.cursor_us > session.first_us);
    _ = try lab.apply(.{ .intent = .{ .transport = .fit } });
    try std.testing.expect(lab.view.window == null);
}

test "filter intent selects a real switch comm" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const session = try session_mod.Session.load(
        std.testing.io,
        arena.allocator(),
        "fixtures/ui/healthy.ndjson",
    );
    var lab = try LabState.init(std.testing.allocator);
    defer lab.deinit();
    _ = try lab.apply(.{ .completion = .{ .source_ready = .{ .session = &session } } });
    _ = try lab.apply(.{ .intent = .{ .filter_comm = "worker-c" } });
    try std.testing.expect(lab.view.filter.comm != null);
    var matches: usize = 0;
    for (session.slices) |slice| {
        if (lab.view.filter.matchesSlice(slice)) matches += 1;
    }
    try std.testing.expect(matches > 0);
}

test "path editing submits a source intent" {
    var lab = try LabState.init(std.testing.allocator);
    defer lab.deinit();
    _ = try lab.apply(.{ .intent = .{ .focus_input = .source_path } });
    try std.testing.expectEqual(action.InputField.source_path, lab.input_focus);
    _ = try lab.apply(.{ .intent = .{ .text_input = .{
        .field = .source_path,
        .text = "fixtures/ui/empty.ndjson",
    } } });
    try std.testing.expectEqualStrings("fixtures/ui/empty.ndjson", lab.sourceInputSlice());
    _ = try lab.apply(.{ .intent = .{ .backspace_input = .source_path } });
    try std.testing.expectEqualStrings("fixtures/ui/empty.ndjso", lab.sourceInputSlice());
    const batch = try lab.apply(.{ .intent = .{ .submit_input = .source_path } });
    try std.testing.expectEqual(@as(u8, 1), batch.len);
    try std.testing.expectEqual(SourcePhase.loading, lab.source.phase);
}
