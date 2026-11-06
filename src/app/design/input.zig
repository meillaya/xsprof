//! Keyboard adapter: routes raw codepoints/modifiers into actions. Kept apart
//! from App so the state machine stays under the line limit.

const std = @import("std");
const app_mod = @import("app.zig");
const action_mod = @import("action.zig");
const state_mod = @import("state.zig");
const commands = @import("commands.zig");
const route = @import("route.zig");
const hits = @import("hits.zig");

const App = app_mod.App;

const key_up: u21 = 0x11;
const key_down: u21 = 0x12;
const key_left: u21 = 0x13;
const key_right: u21 = 0x14;
const key_esc: u21 = 0x1b;
const key_enter: u21 = 0x0a;
const key_tab: u21 = 0x09;
const key_backspace: u21 = 0x7f;

pub fn handleKey(app: *App, codepoint: u21, mods: app_mod.Modifiers) void {
    switch (app.state.dialog) {
        .palette => return handlePalette(app, codepoint, mods),
        .appearance => return handleAppearance(app, codepoint, mods),
        .help => return handleHelp(app, codepoint, mods),
        .confirm => return handleConfirm(app, codepoint, mods),
        .picker => return handlePicker(app, codepoint, mods),
        .onboarding => return handleOnboarding(app, codepoint, mods),
        .none => {},
    }
    if (app.state.events_filter_focused) return handleEventsFilter(app, codepoint, mods);
    if ((mods.meta or mods.ctrl) and (codepoint == 'k' or codepoint == 'K')) return app.applyAction(.open_palette);
    if ((mods.meta or mods.ctrl) and codepoint == ',') return app.applyAction(.{ .nav = .settings });
    if (route.fromKey(codepoint)) |target| return app.applyAction(.{ .nav = target });
    switch (codepoint) {
        '/' => app.applyAction(.filter_events),
        '?' => app.applyAction(.open_help),
        'w', 'W' => app.applyAction(.open_appearance),
        'f', 'F' => app.applyAction(.fit),
        ' ' => app.applyAction(.toggle_play),
        't', 'T' => app.applyAction(.jump_end),
        'c', 'C' => app.applyAction(.copy_selection),
        '+', '=' => app.applyAction(.{ .zoom = 0.6 }),
        '-', '_' => app.applyAction(.{ .zoom = 1.7 }),
        key_esc => {
            app.applyAction(.close_dialog);
            app.state.focus_id = null;
            app.state.focus_visible = false;
            app.state.events_filter_focused = false;
            app.state.text_focus = null;
            app.state.selected_slice = null;
            app.state.events_selected = null;
            app.state.toast = null;
        },
        else => {},
    }
}

fn handlePalette(app: *App, codepoint: u21, mods: app_mod.Modifiers) void {
    _ = mods;
    const state = &app.state;
    switch (codepoint) {
        key_esc => app.applyAction(.close_dialog),
        key_enter, '\r' => app.runPaletteCommand(state.palette_index),
        key_up, key_left => {
            if (state.palette_index > 0) state.palette_index -= 1;
            state.focus_id = hits.palette_row_base + @as(u32, @intCast(state.palette_index));
            state.focus_visible = true;
        },
        key_down, key_right => {
            const count = commands.count(state.paletteQuery());
            if (count > 0 and state.palette_index + 1 < count) state.palette_index += 1;
            state.focus_id = hits.palette_row_base + @as(u32, @intCast(state.palette_index));
            state.focus_visible = true;
        },
        key_backspace => app.applyAction(.{ .text = .{ .field = .palette, .op = .backspace } }),
        else => {
            if (codepoint >= 32 and codepoint < 0x7f) app.applyAction(.{ .text = .{ .field = .palette, .op = .{ .insert = codepoint } } });
        },
    }
}

fn handleAppearance(app: *App, codepoint: u21, mods: app_mod.Modifiers) void {
    _ = mods;
    const state = &app.state;
    switch (codepoint) {
        key_esc => app.applyAction(.close_dialog),
        key_up => {
            const index = if (state.theme_index == 0) 5 else state.theme_index - 1;
            app.applyAction(.{ .theme = index });
            state.focus_id = hits.theme_option_base + @as(u32, @intCast(index));
        },
        key_down => {
            const index = (state.theme_index + 1) % 6;
            app.applyAction(.{ .theme = index });
            state.focus_id = hits.theme_option_base + @as(u32, @intCast(index));
        },
        '1'...'6' => app.applyAction(.{ .theme = @intCast(codepoint - '1') }),
        else => {},
    }
}

fn handleHelp(app: *App, codepoint: u21, mods: app_mod.Modifiers) void {
    if (mods.meta or mods.ctrl) return;
    if (codepoint == key_esc or codepoint == '?') app.applyAction(.close_dialog);
}

fn handleConfirm(app: *App, codepoint: u21, mods: app_mod.Modifiers) void {
    _ = mods;
    switch (codepoint) {
        key_esc, 'n', 'N' => app.applyAction(.confirm_no),
        key_enter, '\r', 'y', 'Y' => app.applyAction(.confirm_yes),
        else => {},
    }
}

fn handleOnboarding(app: *App, codepoint: u21, mods: app_mod.Modifiers) void {
    _ = mods;
    switch (codepoint) {
        key_esc => app.applyAction(.onboarding_skip),
        key_enter, '\r', key_right => {
            if (app.state.onboarding.isLast()) {
                app.applyAction(.onboarding_finish);
            } else {
                app.applyAction(.onboarding_next);
            }
        },
        key_left => app.applyAction(.onboarding_back),
        else => {},
    }
}

fn handlePicker(app: *App, codepoint: u21, mods: app_mod.Modifiers) void {
    _ = mods;
    switch (codepoint) {
        key_esc => app.applyAction(.picker_close),
        key_up => app.applyAction(.{ .picker_move = -1 }),
        key_down => app.applyAction(.{ .picker_move = 1 }),
        key_enter, '\r' => app.applyAction(.picker_enter),
        key_backspace => {
            if (app.state.picker.filter.len > 0) {
                app.applyAction(.{ .text = .{ .field = .picker_filter, .op = .backspace } });
            } else {
                app.applyAction(.picker_parent);
            }
        },
        else => {
            if (codepoint >= 32 and codepoint < 0x7f) app.applyAction(.{ .text = .{ .field = .picker_filter, .op = .{ .insert = codepoint } } });
        },
    }
}

fn handleEventsFilter(app: *App, codepoint: u21, mods: app_mod.Modifiers) void {
    _ = mods;
    switch (codepoint) {
        key_esc => {
            app.state.events_filter_focused = false;
            app.state.text_focus = null;
            app.applyAction(.{ .text = .{ .field = .events_filter, .op = .clear } });
        },
        key_enter, '\r' => {
            app.state.events_filter_focused = false;
            app.state.text_focus = null;
        },
        key_backspace => app.applyAction(.{ .text = .{ .field = .events_filter, .op = .backspace } }),
        else => {
            if (codepoint >= 32 and codepoint < 0x7f) app.applyAction(.{ .text = .{ .field = .events_filter, .op = .{ .insert = codepoint } } });
        },
    }
}

test "esc clears analysis selection" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    app.state.selected_slice = 3;
    app.handleKey(key_esc, .{});
    try std.testing.expect(app.state.selected_slice == null);
}

test "navigation keys keep 1..5 and add 0/6/7" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    app.handleKey('1', .{});
    try std.testing.expectEqual(state_mod.Route.overview, app.state.screen);
    app.handleKey('0', .{});
    try std.testing.expectEqual(state_mod.Route.home, app.state.screen);
    app.handleKey('6', .{});
    try std.testing.expectEqual(state_mod.Route.audit, app.state.screen);
    app.handleKey('7', .{});
    try std.testing.expectEqual(state_mod.Route.settings, app.state.screen);
}

test "palette escape returns focus to trigger" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    app.handleKey('k', .{ .meta = true });
    try std.testing.expectEqual(state_mod.Dialog.palette, app.state.dialog);
    app.handleKey(key_esc, .{});
    try std.testing.expectEqual(state_mod.Dialog.none, app.state.dialog);
    try std.testing.expectEqual(@as(?u32, 200), app.state.focus_id);
}
