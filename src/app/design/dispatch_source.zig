//! Source selection, GPU picker, recorder management and export actions.
//! Kept separate from dispatch.zig so both reducers stay small and testable.

const std = @import("std");
const state_mod = @import("state.zig");
const action_mod = @import("action.zig");
const effect = @import("effect.zig");
const hits = @import("hits.zig");
const source = @import("source.zig");
const recorder = @import("recorder.zig");
const picker = @import("picker.zig");

const Action = action_mod.Action;
const State = state_mod.State;
const Batch = effect.Batch;

pub fn handle(state: *State, surface: effect.Surface, act: Action, batch: *Batch) void {
    switch (act) {
        .source_select, .source_window, .source_open_path, .source_reload, .source_close, .open_journal, .reload_source => handleSource(state, surface, act, batch),
        .open_picker, .picker_move, .picker_enter, .picker_parent, .picker_close => handlePicker(state, surface, act, batch),
        .recorder, .export_file, .open_confirm, .confirm_yes, .confirm_no => handleRecorder(state, surface, act, batch),
        .recents_open => |index| {
            if (state.settings.recents.get(index)) |entry| {
                const kind: source.Kind = switch (entry.kind) {
                    .demo => .demo,
                    .replay => .replay,
                    .recorder_window => .recorder_window,
                    .live => .live,
                };
                openSourcePath(state, kind, entry.pathSlice(), entry.window_ms, batch);
            }
        },
        else => {},
    }
}

pub fn openConfirm(state: *State, kind: state_mod.Confirm) void {
    state.dialog = .confirm;
    state.focus_return = state.focus_id orelse hits.recorder_stop;
    state.focus_id = hits.confirm_yes;
    state.focus_visible = true;
    state.confirm_pending = kind;
    state.setStatus(kind.title());
}

pub fn openSourcePath(state: *State, kind: source.Kind, path: []const u8, window_ms: u64, batch: *Batch) void {
    if (path.len == 0) {
        batch.refuse("source.path.empty", "source path is empty");
        return;
    }
    state.source.beginLoad(kind, path);
    state.settings.last_source = kind;
    if (kind == .demo) {
        batch.add(.load_demo);
        state.screen = .timeline;
        return;
    }
    var request = effect.LoadRequest{ .kind = kind, .window_ms = window_ms };
    request.setPath(path);
    batch.add(.{ .load_path = request });
    state.screen = .timeline;
}

fn handleSource(state: *State, surface: effect.Surface, act: Action, batch: *Batch) void {
    switch (act) {
        .source_select => |kind| switch (kind) {
            .demo => {
                state.source.beginLoad(.demo, "bundled capture");
                batch.add(.load_demo);
                state.screen = .timeline;
            },
            .replay => {
                if (effect.supports(surface, .list_dir)) {
                    openPicker(state, surface, .file, .replay_file, batch);
                } else {
                    const refusal = effect.refusalFor(surface, .list_dir);
                    batch.refuse(refusal.code, refusal.reason);
                }
            },
            .recorder_window => {
                if (effect.supports(surface, .list_dir)) {
                    openPicker(state, surface, .directory, .recorder_dir, batch);
                } else {
                    const refusal = effect.refusalFor(surface, .list_dir);
                    batch.refuse(refusal.code, refusal.reason);
                }
            },
            .live => {
                if (!effect.supports(surface, .live_capture)) {
                    const refusal = effect.refusalFor(surface, .live_capture);
                    batch.refuse(refusal.code, refusal.reason);
                } else if (!state.settings.capture_enabled) {
                    batch.refuse("capture.disabled", "capture controls are disabled in Settings; enable them to start a read-only capture");
                } else {
                    state.source.beginLoad(.live, "live capture");
                    tryStartCapture(state, surface, batch);
                }
            },
        },
        .source_window => |preset| {
            state.source.window.preset = preset;
            state.setStatus(preset.label());
        },
        .source_open_path => |request| openSourcePath(state, request.kind, request.path, request.window_ms, batch),
        .source_reload, .reload_source => {
            if (state.source.phase == .ready or state.source.path_len != 0) {
                state.source.phase = .loading;
            }
            batch.add(.reload_source);
            batch.notify("source reload requested", false);
        },
        .source_close => {
            state.source.clear();
            state.resetView(0);
            state.screen = .home;
            batch.notify("source cleared", false);
        },
        .open_journal => {
            state.closeDialogState();
            batch.add(.open_journal);
        },
        else => {},
    }
}

pub fn openPicker(state: *State, surface: effect.Surface, mode: picker.Mode, purpose: picker.Purpose, batch: *Batch) void {
    if (!effect.supports(surface, .list_dir)) {
        const refusal = effect.refusalFor(surface, .list_dir);
        batch.refuse(refusal.code, refusal.reason);
        return;
    }
    state.dialog = .picker;
    state.focus_return = state.focus_id;
    state.picker.open(mode, purpose);
    state.picker.phase = .loading;
    state.text_focus = .picker_filter;
    state.focus_visible = true;
    state.setStatus("choose a file");
    requestListing(state, batch);
}

fn requestListing(state: *State, batch: *Batch) void {
    var list = effect.ListRequest{ .mode = state.picker.mode, .purpose = state.picker.purpose };
    list.path_len = state.picker.cwd_len;
    @memcpy(list.path[0..list.path_len], state.picker.cwdSlice());
    batch.add(.{ .list_dir = list });
}

fn handlePicker(state: *State, surface: effect.Surface, act: Action, batch: *Batch) void {
    if (state.dialog != .picker) {
        if (act == .picker_close) return;
        openPicker(state, surface, .file, .replay_file, batch);
        return;
    }
    switch (act) {
        .picker_move => |delta| {
            state.picker.move(delta);
            state.focus_id = hits.picker_row_base + @as(u32, @intCast(state.picker.selected));
        },
        .picker_enter => {
            if (state.picker.phase == .error_state) {
                requestListing(state, batch);
                return;
            }
            const entry = state.picker.selectedEntry() orelse {
                batch.notify("no file selected", false);
                return;
            };
            var path_buf: [768]u8 = undefined;
            const path = state.picker.joinPath(entry.nameSlice(), &path_buf);
            if (entry.is_dir) {
                state.picker.setCwd(path);
                state.picker.phase = .loading;
                requestListing(state, batch);
                return;
            }
            const purpose = state.picker.purpose;
            const window_ms = state.source.window.lastMs() orelse 0;
            const dir = state.picker.cwdSlice();
            var dir_copy: [picker.max_path]u8 = undefined;
            const dir_len = @min(dir.len, dir_copy.len);
            @memcpy(dir_copy[0..dir_len], dir[0..dir_len]);
            state.picker.close();
            state.closeDialogState();
            switch (purpose) {
                .replay_file => openSourcePath(state, .replay, path, window_ms, batch),
                .recorder_dir => {
                    state.settings.setRecorderDir(dir_copy[0..dir_len]);
                    state.recorder.external = true;
                    batch.add(.save_settings);
                    batch.notify("recorder state directory selected", false);
                },
            }
        },
        .picker_parent => {
            var parent_buf: [768]u8 = undefined;
            const parent = state.picker.parentPath(&parent_buf);
            state.picker.setCwd(parent);
            state.picker.phase = .loading;
            requestListing(state, batch);
        },
        .picker_close => state.closeDialogState(),
        else => {},
    }
}

fn recorderOptions(state: *const State) recorder.Options {
    const window_ms = state.source.window.lastMs() orelse 5000;
    const clamped: u32 = @intCast(@min(@max(window_ms, 1000), 600_000));
    const preset: recorder.Preset = switch (state.settings.recorder_preset) {
        1 => .memory,
        2 => .deep,
        else => .scheduler,
    };
    return .{ .duration_ms = clamped, .preset = preset };
}

fn tryStartCapture(state: *State, surface: effect.Surface, batch: *Batch) void {
    if (!effect.supports(surface, .recorder_control)) {
        const refusal = effect.refusalFor(surface, .recorder_control);
        batch.refuse(refusal.code, refusal.reason);
        return;
    }
    if (!state.settings.capture_enabled) {
        batch.refuse("capture.disabled", "capture controls are disabled in Settings; enable them to start a read-only capture");
        return;
    }
    switch (state.recorder.begin(recorderOptions(state))) {
        .run => batch.add(.{ .start_capture = state.recorder.options }),
        .refuse => |refusal| batch.refuse(refusal.code, refusal.reason),
        .none => {},
    }
}

fn handleRecorder(state: *State, surface: effect.Surface, act: Action, batch: *Batch) void {
    switch (act) {
        .recorder => |command| switch (command) {
            .start => tryStartCapture(state, surface, batch),
            .stop => {
                if (!effect.supports(surface, .recorder_control)) return refuseControl(surface, batch);
                switch (state.recorder.requestStop()) {
                    .run => batch.add(.stop_capture),
                    .refuse => |refusal| batch.refuse(refusal.code, refusal.reason),
                    .none => {},
                }
            },
            .restart => {
                if (!effect.supports(surface, .recorder_control)) return refuseControl(surface, batch);
                switch (state.recorder.requestRestart()) {
                    .run => |run_command| {
                        if (run_command == .stop) {
                            batch.add(.stop_capture);
                            openConfirm(state, .restart_capture);
                        } else {
                            batch.add(.{ .start_capture = state.recorder.options });
                        }
                    },
                    .refuse => |refusal| batch.refuse(refusal.code, refusal.reason),
                    .none => {},
                }
            },
            .extract => {
                if (!effect.supports(surface, .recorder_control)) return refuseControl(surface, batch);
                switch (state.recorder.extract()) {
                    .run => batch.add(.{ .extract_window = .{ .last_ms = state.source.window.lastMs() orelse 0 } }),
                    .refuse => |refusal| batch.refuse(refusal.code, refusal.reason),
                    .none => {},
                }
            },
            .attach => {
                if (effect.supports(surface, .list_dir)) {
                    openPicker(state, surface, .directory, .recorder_dir, batch);
                } else {
                    const refusal = effect.refusalFor(surface, .list_dir);
                    batch.refuse(refusal.code, refusal.reason);
                }
            },
            .export_journal => exportFile(state, surface, .journal, batch),
            .export_trace => exportFile(state, surface, .trace, batch),
            .export_report => exportFile(state, surface, .report, batch),
            .export_incident => exportFile(state, surface, .incident, batch),
        },
        .export_file => |kind| exportFile(state, surface, kind, batch),
        .open_confirm => |kind| openConfirm(state, kind),
        .confirm_yes => {
            const pending = state.confirm_pending;
            state.closeDialogState();
            if (pending) |kind| switch (kind) {
                .stop_capture => switch (state.recorder.requestStop()) {
                    .run => batch.add(.stop_capture),
                    .refuse => |refusal| batch.refuse(refusal.code, refusal.reason),
                    .none => {},
                },
                .restart_capture => switch (state.recorder.requestRestart()) {
                    .run => batch.add(.{ .start_capture = state.recorder.options }),
                    .refuse => |refusal| batch.refuse(refusal.code, refusal.reason),
                    .none => {},
                },
                .reset_settings => {
                    state.settings = .{};
                    state.theme_index = 0;
                    state.source.clear();
                    batch.add(.save_settings);
                    batch.notify("settings reset", false);
                },
            };
        },
        .confirm_no => state.closeDialogState(),
        else => {},
    }
}

fn refuseControl(surface: effect.Surface, batch: *Batch) void {
    const refusal = effect.refusalFor(surface, .recorder_control);
    batch.refuse(refusal.code, refusal.reason);
}

fn exportFile(state: *State, surface: effect.Surface, kind: effect.ExportKind, batch: *Batch) void {
    if (!effect.supports(surface, .write_file)) {
        const refusal = effect.refusalFor(surface, .write_file);
        batch.refuse(refusal.code, refusal.reason);
        return;
    }
    if (state.recorder.phase.isActive()) {
        batch.refuse("capture.busy", "stop the capture before exporting");
        return;
    }
    var item = effect.Effect{ .export_file = .{ .kind = kind } };
    const dir = state.settings.recorderDirSlice();
    const value = &item.export_file;
    value.path_len = @min(dir.len, value.path.len);
    @memcpy(value.path[0..value.path_len], dir[0..value.path_len]);
    batch.add(item);
    batch.notify("export queued", false);
}

test "snapshot recorder control fails closed with a stable reason" {
    var state = State{};
    state.settings.capture_enabled = true;
    var batch = Batch{};
    handle(&state, .snapshot, .{ .recorder = .start }, &batch);
    try std.testing.expect(batch.len == 1);
    switch (batch.items[0]) {
        .refusal => |refusal| {
            try std.testing.expectEqualStrings("surface.recorder.unsupported", refusal.code);
            try std.testing.expect(refusal.reason.len != 0);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(recorder.Phase.idle, state.recorder.phase);
}

test "linux start capture requires the settings opt-in" {
    var state = State{};
    var batch = Batch{};
    handle(&state, .linux, .{ .recorder = .start }, &batch);
    switch (batch.items[0]) {
        .refusal => |refusal| try std.testing.expectEqualStrings("capture.disabled", refusal.code),
        else => return error.TestUnexpectedResult,
    }
    state.settings.capture_enabled = true;
    batch = Batch{};
    handle(&state, .linux, .{ .recorder = .start }, &batch);
    try std.testing.expectEqual(recorder.Phase.starting, state.recorder.phase);
    switch (batch.items[0]) {
        .start_capture => |options| try std.testing.expect(options.duration_ms >= 1000),
        else => return error.TestUnexpectedResult,
    }
}

test "snapshot replay selection fails closed without a picker" {
    var state = State{};
    var batch = Batch{};
    handle(&state, .snapshot, .{ .source_select = .replay }, &batch);
    try std.testing.expect(batch.len >= 1);
    switch (batch.items[0]) {
        .refusal => |refusal| try std.testing.expectEqualStrings("surface.list_dir.unsupported", refusal.code),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(source.Phase.idle, state.source.phase);
}

test "export requires a writable surface" {
    var state = State{};
    var batch = Batch{};
    handle(&state, .snapshot, .{ .export_file = .trace }, &batch);
    switch (batch.items[0]) {
        .refusal => |refusal| try std.testing.expectEqualStrings("surface.write.unsupported", refusal.code),
        else => return error.TestUnexpectedResult,
    }
    batch = Batch{};
    handle(&state, .linux, .{ .export_file = .trace }, &batch);
    var found = false;
    for (batch.slice()) |item| {
        if (item == .export_file) found = true;
    }
    try std.testing.expect(found);
}

test "external restart fails closed for an externally managed recorder" {
    var state = State{};
    state.recorder.external = true;
    var batch = Batch{};
    handle(&state, .linux, .{ .recorder = .restart }, &batch);
    switch (batch.items[0]) {
        .refusal => |refusal| try std.testing.expectEqualStrings("capture.external", refusal.code),
        else => return error.TestUnexpectedResult,
    }
}
