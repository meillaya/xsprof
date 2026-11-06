//! Canvas hit-id adapter: converts a static hit id into an Action. Kept apart
//! from App so hit routing and the state machine stay auditable and small.

const std = @import("std");
const xsui = @import("xsui");
const app_mod = @import("app.zig");
const action_mod = @import("action.zig");
const state_mod = @import("state.zig");
const route = @import("route.zig");
const hits = @import("hits.zig");
const settings = @import("settings.zig");
const picker = @import("picker.zig");
const source = @import("source.zig");
const recorder = @import("recorder.zig");

const App = app_mod.App;

pub fn handle(app: *App, canvas: *xsui.Canvas, x: f32, y: f32) void {
    const id = canvas.hitAt(x, y) orelse return;
    app.state.focus_id = id;
    app.state.focus_visible = false;
    routeClick(app, id);
}

fn routeClick(app: *App, id: u32) void {
    const state = &app.state;
    // Modal overlays own their id ranges while open.
    switch (state.dialog) {
        .palette => {
            if (id >= hits.palette_row_base and id < hits.palette_row_base + hits.palette_row_max) {
                app.runPaletteCommand(id - hits.palette_row_base);
                return;
            }
            if (id == hits.palette_esc) return app.applyAction(.close_dialog);
            if (id == hits.palette_input) {
                state.text_focus = .palette;
                return;
            }
            return;
        },
        .appearance => {
            if (id >= hits.theme_option_base and id < hits.theme_option_base + 6) {
                app.applyAction(.{ .theme = id - hits.theme_option_base });
                return;
            }
            if (id == hits.dialog_close) return app.applyAction(.close_dialog);
            return;
        },
        .help => {
            if (id == hits.help_close) app.applyAction(.close_dialog);
            return;
        },
        .confirm => {
            if (id == hits.confirm_yes) return app.applyAction(.confirm_yes);
            if (id == hits.confirm_no) return app.applyAction(.confirm_no);
            return;
        },
        .picker => return pickerClick(app, id),
        .onboarding => return onboardingClick(app, id),
        .none => {},
    }

    if (route.fromRailId(id)) |target| return app.applyAction(.{ .nav = target });

    switch (id) {
        hits.topbar_palette => return app.applyAction(.open_palette),
        hits.topbar_theme => return app.applyAction(.open_appearance),
        hits.topbar_help => return app.applyAction(.open_help),
        hits.open_journal => return app.applyAction(.open_journal),
        hits.reload_fixture => return app.applyAction(.reload_source),
        hits.timeline_zoom_in => return app.applyAction(.{ .zoom = 1.5 }),
        hits.timeline_zoom_out => return app.applyAction(.{ .zoom = 0.75 }),
        hits.timeline_fit => return app.applyAction(.fit),
        hits.timeline_play => return app.applyAction(.toggle_play),
        hits.timeline_advisor => return app.applyAction(.{ .nav = .advisor }),
        hits.timeline_minimap => return minimapClick(app, id),
        hits.events_filter => {
            state.events_filter_focused = true;
            state.text_focus = .events_filter;
            return;
        },
        hits.events_to_timeline => return eventsTimeline(app),
        hits.events_filter_task => return eventsFilterTask(app),
        hits.onboarding_next => {
            if (state.onboarding.isLast()) {
                return app.applyAction(.onboarding_finish);
            }
            return app.applyAction(.onboarding_next);
        },
        hits.onboarding_back => return app.applyAction(.onboarding_back),
        hits.onboarding_skip => return app.applyAction(.onboarding_skip),
        hits.onboarding_finish => return app.applyAction(.onboarding_finish),
        hits.recorder_start => return app.applyAction(.{ .recorder = .start }),
        hits.recorder_stop => return app.applyAction(.{ .recorder = .stop }),
        hits.recorder_restart => return app.applyAction(.{ .recorder = .restart }),
        hits.recorder_extract => return app.applyAction(.{ .recorder = .extract }),
        hits.recorder_attach => return app.applyAction(.{ .recorder = .attach }),
        hits.recorder_export_journal => return app.applyAction(.{ .export_file = .journal }),
        hits.recorder_export_trace => return app.applyAction(.{ .export_file = .trace }),
        hits.recorder_export_report => return app.applyAction(.{ .export_file = .report }),
        hits.recorder_export_incident => return app.applyAction(.{ .export_file = .incident }),
        hits.confirm_no => return app.applyAction(.confirm_no),
        hits.audit_verify => return app.applyAction(.audit_verify),
        hits.audit_copy => return app.applyAction(.audit_copy),
        hits.audit_export => return app.applyAction(.audit_export),
        hits.settings_reduced_motion => return app.applyAction(.{ .settings_toggle = .reduced_motion }),
        hits.settings_a11y_announce => return app.applyAction(.{ .settings_toggle = .a11y_announce }),
        hits.settings_a11y_tree => return app.applyAction(.{ .settings_toggle = .a11y_tree }),
        hits.settings_capture_enabled => return app.applyAction(.{ .settings_toggle = .capture_enabled }),
        hits.settings_recorder_dir => {
            state.text_focus = .recorder_dir;
            return;
        },
        hits.settings_reset => return app.applyAction(.settings_reset),
        hits.settings_save => return app.applyAction(.settings_save),
        hits.home_live => return app.applyAction(.{ .source_select = .live }),
        hits.home_replay => return app.applyAction(.{ .source_select = .replay }),
        hits.home_recorder_window => return app.applyAction(.{ .source_select = .recorder_window }),
        hits.home_demo => return app.applyAction(.{ .source_select = .demo }),
        hits.home_open => return app.applyAction(.{ .nav = .timeline }),
        hits.home_refresh => return app.applyAction(.reload_source),
        hits.recents_clear => return app.applyAction(.recents_clear),
        hits.picker_up => return app.applyAction(.{ .picker_move = -1 }),
        hits.picker_refresh => return app.applyAction(.picker_enter),
        hits.picker_cancel => return app.applyAction(.picker_close),
        hits.text_events_filter => {
            state.events_filter_focused = true;
            state.text_focus = .events_filter;
            return;
        },
        hits.text_recorder_dir => {
            state.text_focus = .recorder_dir;
            return;
        },
        else => {},
    }

    // Dynamic ranges.
    if (id >= hits.home_window_base and id < hits.home_window_base + hits.home_window_max) {
        const index = id - hits.home_window_base;
        const presets = [_]source.WindowPreset{ .one_minute, .five_minutes, .ten_minutes, .retained, .custom };
        if (index < presets.len) return app.applyAction(.{ .source_window = presets[index] });
        return;
    }
    if (id >= hits.recents_base and id < hits.recents_base + hits.recents_max) {
        return app.applyAction(.{ .recents_open = id - hits.recents_base });
    }
    if (id >= hits.advisor_filter_base and id < hits.advisor_filter_base + hits.advisor_filter_max) {
        state.advisor_filter = @fromBackingInt(@intCast(id - hits.advisor_filter_base));
        return;
    }
    if (id >= hits.events_type_base and id < hits.events_type_base + hits.events_type_max) {
        const types = [_][]const u8{ "all", "sched_switch", "sched_wakeup", "sched_migrate", "page_fault", "cache_miss", "loss" };
        const index = id - hits.events_type_base;
        if (index < types.len) state.events_type = types[index];
        return;
    }
    if (id >= hits.events_row_base and id < hits.events_row_base + hits.events_row_max) {
        state.events_selected = id - hits.events_row_base;
        return;
    }
    if (id >= hits.advisor_card_base and id < hits.advisor_card_base + hits.advisor_card_max) {
        return advisorEvidence(app, id - hits.advisor_card_base);
    }
    if (id >= hits.capture_copy_base and id < hits.capture_copy_base + hits.capture_copy_max) {
        return captureCopy(app, id - hits.capture_copy_base);
    }
    if (id >= hits.settings_theme_base and id < hits.settings_theme_base + hits.settings_theme_max) {
        return app.applyAction(.{ .theme = id - hits.settings_theme_base });
    }
    if (id >= hits.slice_base and id < hits.slice_base + hits.slice_max) {
        state.selected_slice = id - hits.slice_base;
        return;
    }
}

fn pickerClick(app: *App, id: u32) void {
    if (id >= hits.picker_row_base and id < hits.picker_row_base + hits.picker_row_max) {
        const index = id - hits.picker_row_base;
        const state = &app.state;
        if (state.picker.len == 0) return;
        state.picker.selected = @min(index, state.picker.len - 1);
        app.applyAction(.picker_enter);
        return;
    }
    switch (id) {
        hits.picker_up => app.applyAction(.{ .picker_move = -1 }),
        hits.picker_refresh => app.applyAction(.picker_enter),
        hits.picker_cancel => app.applyAction(.picker_close),
        hits.picker_confirm => app.applyAction(.picker_enter),
        hits.picker_filter => app.state.text_focus = .picker_filter,
        else => {},
    }
}

fn onboardingClick(app: *App, id: u32) void {
    switch (id) {
        hits.onboarding_next, hits.onboarding_finish => {
            if (app.state.onboarding.isLast()) {
                app.applyAction(.onboarding_finish);
            } else {
                app.applyAction(.onboarding_next);
            }
        },
        hits.onboarding_back => app.applyAction(.onboarding_back),
        hits.onboarding_skip => app.applyAction(.onboarding_skip),
        else => {},
    }
}

fn minimapClick(app: *App, id: u32) void {
    _ = id;
    const state = &app.state;
    const start = state.viewStart(app.model.summary.windowMs);
    const window = app.model.summary.windowMs;
    const span = @max(300.0, state.viewEnd(window) - start);
    state.timeline_start = std.math.clamp(state.timeline_playhead - span * 0.5, 0, @max(0, window - span));
    state.timeline_end = @min(window, state.timeline_start + span);
}

fn eventsTimeline(app: *App) void {
    const state = &app.state;
    if (state.events_selected) |index| {
        if (index < app.model.events.len) {
            const event = app.model.events[index];
            state.timeline_start = @max(0, event.ts - 800);
            state.timeline_end = @min(app.model.summary.windowMs, event.ts + 800);
            app.applyAction(.{ .nav = .timeline });
            app.showToast("timeline at event", false);
        }
    }
}

fn eventsFilterTask(app: *App) void {
    const state = &app.state;
    if (state.events_selected) |index| {
        if (index < app.model.events.len) {
            const comm = app.model.events[index].comm;
            app.applyAction(.{ .text = .{ .field = .events_filter, .op = .clear } });
            for (comm) |codepoint| {
                app.applyAction(.{ .text = .{ .field = .events_filter, .op = .{ .insert = codepoint } } });
            }
            state.events_type = "all";
            app.showToast("filtered to task", false);
        }
    }
}

fn advisorEvidence(app: *App, index: u32) void {
    const state = &app.state;
    if (index < app.model.advisor.len) {
        if (app.model.advisor[index].focus) |focus| {
            state.timeline_start = @max(0, focus.from - 150);
            state.timeline_end = @min(app.model.summary.windowMs, focus.to + 150);
            app.applyAction(.{ .nav = .timeline });
            app.showToast("advisor evidence focused", false);
        }
    }
}

fn captureCopy(app: *App, index: u32) void {
    const capture = @import("capture.zig");
    if (index < capture.commands.len) {
        app.requestCopy(capture.commands[index][1]);
        app.showToast("command copied", false);
    }
}

test "rail clicks map to routes and keep legacy ids" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    var frame: xsui.frame.Frame = undefined;
    try frame.init(std.testing.allocator, 400, 400, .{});
    defer frame.deinit();
    var canvas = xsui.Canvas.init(&frame);
    defer canvas.deinit();
    canvas.hit(105, .{ .x = 0, .y = 0, .w = 10, .h = 10 });
    handle(&app, &canvas, 5, 5);
    try std.testing.expectEqual(state_mod.Route.home, app.state.screen);
    canvas.resetHits();
    canvas.hit(103, .{ .x = 0, .y = 0, .w = 10, .h = 10 });
    handle(&app, &canvas, 5, 5);
    try std.testing.expectEqual(state_mod.Route.events, app.state.screen);
}

test "capture copy hit keeps legacy behaviour" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    var frame: xsui.frame.Frame = undefined;
    try frame.init(std.testing.allocator, 400, 400, .{});
    defer frame.deinit();
    var canvas = xsui.Canvas.init(&frame);
    defer canvas.deinit();
    canvas.hit(800, .{ .x = 0, .y = 0, .w = 10, .h = 10 });
    handle(&app, &canvas, 5, 5);
    const capture = @import("capture.zig");
    try std.testing.expectEqualStrings(capture.commands[0][1], app.copyText());
}

test "snapshot recorder control click is refused without mutating state" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    app.setSurface(.snapshot);
    var frame: xsui.frame.Frame = undefined;
    try frame.init(std.testing.allocator, 400, 400, .{});
    defer frame.deinit();
    var canvas = xsui.Canvas.init(&frame);
    defer canvas.deinit();
    canvas.hit(hits.recorder_start, .{ .x = 0, .y = 0, .w = 10, .h = 10 });
    handle(&app, &canvas, 5, 5);
    try std.testing.expectEqual(recorder.Phase.idle, app.state.recorder.phase);
    try std.testing.expect(app.state.toast != null);
}
