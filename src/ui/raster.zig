//! CPU reference rasterizer for the flat UI draw list. It is intentionally the
//! same input as the GPU backends; snapshots and parity tests use it.

const std = @import("std");
const draw = @import("draw.zig");

pub fn render(
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    list: *const draw.DrawList,
    background: draw.Color,
) ![]u8 {
    const w: usize = width;
    const h: usize = height;
    const pixels = try allocator.alloc(u8, w * h * 4);
    var i: usize = 0;
    while (i < w * h) : (i += 1) {
        pixels[i * 4] = background.r;
        pixels[i * 4 + 1] = background.g;
        pixels[i * 4 + 2] = background.b;
        pixels[i * 4 + 3] = 255;
    }
    for (list.items.items) |instance| {
        switch (instance.mode) {
            @backingInt(draw.Mode.glyph) => blitGlyph(pixels, w, h, list.atlas, instance),
            else => blitRect(pixels, w, h, instance),
        }
    }
    return pixels;
}

fn clipBounds(instance: draw.Instance, w: usize, h: usize) struct { x0: usize, y0: usize, x1: usize, y1: usize } {
    const clip = instance.clip;
    const x0: usize = @intFromFloat(@max(0, @floor(clip[0])));
    const y0: usize = @intFromFloat(@max(0, @floor(clip[1])));
    const x1: usize = @intFromFloat(@min(@as(f32, @floatFromInt(w)), @ceil(clip[2])));
    const y1: usize = @intFromFloat(@min(@as(f32, @floatFromInt(h)), @ceil(clip[3])));
    return .{ .x0 = @min(x0, w), .y0 = @min(y0, h), .x1 = @min(x1, w), .y1 = @min(y1, h) };
}

fn blend(pixels: []u8, w: usize, x: usize, y: usize, color: draw.Color, alpha: u8) void {
    if (alpha == 0) return;
    const index = (y * w + x) * 4;
    const sa: u32 = alpha;
    const ia: u32 = 255 - sa;
    pixels[index] = @intCast((@as(u32, color.r) * sa + @as(u32, pixels[index]) * ia) / 255);
    pixels[index + 1] = @intCast((@as(u32, color.g) * sa + @as(u32, pixels[index + 1]) * ia) / 255);
    pixels[index + 2] = @intCast((@as(u32, color.b) * sa + @as(u32, pixels[index + 2]) * ia) / 255);
    pixels[index + 3] = 255;
}

fn blitRect(pixels: []u8, w: usize, h: usize, instance: draw.Instance) void {
    const rect = instance.rect;
    if (rect[2] <= 0 or rect[3] <= 0) return;
    const clip = clipBounds(instance, w, h);
    const bx0: usize = @intFromFloat(@max(0, @floor(rect[0])));
    const by0: usize = @intFromFloat(@max(0, @floor(rect[1])));
    const bx1: usize = @intFromFloat(@min(@as(f32, @floatFromInt(w)), @ceil(rect[0] + rect[2])));
    const by1: usize = @intFromFloat(@min(@as(f32, @floatFromInt(h)), @ceil(rect[1] + rect[3])));
    const fill = draw.Color.fromU32(instance.color);
    const border = draw.Color.fromU32(instance.border_color);
    const half_w = rect[2] * 0.5;
    const half_h = rect[3] * 0.5;
    const radius = @min(instance.radius, @min(half_w, half_h));
    const cx = rect[0] + half_w;
    const cy = rect[1] + half_h;
    var y = @max(by0, clip.y0);
    while (y < @min(by1, clip.y1)) : (y += 1) {
        var x = @max(bx0, clip.x0);
        while (x < @min(bx1, clip.x1)) : (x += 1) {
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const py = @as(f32, @floatFromInt(y)) + 0.5;
            const dx = @abs(px - cx) - (half_w - radius);
            const dy = @abs(py - cy) - (half_h - radius);
            const outside = @sqrt(@max(dx, 0) * @max(dx, 0) + @max(dy, 0) * @max(dy, 0));
            const inside = @min(@max(dx, dy), 0);
            const dist = outside + inside - radius;
            const coverage = std.math.clamp(0.5 - dist, 0, 1);
            if (coverage <= 0) continue;
            if (instance.border_width > 0 and border.a != 0) {
                const inner = std.math.clamp(0.5 - (dist + instance.border_width), 0, 1);
                const ring = coverage - inner;
                if (ring > 0) {
                    const alpha = @as(u8, @intFromFloat(ring * @as(f32, @floatFromInt(border.a))));
                    blend(pixels, w, x, y, border, alpha);
                }
                if (inner > 0 and fill.a != 0) {
                    const alpha = @as(u8, @intFromFloat(inner * @as(f32, @floatFromInt(fill.a))));
                    blend(pixels, w, x, y, fill, alpha);
                }
            } else if (fill.a != 0) {
                const alpha = @as(u8, @intFromFloat(coverage * @as(f32, @floatFromInt(fill.a))));
                blend(pixels, w, x, y, fill, alpha);
            }
        }
    }
}

fn blitGlyph(pixels: []u8, w: usize, h: usize, atlas: *const draw.Atlas, instance: draw.Instance) void {
    const rect = instance.rect;
    if (rect[2] <= 0 or rect[3] <= 0) return;
    const clip = clipBounds(instance, w, h);
    const color = draw.Color.fromU32(instance.color);
    if (color.a == 0) return;
    const bx0: usize = @intFromFloat(@max(0, @floor(rect[0])));
    const by0: usize = @intFromFloat(@max(0, @floor(rect[1])));
    const bx1: usize = @intFromFloat(@min(@as(f32, @floatFromInt(w)), @ceil(rect[0] + rect[2])));
    const by1: usize = @intFromFloat(@min(@as(f32, @floatFromInt(h)), @ceil(rect[1] + rect[3])));
    const tw = @as(f32, @floatFromInt(atlas.width));
    const th = @as(f32, @floatFromInt(atlas.height));
    var y = @max(by0, clip.y0);
    while (y < @min(by1, clip.y1)) : (y += 1) {
        var x = @max(bx0, clip.x0);
        while (x < @min(bx1, clip.x1)) : (x += 1) {
            const u = (@as(f32, @floatFromInt(x)) + 0.5 - rect[0]) / rect[2];
            const v = (@as(f32, @floatFromInt(y)) + 0.5 - rect[1]) / rect[3];
            const uu = instance.uv[0] + u * (instance.uv[2] - instance.uv[0]);
            const vv = instance.uv[1] + v * (instance.uv[3] - instance.uv[1]);
            const tx: usize = @intFromFloat(@min(tw - 1, @max(0, @floor(uu * tw))));
            const ty: usize = @intFromFloat(@min(th - 1, @max(0, @floor(vv * th))));
            const coverage = atlas.pixels[ty * atlas.width + tx];
            if (coverage == 0) continue;
            const alpha = @as(u8, @intCast((@as(u32, coverage) * @as(u32, color.a)) / 255));
            blend(pixels, w, x, y, color, alpha);
        }
    }
}

test "rasterizes a red rect on black" {
    var atlas = try draw.Atlas.init(std.testing.allocator);
    defer atlas.deinit();
    var list = draw.DrawList.init(std.testing.allocator, &atlas);
    defer list.deinit();
    try list.rect(1, 1, 2, 2, .{ .r = 255, .g = 0, .b = 0 }, .{ 0, 0, 4, 4 });
    const pixels = try render(std.testing.allocator, 4, 4, &list, .{ .r = 0, .g = 0, .b = 0 });
    defer std.testing.allocator.free(pixels);
    try std.testing.expectEqual(@as(u8, 255), pixels[(1 * 4 + 1) * 4]);
    try std.testing.expectEqual(@as(u8, 0), pixels[(0 * 4 + 0) * 4]);
    try std.testing.expectEqual(@as(u8, 0), pixels[(3 * 4 + 3) * 4]);
}

test "clip excludes pixels" {
    var atlas = try draw.Atlas.init(std.testing.allocator);
    defer atlas.deinit();
    var list = draw.DrawList.init(std.testing.allocator, &atlas);
    defer list.deinit();
    try list.rect(0, 0, 4, 4, .{ .r = 255, .g = 255, .b = 255 }, .{ 0, 0, 2, 2 });
    const pixels = try render(std.testing.allocator, 4, 4, &list, .{ .r = 0, .g = 0, .b = 0 });
    defer std.testing.allocator.free(pixels);
    try std.testing.expectEqual(@as(u8, 255), pixels[(1 * 4 + 1) * 4]);
    try std.testing.expectEqual(@as(u8, 0), pixels[(3 * 4 + 3) * 4]);
}
