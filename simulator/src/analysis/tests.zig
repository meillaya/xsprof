const std = @import("std");
const analysis = @import("root.zig");

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .unlimited);
}

test "analysis module audit stays export-only" {
    const allocator = std.testing.allocator;
    const files = [_][]const u8{
        "src/analysis/args.zig",
        "src/analysis/derive.zig",
        "src/analysis/main.zig",
        "src/analysis/model.zig",
        "src/analysis/render_markdown.zig",
        "src/analysis/render_svg.zig",
        "src/analysis/root.zig",
    };
    const forbidden = [_][]const u8{
        "../sim/",
        "../root.zig",
        "@import(\"zig_scheduler\")",
        "SimulationResult",
        "ScenarioOwned",
    };

    for (files) |path| {
        const source = try readFileAlloc(allocator, path);
        defer allocator.free(source);

        for (forbidden) |needle| {
            try std.testing.expect(std.mem.indexOf(u8, source, needle) == null);
        }
    }
}
