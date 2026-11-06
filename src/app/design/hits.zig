//! Hit-id catalogue for the product console. Ids are a stable contract: every
//! interactive/accessible rectangle registers one; clicks, focus, and the
//! accessibility tree all resolve through this catalogue.
//!
//! Ranges:
//!   100..107        rail route items (100 + @backingInt(route))
//!   200..299        topbar/shell actions
//!   300..399        timeline transport/plot controls
//!   400..499        advisor filters
//!   500..599        events ledger rows/filter (data rows use 500 + index)
//!   600..699        events type chips + detail actions
//!   700..799        palette/appearance/help/confirm overlays
//!   800..899        capture command copy buttons
//!   900..999        advisor evidence cards
//!   1000..2999      DATA range: 1000 + slice index (legacy; see TODO Hit.data)
//!   3000..3099      home source/frame/recorder strip
//!   3100..3199      recents
//!   3150..3199      onboarding (subset of recents range, kept distinct below)
//!   3200..3299      recorder management + confirm
//!   3300..3399      audit actions
//!   3400..3499      settings controls
//!   3500..3599      picker rows/actions
//!   3600..3699      text fields
//!   3700..3799      confirmation dialogs
//!   3800..3899      shell extras (source chip menu, share)
//!   3900..3999      reserved

const std = @import("std");

pub const rail_base: u32 = 100;
pub const rail_max: u32 = 107;

pub const topbar_palette: u32 = 200;
pub const topbar_theme: u32 = 201;
pub const topbar_help: u32 = 202;
pub const open_journal: u32 = 203;
pub const reload_fixture: u32 = 204;

pub const timeline_zoom_in: u32 = 300;
pub const timeline_zoom_out: u32 = 301;
pub const timeline_fit: u32 = 302;
pub const timeline_play: u32 = 303;
pub const timeline_advisor: u32 = 304;
pub const timeline_minimap: u32 = 305;

pub const advisor_filter_base: u32 = 400;
pub const advisor_filter_max: u32 = 5;
pub const advisor_card_base: u32 = 900;
pub const advisor_card_max: u32 = 8;

pub const events_filter: u32 = 520;
pub const events_row_base: u32 = 500;
pub const events_row_max: u32 = 20;
pub const events_type_base: u32 = 600;
pub const events_type_max: u32 = 7;
pub const events_to_timeline: u32 = 610;
pub const events_filter_task: u32 = 611;

pub const palette_row_base: u32 = 700;
/// Palette rows are modal: while the palette is open ids 700..739 belong to
/// commands, so theme option ids 720..725 are only live in the appearance
/// dialog. This keeps legacy ids frozen while the palette grows past 20.
pub const palette_row_max: u32 = 40;
pub const palette_input: u32 = 742;
pub const palette_esc: u32 = 743;
pub const theme_option_base: u32 = 720;
pub const theme_option_max: u32 = 6;
pub const dialog_close: u32 = 740;
pub const help_close: u32 = 741;

pub const capture_copy_base: u32 = 800;
pub const capture_copy_max: u32 = 4;

pub const slice_base: u32 = 1000;
pub const slice_max: u32 = 2000;
pub const data_max: u32 = 2999;

// Home / source selection.
pub const home_live: u32 = 3000;
pub const home_replay: u32 = 3001;
pub const home_recorder_window: u32 = 3002;
pub const home_demo: u32 = 3003;
pub const home_open: u32 = 3004;
pub const home_window_base: u32 = 3010;
pub const home_window_max: u32 = 6;
pub const home_refresh: u32 = 3020;
pub const home_capability_base: u32 = 3030;
pub const home_capability_max: u32 = 8;

// Recents.
pub const recents_base: u32 = 3100;
pub const recents_max: u32 = 10;
pub const recents_clear: u32 = 3111;

// Onboarding overlay (4 steps).
pub const onboarding_next: u32 = 3150;
pub const onboarding_back: u32 = 3151;
pub const onboarding_skip: u32 = 3152;
pub const onboarding_finish: u32 = 3153;

// Recorder management (+ confirm overlay).
pub const recorder_start: u32 = 3200;
pub const recorder_stop: u32 = 3201;
pub const recorder_restart: u32 = 3202;
pub const recorder_extract: u32 = 3203;
pub const recorder_attach: u32 = 3204;
pub const recorder_export_journal: u32 = 3210;
pub const recorder_export_trace: u32 = 3211;
pub const recorder_export_report: u32 = 3212;
pub const recorder_export_incident: u32 = 3213;
pub const recorder_copy_base: u32 = 3220;
pub const recorder_copy_max: u32 = 8;
pub const confirm_yes: u32 = 3230;
pub const confirm_no: u32 = 3231;

// Audit view.
pub const audit_verify: u32 = 3300;
pub const audit_copy: u32 = 3301;
pub const audit_export: u32 = 3302;
pub const audit_filter_base: u32 = 3310;
pub const audit_filter_max: u32 = 4;
pub const audit_action_base: u32 = 3320;
pub const audit_action_max: u32 = 12;

// Settings.
pub const settings_theme_base: u32 = 3400;
pub const settings_theme_max: u32 = 6;
pub const settings_reduced_motion: u32 = 3410;
pub const settings_a11y_announce: u32 = 3411;
pub const settings_a11y_tree: u32 = 3412;
pub const settings_capture_enabled: u32 = 3413;
pub const settings_recorder_dir: u32 = 3414;
pub const settings_reset: u32 = 3415;
pub const settings_save: u32 = 3416;
pub const settings_section_base: u32 = 3420;
pub const settings_section_max: u32 = 6;
pub const settings_option_base: u32 = 3430;
pub const settings_option_max: u32 = 16;
pub const settings_about: u32 = 3440;

// GPU picker overlay.
pub const picker_row_base: u32 = 3500;
pub const picker_row_max: u32 = 128;
pub const picker_up: u32 = 3640;
pub const picker_refresh: u32 = 3641;
pub const picker_cancel: u32 = 3642;
pub const picker_confirm: u32 = 3643;
pub const picker_filter: u32 = 3644;

// Text fields (focus targets with a caret).
pub const text_events_filter: u32 = 3600;
pub const text_palette: u32 = 3601;
pub const text_picker_filter: u32 = 3602;
pub const text_recorder_dir: u32 = 3603;

// Confirmation overlay (generic).
pub const shell_source_menu: u32 = 3800;
pub const shell_share: u32 = 3801;

pub fn isRail(id: u32) bool {
    return id >= rail_base and id <= rail_max;
}

/// Legacy id-as-index encoding. New code should read Hit.data once the xsui
/// runtime exposes it; until then dispatch keeps the historical ranges.
pub fn isDataId(id: u32) bool {
    return id >= slice_base and id < 3000;
}

pub fn isShellId(id: u32) bool {
    return id >= 3000;
}

pub fn railId(backing: u32) u32 {
    return rail_base + backing;
}

pub fn railBacking(id: u32) ?u32 {
    if (!isRail(id)) return null;
    return id - rail_base;
}

test "hit ranges do not overlap" {
    const ranges = [_][2]u32{
        .{ rail_base, rail_max },
        .{ 200, 299 },
        .{ 300, 399 },
        .{ 400, 499 },
        .{ 500, 599 },
        .{ 600, 699 },
        .{ 700, 799 },
        .{ 800, 899 },
        .{ 900, 999 },
        .{ slice_base, data_max },
        .{ 3000, 3099 },
        .{ 3100, 3199 },
        .{ 3200, 3299 },
        .{ 3300, 3399 },
        .{ 3400, 3499 },
        .{ 3500, 3599 },
        .{ 3600, 3699 },
        .{ 3700, 3799 },
        .{ 3800, 3899 },
        .{ 3900, 3999 },
    };
    var i: usize = 0;
    while (i < ranges.len) : (i += 1) {
        try std.testing.expect(ranges[i][0] <= ranges[i][1]);
        var j: usize = i + 1;
        while (j < ranges.len) : (j += 1) {
            const disjoint = ranges[i][1] < ranges[j][0] or ranges[j][1] < ranges[i][0];
            try std.testing.expect(disjoint);
        }
    }
    try std.testing.expectEqual(@as(u32, 104), railId(4));
    try std.testing.expectEqual(@as(u32, 105), railId(5));
    try std.testing.expectEqual(@as(?u32, 7), railBacking(107));
}
