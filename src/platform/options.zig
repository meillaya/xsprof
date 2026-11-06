//! Shared native-window options passed from the CLI to the macOS/Linux
//! surfaces. Platform-neutral: no OS, window, or profiler imports, so it also
//! compiles for the wasm/web build if a surface ever needs it.

const std = @import("std");

pub const Size = struct {
    width: u32,
    height: u32,
};

pub const min_width: u32 = 640;
pub const min_height: u32 = 480;
pub const max_width: u32 = 16384;
pub const max_height: u32 = 16384;
pub const default_width: u32 = 1280;
pub const default_height: u32 = 720;

pub const Options = struct {
    replay: ?[]const u8 = null,
    demo_model: ?[]const u8 = null,
    recorder_dir: ?[]const u8 = null,
    screen: u32 = 0,
    theme_index: usize = 0,
    smoke: bool = false,
    width: u32 = default_width,
    height: u32 = default_height,
    /// Smoke-only: replay one resize through the native resize path.
    resize: ?Size = null,
    /// macOS: install the NSAccessibility bridge. Linux exports the tree as
    /// canonical JSON and reports DEGRADED (no AT-SPI2 bridge in this task).
    a11y: bool = false,
    /// Live capture / recorder tail. Parsed here; controller wiring is exposed
    /// through `src/app/design/live.zig` for the app shell.
    live: bool = false,
    duration_ms: u32 = 1000,
    preset: []const u8 = "scheduler",
    follow_recorder: ?[]const u8 = null,

    pub fn size(self: Options) Size {
        return clampSize(.{ .width = self.width, .height = self.height });
    }
};

pub fn clampSize(size: Size) Size {
    return .{
        .width = std.math.clamp(size.width, min_width, max_width),
        .height = std.math.clamp(size.height, min_height, max_height),
    };
}

/// Resize math shared by both surfaces: content never drops below the minimum
/// (the window manager normally enforces it; a live drag can still outrun it).
pub fn fitBounds(bounds: Size, minimum: Size) Size {
    const floor = clampSize(minimum);
    return clampSize(.{
        .width = @max(bounds.width, floor.width),
        .height = @max(bounds.height, floor.height),
    });
}

/// Parses "WxH" (e.g. "900x600"). Returns null for malformed/zero sizes.
pub fn parseSize(text: []const u8) ?Size {
    const x_at = std.mem.indexOfScalar(u8, text, 'x') orelse
        std.mem.indexOfScalar(u8, text, 'X') orelse return null;
    const width_text = std.mem.trim(u8, text[0..x_at], " \t");
    const height_text = std.mem.trim(u8, text[x_at + 1 ..], " \t");
    if (width_text.len == 0 or height_text.len == 0) return null;
    const width = std.fmt.parseInt(u32, width_text, 10) catch return null;
    const height = std.fmt.parseInt(u32, height_text, 10) catch return null;
    if (width == 0 or height == 0) return null;
    return .{ .width = width, .height = height };
}

test "native options clamp, fit, and parse sizes" {
    try std.testing.expectEqual(@as(u32, min_width), clampSize(.{ .width = 100, .height = 100 }).width);
    try std.testing.expectEqual(@as(u32, min_height), clampSize(.{ .width = 100, .height = 100 }).height);
    try std.testing.expectEqual(@as(u32, max_width), clampSize(.{ .width = 999_999, .height = 999_999 }).width);
    const fitted = fitBounds(.{ .width = 200, .height = 600 }, .{ .width = 640, .height = 480 });
    try std.testing.expectEqual(@as(u32, 640), fitted.width);
    try std.testing.expectEqual(@as(u32, 600), fitted.height);
    try std.testing.expectEqual(@as(?Size, Size{ .width = 900, .height = 600 }), parseSize("900x600"));
    try std.testing.expectEqual(@as(?Size, null), parseSize("900"));
    try std.testing.expectEqual(@as(?Size, null), parseSize("0x600"));
    const tiny = Options{ .width = 100, .height = 100 };
    try std.testing.expectEqual(@as(?Size, Size{ .width = 640, .height = 480 }), @as(?Size, tiny.size()));
}
