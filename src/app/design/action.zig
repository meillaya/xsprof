//! Bounded user actions for the product console. Every input path (key,
//! click, palette, text field, timer completion) resolves to an Action; the
//! reducer in dispatch.zig is the only writer of State.

const std = @import("std");
const route = @import("route.zig");
const source = @import("source.zig");
const recorder = @import("recorder.zig");
const picker = @import("picker.zig");
const settings = @import("settings.zig");
const effect = @import("effect.zig");
const text_input = @import("text_input.zig");
const state_mod = @import("state.zig");

pub const max_path = 512;

pub const TextField = text_input.Field;

pub const TextOp = union(enum) {
    insert: u21,
    backspace,
    delete,
    left,
    right,
    home,
    end,
    kill_word,
    kill_line,
    clear,
};

pub const Action = union(enum) {
    // Navigation / shell.
    nav: route.Route,
    open_palette,
    open_appearance,
    open_help,
    close_dialog,
    quit,

    // Appearance.
    theme: usize,
    settings_toggle: settings.Key,
    settings_save,
    settings_reset,

    // Source selection.
    source_select: source.Kind,
    source_window: source.WindowPreset,
    source_open_path: struct { kind: source.Kind, window_ms: u64, path: []const u8 },
    source_reload,
    source_close,
    open_journal,
    reload_source,

    // Picker overlay.
    open_picker: struct { mode: picker.Mode, purpose: picker.Purpose },
    picker_move: i32,
    picker_enter,
    picker_parent,
    picker_close,

    // Recorder management.
    recorder: recorder.Command,
    export_file: effect.ExportKind,
    open_confirm: state_mod.Confirm,
    confirm_yes,
    confirm_no,

    // Onboarding.
    onboarding_next,
    onboarding_back,
    onboarding_skip,
    onboarding_finish,

    // Recents / audit.
    recents_open: usize,
    recents_clear,
    audit_copy,
    audit_export,
    audit_verify,

    // Timeline / analysis (unchanged behaviour).
    fit,
    zoom: f64,
    toggle_play,
    jump_end,
    filter_events,
    copy_selection,

    // Text editing.
    text: struct { field: TextField, op: TextOp },
};

test "action union covers shell and analysis intents" {
    const actions = [_]Action{
        .{ .nav = .home },
        .open_palette,
        .{ .source_select = .replay },
        .{ .recorder = .restart },
        .{ .export_file = .trace },
        .{ .open_confirm = .stop_capture },
        .onboarding_next,
        .{ .recents_open = 0 },
        .{ .text = .{ .field = .palette, .op = .{ .insert = 'a' } } },
        .{ .zoom = 1.5 },
    };
    try std.testing.expectEqual(@as(usize, 10), actions.len);
}
