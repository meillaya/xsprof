//! GENERATED from design/ui-spec.json by tools/gen_ui_spec.py. Do not edit.
//! The formal contract every CPU/Metal/GL/WebGL2 surface consumes.

const std = @import("std");

pub const schema = "xsprof/ui-spec/v1";
pub const version: u32 = 1;
pub const prototype_sha256 = "0823328b3261b89ce2d8c2af53ebc61adfedd49f19706239e437b7fdb6a3de62";
pub const reference_width: f32 = 1440.0;
pub const reference_height: f32 = 900.0;
pub const native_width: f32 = 1280.0;
pub const native_height: f32 = 720.0;
pub const shell_top: f32 = 52.0;
pub const shell_bottom: f32 = 30.0;
pub const rail_width: f32 = 92.0;
pub const rail_item_h: f32 = 63.75;
pub const stage_pad_top: f32 = 20.0;
pub const stage_pad_x: f32 = 24.0;
pub const stage_pad_bottom: f32 = 22.0;
pub const cross_mae_max: f32 = 2.5;
pub const cross_over24_max: f32 = 3.0;
pub const text_atlas_sha256: [32]u8 = .{
    0x84, 0x00, 0x8d, 0xa0, 0xe6, 0x3e, 0x67, 0xb1,
    0x51, 0x6d, 0xe4, 0x4a, 0xf3, 0xd4, 0xbd, 0x49,
    0x8d, 0xf5, 0x71, 0x49, 0xa2, 0xe2, 0xe1, 0xc5,
    0x37, 0xa1, 0xfb, 0x7d, 0x3f, 0x4a, 0x02, 0xa5,
};
pub const Breakpoint = struct { max_width: u32, id: []const u8 };
pub const breakpoints = [_]Breakpoint{
    .{ .max_width = 1048576, .id = "wide" },
    .{ .max_width = 1320, .id = "compact" },
    .{ .max_width = 1140, .id = "stacked" },
    .{ .max_width = 1024, .id = "bottom-rail" },
    .{ .max_width = 780, .id = "compact-topbar" },
    .{ .max_width = 420, .id = "phone" },
};

pub fn modeForWidth(width: f32) []const u8 {
    for (breakpoints) |bp| {
        if (width <= @as(f32, @floatFromInt(bp.max_width))) return bp.id;
    }
    return "wide";
}

test "formal spec atlas hash is embedded" {
    const xsui = @import("xsui");
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(xsui.text_atlas, &digest, .{});
    try std.testing.expectEqualSlices(u8, &text_atlas_sha256, &digest);
}
