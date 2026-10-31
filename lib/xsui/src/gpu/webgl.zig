//! Zig side of the WebGL2 ABI. The JS shim owns the GL context; this file
//! pins the instance layout, attribute locations, atlas format, and served
//! shader paths so a layout change fails at compile time instead of producing
//! silently shifted pixels.
//!
//! The Metal backend pads each instance row to 80 bytes to satisfy MSL's
//! 16-byte alignment; the shared Zig/WebGL2 stride remains 72 bytes.

const std = @import("std");
const draw = @import("../draw.zig");

pub const Attribute = struct {
    location: u8,
    components: u8,
    offset: usize,
    integer: bool,
};

pub const vertex_count: u8 = 4;
pub const topology = "triangle-strip";

pub const instance_stride_bytes: usize = @sizeOf(draw.Instance);
pub const instance_stride_floats: usize = instance_stride_bytes / @sizeOf(f32);

pub const attributes = [_]Attribute{
    .{ .location = 0, .components = 4, .offset = 0, .integer = false },
    .{ .location = 1, .components = 4, .offset = 16, .integer = false },
    .{ .location = 2, .components = 4, .offset = 32, .integer = false },
    .{ .location = 3, .components = 1, .offset = 48, .integer = true },
    .{ .location = 4, .components = 1, .offset = 52, .integer = true },
    .{ .location = 5, .components = 1, .offset = 56, .integer = false },
    .{ .location = 6, .components = 1, .offset = 60, .integer = false },
    .{ .location = 7, .components = 1, .offset = 64, .integer = true },
};

pub const atlas_format = "r8unorm";
pub const atlas_width = draw.atlas_width;
pub const atlas_height = draw.atlas_height;
pub const shader_vertex_path = "/shaders/ui.vert.glsl";
pub const shader_fragment_path = "/shaders/ui.frag.glsl";

comptime {
    if (@sizeOf(draw.Instance) != 72) {
        @compileError("draw.Instance changed; update web/gl.js attribute stride and the ABI test");
    }
    if (@offsetOf(draw.Instance, "rect") != 0 or
        @offsetOf(draw.Instance, "clip") != 16 or
        @offsetOf(draw.Instance, "uv") != 32 or
        @offsetOf(draw.Instance, "color") != 48 or
        @offsetOf(draw.Instance, "border_color") != 52 or
        @offsetOf(draw.Instance, "radius") != 56 or
        @offsetOf(draw.Instance, "border_width") != 60 or
        @offsetOf(draw.Instance, "mode") != 64 or
        @offsetOf(draw.Instance, "pad") != 68)
    {
        @compileError("draw.Instance field offsets changed; update the WebGL2 attribute table");
    }
    if (@sizeOf(draw.Instance) / @sizeOf(f32) != 18) {
        @compileError("draw.Instance must be 18 f32 lanes for the web bridge");
    }
}

test "webgl instance ABI stays stable" {
    try std.testing.expectEqual(@as(usize, 72), instance_stride_bytes);
    try std.testing.expectEqual(@as(usize, 18), instance_stride_floats);
    try std.testing.expectEqual(@as(usize, 8), attributes.len);
    try std.testing.expectEqual(@as(usize, 0), attributes[0].offset);
    try std.testing.expectEqual(@as(usize, 64), attributes[7].offset);
    try std.testing.expectEqual(atlas_width, atlas_height);
    try std.testing.expect(atlas_width >= 256);
}
