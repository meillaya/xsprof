//! Pure input->state reducer for the product console. Every action (key,
//! click, palette, text field) lands here. Reducers never perform IO: they
//! update State and append bounded effects. Source/picker/recorder handling
//! lives in dispatch_source.zig to keep both files small.

const std = @import("std");
const state_mod = @import("state.zig");
const action_mod = @import("action.zig");
const effect = @import("effect.zig");
const hits = @import("hits.zig");
const text_input = @import("text_input.zig");
const dispatch_source = @import("dispatch_source.zig");

const Action = action_mod.Action;
const State = state_mod.State;
const Batch = effect.Batch;

pub const reduce = reduceWith;

pub fn reduceWith(state: *State, surface: effect.Surface, act: Action) Batch {
    var batch = Batch{};
    switch (act) {
        .nav => |route| {
            state.closeDialogState();
            state.screen = route;
            state.scroll_y = 0;
            state.events_filter_focused = false;
            state.text_focus = null;
            if (route != .timeline) state.timeline_playing = false;
            state.focus_id = route.railId();
            state.focus_visible = true;
            state.setStatus(route.name());
        },
        .open_palette => {
            openDialog(state, .palette, hits.topbar_palette, hits.palette_input);
            state.palette_input.clear();
            state.palette_index = 0;
            state.text_focus = .palette;
            state.setStatus("palette");
        },
        .open_appearance => {
            openDialog(state, .appearance, hits.topbar_theme, hits.theme_option_base + @as(u32, @intCast(state.theme_index % 6)));
            state.setStatus("appearance");
        },
        .open_help => {
            openDialog(state, .help, hits.topbar_help, hits.help_close);
            state.setStatus("keyboard help");
        },
        .close_dialog => state.closeDialogState(),
        .quit => {},
        .theme => |index| {
            if (index < 6) {
                state.theme_index = index;
                state.settings.theme_index = index;
                if (state.dialog == .appearance) state.focus_id = hits.theme_option_base + @as(u32, @intCast(index));
                batch.add(.save_settings);
                batch.notify("theme applied", false);
            }
        },
        .settings_toggle => |key| {
            const value = state.settings.toggle(key);
            if (key == .capture_enabled and !effect.supports(surface, .recorder_control)) {
                const refusal = effect.refusalFor(surface, .recorder_control);
                batch.refuse(refusal.code, refusal.reason);
            }
            batch.add(.save_settings);
            batch.notify(if (value) "setting enabled" else "setting disabled", false);
        },
        .settings_save => {
            batch.add(.save_settings);
            batch.notify("settings saved", false);
        },
        .settings_reset => dispatch_source.openConfirm(state, .reset_settings),
        .source_select, .source_window, .source_open_path, .source_reload, .source_close, .open_journal, .reload_source, .open_picker, .picker_move, .picker_enter, .picker_parent, .picker_close, .recorder, .export_file, .open_confirm, .confirm_yes, .confirm_no, .recents_open => {
            dispatch_source.handle(state, surface, act, &batch);
        },
        .recents_clear => {
            state.settings.recents.clear();
            batch.add(.save_settings);
            batch.notify("recents cleared", false);
        },
        .onboarding_next => {
            if (!state.onboarding.active) {
                state.onboarding.active = true;
                state.onboarding.step = .welcome;
                state.dialog = .onboarding;
                state.focus_return = state.focus_id;
                state.focus_id = hits.onboarding_next;
            } else if (state.onboarding.isLast()) {
                finishOnboarding(state, &batch);
            } else {
                state.onboarding.next();
                state.focus_id = hits.onboarding_next;
            }
        },
        .onboarding_back => {
            state.onboarding.back();
            state.focus_id = hits.onboarding_back;
        },
        .onboarding_skip, .onboarding_finish => finishOnboarding(state, &batch),
        .audit_copy => {
            var buf: [160]u8 = undefined;
            const newest = state.audit.newest();
            const text = if (newest) |entry|
                std.fmt.bufPrint(&buf, "xsprof ui audit: {d} entries, host_mutation=false, last {s} {s}", .{ state.audit.len, entry.actionSlice(), entry.outcome.label() }) catch "xsprof ui audit"
            else
                "xsprof ui audit: empty";
            var t = effect.Text{};
            t.set(text);
            batch.add(.{ .copy_text = t });
            batch.notify("audit summary copied", false);
        },
        .audit_export => {
            if (!effect.supports(surface, .write_file)) {
                const refusal = effect.refusalFor(surface, .write_file);
                batch.refuse(refusal.code, refusal.reason);
            } else {
                batch.add(.export_audit);
                batch.notify("audit export queued", false);
            }
        },
        .audit_verify => {
            if (effect.supports(surface, .recorder_control)) {
                batch.add(.verify_recorder);
            } else {
                const refusal = effect.refusalFor(surface, .recorder_control);
                batch.refuse(refusal.code, refusal.reason);
            }
        },
        .fit, .zoom, .jump_end, .copy_selection => {
            // Model-dependent actions are applied by App against the current
            // model before the reducer runs (docs/product-shell.md).
        },
        .toggle_play => {
            if (state.screen != .timeline) {
                state.screen = .timeline;
                state.focus_id = hits.timeline_play;
            }
            state.timeline_playing = !state.timeline_playing;
            batch.notify(if (state.timeline_playing) "playing" else "paused", false);
        },
        .filter_events => {
            state.closeDialogState();
            state.screen = .events;
            state.focus_id = hits.events_filter;
            state.focus_visible = true;
            state.events_filter_focused = true;
            state.text_focus = .events_filter;
            batch.notify("filter events by task", false);
        },
        .text => |edit| handleText(state, edit.field, edit.op),
    }
    return batch;
}

pub fn openDialog(state: *State, dialog: state_mod.Dialog, return_id: u32, focus_id: u32) void {
    state.dialog = dialog;
    state.focus_return = return_id;
    state.focus_id = focus_id;
    state.focus_visible = true;
}

fn finishOnboarding(state: *State, batch: *Batch) void {
    if (state.onboarding.active) {
        state.onboarding.finish();
    } else {
        state.onboarding.skip();
    }
    state.settings.onboarding_version = state.onboarding.completed_version;
    state.closeDialogState();
    batch.add(.save_settings);
    batch.notify("onboarding complete", false);
}

pub fn handleText(state: *State, field: text_input.Field, op: action_mod.TextOp) void {
    const target: *text_input.Input = switch (field) {
        .palette => &state.palette_input,
        .events_filter => &state.events_input,
        .picker_filter => &state.picker.filter,
        .recorder_dir => &state.settings.recorder_dir,
    };
    switch (op) {
        .insert => |codepoint| _ = target.insert(codepoint),
        .backspace => _ = target.backspace(),
        .delete => _ = target.delete(),
        .left => target.left(),
        .right => target.right(),
        .home => target.home(),
        .end => target.end(),
        .kill_word => target.killWord(),
        .kill_line => target.killLine(),
        .clear => target.clear(),
    }
    switch (field) {
        .palette => state.palette_index = 0,
        .events_filter => {
            state.events_query = state.events_input.slice();
            state.events_selected = null;
        },
        .recorder_dir => {},
        .picker_filter => state.picker.selected = 0,
    }
}

test "nav keeps analysis ids and extension rail ids stable" {
    var state = State{};
    _ = reduce(&state, .linux, .{ .nav = .overview });
    try std.testing.expectEqual(@as(?u32, 100), state.focus_id);
    _ = reduce(&state, .linux, .{ .nav = .home });
    try std.testing.expectEqual(@as(?u32, 105), state.focus_id);
    _ = reduce(&state, .linux, .{ .nav = .audit });
    try std.testing.expectEqual(@as(?u32, 106), state.focus_id);
    _ = reduce(&state, .linux, .{ .nav = .settings });
    try std.testing.expectEqual(@as(?u32, 107), state.focus_id);
}

test "palette open and close restores the trigger" {
    var state = State{};
    _ = reduce(&state, .linux, .open_palette);
    try std.testing.expectEqual(state_mod.Dialog.palette, state.dialog);
    try std.testing.expectEqual(@as(?u32, hits.palette_input), state.focus_id);
    try std.testing.expectEqual(@as(?u32, hits.topbar_palette), state.focus_return);
    _ = reduce(&state, .linux, .close_dialog);
    try std.testing.expectEqual(@as(?u32, hits.topbar_palette), state.focus_id);
}

test "text edits update the events filter query" {
    var state = State{};
    _ = reduce(&state, .linux, .{ .text = .{ .field = .events_filter, .op = .{ .insert = 'a' } } });
    _ = reduce(&state, .linux, .{ .text = .{ .field = .events_filter, .op = .{ .insert = 'b' } } });
    try std.testing.expectEqualStrings("ab", state.eventsQuery());
    _ = reduce(&state, .linux, .{ .text = .{ .field = .events_filter, .op = .backspace } });
    try std.testing.expectEqualStrings("a", state.eventsQuery());
}

test "onboarding walks four steps and persists on finish" {
    var state = State{};
    _ = reduce(&state, .linux, .onboarding_next);
    try std.testing.expect(state.onboarding.active);
    _ = reduce(&state, .linux, .onboarding_next);
    try std.testing.expectEqual(@as(u8, 1), state.onboarding.step.index());
    _ = reduce(&state, .linux, .onboarding_skip);
    try std.testing.expect(!state.onboarding.active);
    try std.testing.expectEqual(@as(u32, 2), state.settings.onboarding_version);
}
