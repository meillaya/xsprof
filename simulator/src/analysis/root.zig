const std = @import("std");

pub const args = @import("args.zig");
pub const derive = @import("derive.zig");
pub const model = @import("model.zig");
pub const Options = args.Options;
pub const OutputFormat = args.OutputFormat;
pub const parseArgs = args.parseArgs;

pub fn analyzeBytes(allocator: std.mem.Allocator, bytes: []const u8, output_format: OutputFormat) ![]u8 {
    var parsed = try model.parseReport(allocator, bytes);
    defer parsed.deinit();

    var summary = try derive.derive(allocator, &parsed.value);
    defer summary.deinit();

    return switch (output_format) {
        .markdown => @import("render_markdown.zig").render(allocator, &parsed.value, &summary),
        .svg => @import("render_svg.zig").render(allocator, &parsed.value, &summary),
    };
}

pub fn analyzeFile(allocator: std.mem.Allocator, input_path: []const u8, output_format: OutputFormat) ![]u8 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), input_path, allocator, .unlimited);
    defer allocator.free(bytes);
    return try analyzeBytes(allocator, bytes, output_format);
}

test {
    _ = @import("args.zig");
    _ = @import("tests.zig");
}
