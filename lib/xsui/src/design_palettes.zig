//! Generated from design/palettes.json. Do not edit by hand.
//! Regenerate with tools/gen_design_tokens.py; keep design/validate.py green.

const draw = @import("draw.zig");

pub const Palette = draw.Theme;
pub const design_source_sha256 = "0823328b3261b89ce2d8c2af53ebc61adfedd49f19706239e437b7fdb6a3de62";

pub const Preset = struct {
    id: []const u8,
    name: []const u8,
    kind: []const u8,
    group: []const u8,
    theme: Palette,
};

pub const graphite_palette: Palette = .{
    .bg = .{ .r = 0x05, .g = 0x05, .b = 0x05 },
    .panel = .{ .r = 0x10, .g = 0x10, .b = 0x0e },
    .raised = .{ .r = 0x17, .g = 0x15, .b = 0x12 },
    .raised2 = .{ .r = 0x1e, .g = 0x1b, .b = 0x17 },
    .field = .{ .r = 0x0b, .g = 0x0b, .b = 0x0a },
    .text = .{ .r = 0xf5, .g = 0xef, .b = 0xe4 },
    .muted = .{ .r = 0xa7, .g = 0x9b, .b = 0x8c },
    .dim = .{ .r = 0x9a, .g = 0x8d, .b = 0x7b },
    .faint = .{ .r = 0x8a, .g = 0x7e, .b = 0x6f },
    .line = .{ .r = 0x26, .g = 0x23, .b = 0x20 },
    .line_strong = .{ .r = 0x3a, .g = 0x33, .b = 0x2b },
    .live = .{ .r = 0x58, .g = 0xd7, .b = 0xe8 },
    .pass = .{ .r = 0x72, .g = 0xd4, .b = 0x87 },
    .skip = .{ .r = 0xe3, .g = 0xb4, .b = 0x5c },
    .refuse = .{ .r = 0xff, .g = 0x6b, .b = 0x9a },
    .pending = .{ .r = 0xde, .g = 0xd6, .b = 0xc9 },
    .vm = .{ .r = 0xb4, .g = 0x8c, .b = 0xff },
    .tint_live = .{ .r = 0x58, .g = 0xd7, .b = 0xe8, .a = 26 },
    .tint_refuse = .{ .r = 0xff, .g = 0x6b, .b = 0x9a, .a = 23 },
    .tint_skip = .{ .r = 0xe3, .g = 0xb4, .b = 0x5c, .a = 23 },
    .tint_pass = .{ .r = 0x72, .g = 0xd4, .b = 0x87, .a = 20 },
    .lane_idle = .{ .r = 0x1c, .g = 0x1a, .b = 0x17 },
    .lane_grid = .{ .r = 0x20, .g = 0x1d, .b = 0x19 },
    .focus = .{ .r = 0x58, .g = 0xd7, .b = 0xe8 },
    .lanes = .{
        .{ .r = 0x58, .g = 0xd7, .b = 0xe8 }, // lane 1
        .{ .r = 0x72, .g = 0xd4, .b = 0x87 }, // lane 2
        .{ .r = 0xe3, .g = 0xb4, .b = 0x5c }, // lane 3
        .{ .r = 0xff, .g = 0x6b, .b = 0x9a }, // lane 4
        .{ .r = 0xb4, .g = 0x8c, .b = 0xff }, // lane 5
        .{ .r = 0x9d, .g = 0xb4, .b = 0xc0 }, // lane 6
        .{ .r = 0xc8, .g = 0xb4, .b = 0x8a }, // lane 7
        .{ .r = 0x4f, .g = 0xb3, .b = 0xa3 }, // lane 8
        .{ .r = 0xd7, .g = 0x9c, .b = 0xc4 }, // lane 9
    },
    .hairline = .{ .r = 0x26, .g = 0x23, .b = 0x20 },
    .chip_source_border = .{ .r = 0x3a, .g = 0x6b, .b = 0x70 },
    .chip_journal_border = .{ .r = 0x46, .g = 0x6d, .b = 0x4b },
    .chip_loss_border = .{ .r = 0x7d, .g = 0x40, .b = 0x51 },
    .control_pressed_border = .{ .r = 0x3c, .g = 0x74, .b = 0x7a },
    .button_hover_border = .{ .r = 0x72, .g = 0x6b, .b = 0x62 },
    .segment_loss_border = .{ .r = 0x88, .g = 0x43, .b = 0x57 },
    .refuse_chip_border = .{ .r = 0x78, .g = 0x3e, .b = 0x4e },
    .theme_option_active_border = .{ .r = 0x42, .g = 0x86, .b = 0x8e },
    .ledger_loss_hover = .{ .r = 0x31, .g = 0x1d, .b = 0x22 },
};

pub const paper_palette: Palette = .{
    .bg = .{ .r = 0xf3, .g = 0xea, .b = 0xd7 },
    .panel = .{ .r = 0xf8, .g = 0xf1, .b = 0xe3 },
    .raised = .{ .r = 0xec, .g = 0xe1, .b = 0xcc },
    .raised2 = .{ .r = 0xe3, .g = 0xd6, .b = 0xbd },
    .field = .{ .r = 0xfd, .g = 0xf8, .b = 0xee },
    .text = .{ .r = 0x1b, .g = 0x18, .b = 0x13 },
    .muted = .{ .r = 0x5f, .g = 0x54, .b = 0x45 },
    .dim = .{ .r = 0x6f, .g = 0x63, .b = 0x52 },
    .faint = .{ .r = 0x71, .g = 0x65, .b = 0x55 },
    .line = .{ .r = 0xde, .g = 0xd0, .b = 0xb8 },
    .line_strong = .{ .r = 0xc3, .g = 0xb2, .b = 0x99 },
    .live = .{ .r = 0x0c, .g = 0x67, .b = 0x76 },
    .pass = .{ .r = 0x25, .g = 0x6a, .b = 0x3b },
    .skip = .{ .r = 0x8a, .g = 0x5a, .b = 0x10 },
    .refuse = .{ .r = 0xa3, .g = 0x27, .b = 0x54 },
    .pending = .{ .r = 0x4a, .g = 0x40, .b = 0x34 },
    .vm = .{ .r = 0x5a, .g = 0x3f, .b = 0x9e },
    .tint_live = .{ .r = 0x0d, .g = 0x6c, .b = 0x7c, .a = 26 },
    .tint_refuse = .{ .r = 0xa3, .g = 0x27, .b = 0x54, .a = 23 },
    .tint_skip = .{ .r = 0x8a, .g = 0x5a, .b = 0x10, .a = 26 },
    .tint_pass = .{ .r = 0x25, .g = 0x6a, .b = 0x3b, .a = 20 },
    .lane_idle = .{ .r = 0xe6, .g = 0xdb, .b = 0xc6 },
    .lane_grid = .{ .r = 0xde, .g = 0xd0, .b = 0xb8 },
    .focus = .{ .r = 0x0c, .g = 0x67, .b = 0x76 },
    .lanes = .{
        .{ .r = 0x0d, .g = 0x6c, .b = 0x7c }, // lane 1
        .{ .r = 0x2f, .g = 0x7d, .b = 0x4a }, // lane 2
        .{ .r = 0x9a, .g = 0x6a, .b = 0x12 }, // lane 3
        .{ .r = 0xa8, .g = 0x30, .b = 0x5a }, // lane 4
        .{ .r = 0x6b, .g = 0x4b, .b = 0xb0 }, // lane 5
        .{ .r = 0x4a, .g = 0x65, .b = 0x72 }, // lane 6
        .{ .r = 0x7d, .g = 0x6a, .b = 0x3f }, // lane 7
        .{ .r = 0x2a, .g = 0x7f, .b = 0x74 }, // lane 8
        .{ .r = 0x9a, .g = 0x44, .b = 0x72 }, // lane 9
    },
    .hairline = .{ .r = 0xde, .g = 0xd0, .b = 0xb8 },
    .chip_source_border = .{ .r = 0x8a, .g = 0xa6, .b = 0x9e },
    .chip_journal_border = .{ .r = 0x90, .g = 0xa5, .b = 0x84 },
    .chip_loss_border = .{ .r = 0xc6, .g = 0x8c, .b = 0x90 },
    .control_pressed_border = .{ .r = 0x80, .g = 0xa1, .b = 0x9a },
    .button_hover_border = .{ .r = 0x91, .g = 0x84, .b = 0x71 },
    .segment_loss_border = .{ .r = 0xc3, .g = 0x84, .b = 0x8b },
    .refuse_chip_border = .{ .r = 0xc8, .g = 0x90, .b = 0x92 },
    .theme_option_active_border = .{ .r = 0x6a, .g = 0x96, .b = 0x94 },
    .ledger_loss_hover = .{ .r = 0xec, .g = 0xd5, .b = 0xcf },
};

pub const latte_palette: Palette = .{
    .bg = .{ .r = 0xdc, .g = 0xe0, .b = 0xe8 },
    .panel = .{ .r = 0xef, .g = 0xf1, .b = 0xf5 },
    .raised = .{ .r = 0xe6, .g = 0xe9, .b = 0xef },
    .raised2 = .{ .r = 0xcc, .g = 0xd0, .b = 0xda },
    .field = .{ .r = 0xef, .g = 0xf1, .b = 0xf5 },
    .text = .{ .r = 0x4c, .g = 0x4f, .b = 0x69 },
    .muted = .{ .r = 0x53, .g = 0x56, .b = 0x6d },
    .dim = .{ .r = 0x58, .g = 0x5b, .b = 0x72 },
    .faint = .{ .r = 0x5c, .g = 0x5f, .b = 0x77 },
    .line = .{ .r = 0xcc, .g = 0xd0, .b = 0xda },
    .line_strong = .{ .r = 0xbc, .g = 0xc0, .b = 0xcc },
    .live = .{ .r = 0x17, .g = 0x53, .b = 0xb9 },
    .pass = .{ .r = 0x27, .g = 0x6b, .b = 0x2a },
    .skip = .{ .r = 0x85, .g = 0x57, .b = 0x00 },
    .refuse = .{ .r = 0xc1, .g = 0x0f, .b = 0x36 },
    .pending = .{ .r = 0x5c, .g = 0x5f, .b = 0x77 },
    .vm = .{ .r = 0x88, .g = 0x39, .b = 0xef },
    .tint_live = .{ .r = 0x1e, .g = 0x66, .b = 0xf5, .a = 26 },
    .tint_refuse = .{ .r = 0xd2, .g = 0x0f, .b = 0x39, .a = 23 },
    .tint_skip = .{ .r = 0xdf, .g = 0x8e, .b = 0x1d, .a = 31 },
    .tint_pass = .{ .r = 0x40, .g = 0xa0, .b = 0x2b, .a = 26 },
    .lane_idle = .{ .r = 0xdc, .g = 0xe0, .b = 0xe8 },
    .lane_grid = .{ .r = 0xcc, .g = 0xd0, .b = 0xda },
    .focus = .{ .r = 0x17, .g = 0x53, .b = 0xb9 },
    .lanes = .{
        .{ .r = 0x1e, .g = 0x66, .b = 0xf5 }, // lane 1
        .{ .r = 0x40, .g = 0xa0, .b = 0x2b }, // lane 2
        .{ .r = 0xdf, .g = 0x8e, .b = 0x1d }, // lane 3
        .{ .r = 0xd2, .g = 0x0f, .b = 0x39 }, // lane 4
        .{ .r = 0x88, .g = 0x39, .b = 0xef }, // lane 5
        .{ .r = 0x17, .g = 0x92, .b = 0x99 }, // lane 6
        .{ .r = 0xfe, .g = 0x64, .b = 0x0b }, // lane 7
        .{ .r = 0x04, .g = 0xa5, .b = 0xe5 }, // lane 8
        .{ .r = 0xea, .g = 0x76, .b = 0xcb }, // lane 9
    },
    .hairline = .{ .r = 0xcc, .g = 0xd0, .b = 0xda },
    .chip_source_border = .{ .r = 0x84, .g = 0x9e, .b = 0xcd },
    .chip_journal_border = .{ .r = 0x87, .g = 0xa6, .b = 0x90 },
    .chip_loss_border = .{ .r = 0xc8, .g = 0x83, .b = 0x98 },
    .control_pressed_border = .{ .r = 0x7b, .g = 0x98, .b = 0xcb },
    .button_hover_border = .{ .r = 0x9a, .g = 0x9e, .b = 0xae },
    .segment_loss_border = .{ .r = 0xc7, .g = 0x79, .b = 0x90 },
    .refuse_chip_border = .{ .r = 0xc8, .g = 0x87, .b = 0x9c },
    .theme_option_active_border = .{ .r = 0x68, .g = 0x8b, .b = 0xc8 },
    .ledger_loss_hover = .{ .r = 0xe9, .g = 0xd1, .b = 0xda },
};

pub const frappe_palette: Palette = .{
    .bg = .{ .r = 0x23, .g = 0x26, .b = 0x34 },
    .panel = .{ .r = 0x30, .g = 0x34, .b = 0x46 },
    .raised = .{ .r = 0x41, .g = 0x45, .b = 0x59 },
    .raised2 = .{ .r = 0x51, .g = 0x57, .b = 0x6d },
    .field = .{ .r = 0x29, .g = 0x2c, .b = 0x3c },
    .text = .{ .r = 0xc6, .g = 0xd0, .b = 0xf5 },
    .muted = .{ .r = 0xb5, .g = 0xbf, .b = 0xe2 },
    .dim = .{ .r = 0xa5, .g = 0xad, .b = 0xce },
    .faint = .{ .r = 0x94, .g = 0x9c, .b = 0xbb },
    .line = .{ .r = 0x41, .g = 0x45, .b = 0x59 },
    .line_strong = .{ .r = 0x51, .g = 0x57, .b = 0x6d },
    .live = .{ .r = 0x91, .g = 0xad, .b = 0xef },
    .pass = .{ .r = 0xa6, .g = 0xd1, .b = 0x89 },
    .skip = .{ .r = 0xe5, .g = 0xc8, .b = 0x90 },
    .refuse = .{ .r = 0xea, .g = 0x91, .b = 0x93 },
    .pending = .{ .r = 0xa5, .g = 0xad, .b = 0xce },
    .vm = .{ .r = 0xca, .g = 0x9e, .b = 0xe6 },
    .tint_live = .{ .r = 0x8c, .g = 0xaa, .b = 0xee, .a = 26 },
    .tint_refuse = .{ .r = 0xe7, .g = 0x82, .b = 0x84, .a = 23 },
    .tint_skip = .{ .r = 0xe5, .g = 0xc8, .b = 0x90, .a = 23 },
    .tint_pass = .{ .r = 0xa6, .g = 0xd1, .b = 0x89, .a = 20 },
    .lane_idle = .{ .r = 0x29, .g = 0x2c, .b = 0x3c },
    .lane_grid = .{ .r = 0x41, .g = 0x45, .b = 0x59 },
    .focus = .{ .r = 0x91, .g = 0xad, .b = 0xef },
    .lanes = .{
        .{ .r = 0x99, .g = 0xd1, .b = 0xdb }, // lane 1
        .{ .r = 0xa6, .g = 0xd1, .b = 0x89 }, // lane 2
        .{ .r = 0xe5, .g = 0xc8, .b = 0x90 }, // lane 3
        .{ .r = 0xe7, .g = 0x82, .b = 0x84 }, // lane 4
        .{ .r = 0xca, .g = 0x9e, .b = 0xe6 }, // lane 5
        .{ .r = 0x81, .g = 0xc8, .b = 0xbe }, // lane 6
        .{ .r = 0xef, .g = 0x9f, .b = 0x76 }, // lane 7
        .{ .r = 0xba, .g = 0xbb, .b = 0xf1 }, // lane 8
        .{ .r = 0xf4, .g = 0xb8, .b = 0xe4 }, // lane 9
    },
    .hairline = .{ .r = 0x41, .g = 0x45, .b = 0x59 },
    .chip_source_border = .{ .r = 0x61, .g = 0x6f, .b = 0x95 },
    .chip_journal_border = .{ .r = 0x6b, .g = 0x80, .b = 0x6d },
    .chip_loss_border = .{ .r = 0x85, .g = 0x63, .b = 0x70 },
    .control_pressed_border = .{ .r = 0x65, .g = 0x74, .b = 0x9c },
    .button_hover_border = .{ .r = 0x74, .g = 0x7b, .b = 0x96 },
    .segment_loss_border = .{ .r = 0x8d, .g = 0x67, .b = 0x73 },
    .refuse_chip_border = .{ .r = 0x81, .g = 0x62, .b = 0x6f },
    .theme_option_active_border = .{ .r = 0x6d, .g = 0x7e, .b = 0xac },
    .ledger_loss_hover = .{ .r = 0x4a, .g = 0x41, .b = 0x51 },
};

pub const macchiato_palette: Palette = .{
    .bg = .{ .r = 0x18, .g = 0x19, .b = 0x26 },
    .panel = .{ .r = 0x24, .g = 0x27, .b = 0x3a },
    .raised = .{ .r = 0x36, .g = 0x3a, .b = 0x4f },
    .raised2 = .{ .r = 0x49, .g = 0x4d, .b = 0x64 },
    .field = .{ .r = 0x1e, .g = 0x20, .b = 0x30 },
    .text = .{ .r = 0xca, .g = 0xd3, .b = 0xf5 },
    .muted = .{ .r = 0xb8, .g = 0xc0, .b = 0xe0 },
    .dim = .{ .r = 0xa5, .g = 0xad, .b = 0xcb },
    .faint = .{ .r = 0x93, .g = 0x9a, .b = 0xb7 },
    .line = .{ .r = 0x36, .g = 0x3a, .b = 0x4f },
    .line_strong = .{ .r = 0x49, .g = 0x4d, .b = 0x64 },
    .live = .{ .r = 0x8a, .g = 0xad, .b = 0xf4 },
    .pass = .{ .r = 0xa6, .g = 0xda, .b = 0x95 },
    .skip = .{ .r = 0xee, .g = 0xd4, .b = 0x9f },
    .refuse = .{ .r = 0xed, .g = 0x87, .b = 0x96 },
    .pending = .{ .r = 0xa5, .g = 0xad, .b = 0xcb },
    .vm = .{ .r = 0xc6, .g = 0xa0, .b = 0xf6 },
    .tint_live = .{ .r = 0x8a, .g = 0xad, .b = 0xf4, .a = 26 },
    .tint_refuse = .{ .r = 0xed, .g = 0x87, .b = 0x96, .a = 23 },
    .tint_skip = .{ .r = 0xee, .g = 0xd4, .b = 0x9f, .a = 23 },
    .tint_pass = .{ .r = 0xa6, .g = 0xda, .b = 0x95, .a = 20 },
    .lane_idle = .{ .r = 0x1e, .g = 0x20, .b = 0x30 },
    .lane_grid = .{ .r = 0x36, .g = 0x3a, .b = 0x4f },
    .focus = .{ .r = 0x8a, .g = 0xad, .b = 0xf4 },
    .lanes = .{
        .{ .r = 0x91, .g = 0xd7, .b = 0xe3 }, // lane 1
        .{ .r = 0xa6, .g = 0xda, .b = 0x95 }, // lane 2
        .{ .r = 0xee, .g = 0xd4, .b = 0x9f }, // lane 3
        .{ .r = 0xed, .g = 0x87, .b = 0x96 }, // lane 4
        .{ .r = 0xc6, .g = 0xa0, .b = 0xf6 }, // lane 5
        .{ .r = 0x8b, .g = 0xd5, .b = 0xca }, // lane 6
        .{ .r = 0xf5, .g = 0xa9, .b = 0x7f }, // lane 7
        .{ .r = 0xb7, .g = 0xbd, .b = 0xf8 }, // lane 8
        .{ .r = 0xf5, .g = 0xbd, .b = 0xe6 }, // lane 9
    },
    .hairline = .{ .r = 0x36, .g = 0x3a, .b = 0x4f },
    .chip_source_border = .{ .r = 0x58, .g = 0x68, .b = 0x91 },
    .chip_journal_border = .{ .r = 0x65, .g = 0x7d, .b = 0x6c },
    .chip_loss_border = .{ .r = 0x7f, .g = 0x59, .b = 0x6b },
    .control_pressed_border = .{ .r = 0x5c, .g = 0x6e, .b = 0x99 },
    .button_hover_border = .{ .r = 0x70, .g = 0x75, .b = 0x90 },
    .segment_loss_border = .{ .r = 0x88, .g = 0x5d, .b = 0x6f },
    .refuse_chip_border = .{ .r = 0x7c, .g = 0x57, .b = 0x6a },
    .theme_option_active_border = .{ .r = 0x64, .g = 0x79, .b = 0xaa },
    .ledger_loss_hover = .{ .r = 0x40, .g = 0x34, .b = 0x47 },
};

pub const mocha_palette: Palette = .{
    .bg = .{ .r = 0x11, .g = 0x11, .b = 0x1b },
    .panel = .{ .r = 0x1e, .g = 0x1e, .b = 0x2e },
    .raised = .{ .r = 0x31, .g = 0x32, .b = 0x44 },
    .raised2 = .{ .r = 0x45, .g = 0x47, .b = 0x5a },
    .field = .{ .r = 0x18, .g = 0x18, .b = 0x25 },
    .text = .{ .r = 0xcd, .g = 0xd6, .b = 0xf4 },
    .muted = .{ .r = 0xba, .g = 0xc2, .b = 0xde },
    .dim = .{ .r = 0xa6, .g = 0xad, .b = 0xc8 },
    .faint = .{ .r = 0x93, .g = 0x99, .b = 0xb2 },
    .line = .{ .r = 0x31, .g = 0x32, .b = 0x44 },
    .line_strong = .{ .r = 0x45, .g = 0x47, .b = 0x5a },
    .live = .{ .r = 0x89, .g = 0xb4, .b = 0xfa },
    .pass = .{ .r = 0xa6, .g = 0xe3, .b = 0xa1 },
    .skip = .{ .r = 0xf9, .g = 0xe2, .b = 0xaf },
    .refuse = .{ .r = 0xf3, .g = 0x8b, .b = 0xa8 },
    .pending = .{ .r = 0xa6, .g = 0xad, .b = 0xc8 },
    .vm = .{ .r = 0xcb, .g = 0xa6, .b = 0xf7 },
    .tint_live = .{ .r = 0x89, .g = 0xb4, .b = 0xfa, .a = 26 },
    .tint_refuse = .{ .r = 0xf3, .g = 0x8b, .b = 0xa8, .a = 23 },
    .tint_skip = .{ .r = 0xf9, .g = 0xe2, .b = 0xaf, .a = 23 },
    .tint_pass = .{ .r = 0xa6, .g = 0xe3, .b = 0xa1, .a = 20 },
    .lane_idle = .{ .r = 0x18, .g = 0x18, .b = 0x25 },
    .lane_grid = .{ .r = 0x31, .g = 0x32, .b = 0x44 },
    .focus = .{ .r = 0x89, .g = 0xb4, .b = 0xfa },
    .lanes = .{
        .{ .r = 0x89, .g = 0xdc, .b = 0xeb }, // lane 1
        .{ .r = 0xa6, .g = 0xe3, .b = 0xa1 }, // lane 2
        .{ .r = 0xf9, .g = 0xe2, .b = 0xaf }, // lane 3
        .{ .r = 0xf3, .g = 0x8b, .b = 0xa8 }, // lane 4
        .{ .r = 0xcb, .g = 0xa6, .b = 0xf7 }, // lane 5
        .{ .r = 0x94, .g = 0xe2, .b = 0xd5 }, // lane 6
        .{ .r = 0xfa, .g = 0xb3, .b = 0x87 }, // lane 7
        .{ .r = 0xb4, .g = 0xbe, .b = 0xfe }, // lane 8
        .{ .r = 0xf5, .g = 0xc2, .b = 0xe7 }, // lane 9
    },
    .hairline = .{ .r = 0x31, .g = 0x32, .b = 0x44 },
    .chip_source_border = .{ .r = 0x54, .g = 0x66, .b = 0x8d },
    .chip_journal_border = .{ .r = 0x62, .g = 0x7c, .b = 0x6b },
    .chip_loss_border = .{ .r = 0x7f, .g = 0x56, .b = 0x6c },
    .control_pressed_border = .{ .r = 0x59, .g = 0x6c, .b = 0x96 },
    .button_hover_border = .{ .r = 0x6e, .g = 0x72, .b = 0x88 },
    .segment_loss_border = .{ .r = 0x88, .g = 0x5a, .b = 0x71 },
    .refuse_chip_border = .{ .r = 0x7b, .g = 0x54, .b = 0x6a },
    .theme_option_active_border = .{ .r = 0x61, .g = 0x7a, .b = 0xa8 },
    .ledger_loss_hover = .{ .r = 0x3c, .g = 0x2d, .b = 0x3f },
};

pub const presets = [_]Preset{
    .{ .id = "dark", .name = "Graphite", .kind = "dark", .group = "core", .theme = graphite_palette },
    .{ .id = "paper", .name = "Paper", .kind = "light", .group = "core", .theme = paper_palette },
    .{ .id = "latte", .name = "Catppuccin Latte", .kind = "light", .group = "flavor", .theme = latte_palette },
    .{ .id = "frappe", .name = "Catppuccin Frappe", .kind = "dark", .group = "flavor", .theme = frappe_palette },
    .{ .id = "macchiato", .name = "Catppuccin Macchiato", .kind = "dark", .group = "flavor", .theme = macchiato_palette },
    .{ .id = "mocha", .name = "Catppuccin Mocha", .kind = "dark", .group = "flavor", .theme = mocha_palette },
};

pub const default = graphite_palette;

test "all six palettes are present and distinct" {
    try @import("std").testing.expectEqual(@as(usize, 6), presets.len);
    try @import("std").testing.expect(graphite_palette.bg.r != paper_palette.bg.r);
    try @import("std").testing.expect(graphite_palette.lanes[0].r == 0x58);
    try @import("std").testing.expect(graphite_palette.chip_source_border.r == 0x3a);
}
