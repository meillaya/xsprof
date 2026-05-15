const std = @import("std");

const production_files = [_][]const u8{
    "build.zig",
    "src/quality/root.zig",
    "src/perf/root.zig",
    "src/semantics/root.zig",
    "src/dashboard/root.zig",
    "src/tui/args.zig",
    "src/tui/render.zig",
    "src/tui/root.zig",
    "src/tui/main.zig",
    "src/observability/root.zig",
    "src/observability/comparison.zig",
    "src/report_pipeline/root.zig",
    "src/report_pipeline/tests.zig",
};

fn isDigit(byte: u8) bool {
    return byte >= '0' and byte <= '9';
}

fn containsNumberedRoadmapLabel(bytes: []const u8) bool {
    if (bytes.len < 2) return false;
    var i: usize = 0;
    while (i + 1 < bytes.len) : (i += 1) {
        if ((bytes[i] == 'M' or bytes[i] == 'm') and isDigit(bytes[i + 1])) return true;
    }
    return false;
}

fn containsLegacyFlag(bytes: []const u8) bool {
    if (bytes.len < 4) return false;
    var i: usize = 0;
    while (i + 3 < bytes.len) : (i += 1) {
        if (bytes[i] == '-' and bytes[i + 1] == '-' and bytes[i + 2] == 'm' and isDigit(bytes[i + 3])) return true;
    }
    return false;
}

fn containsRoadmapVocabulary(bytes: []const u8) bool {
    return std.mem.indexOf(u8, bytes, "mile" ++ "stone") != null or
        std.mem.indexOf(u8, bytes, "Mile" ++ "stone") != null;
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .unlimited);
}

test "production terminal surfaces use domain labels" {
    const allocator = std.testing.allocator;

    for (production_files) |path| {
        const contents = try readFileAlloc(allocator, path);
        defer allocator.free(contents);

        const has_label = containsNumberedRoadmapLabel(contents);
        const has_flag = containsLegacyFlag(contents);
        const has_vocab = containsRoadmapVocabulary(contents);
        if (has_label or has_flag or has_vocab) {
            std.debug.print("production label leak in {s}: numbered={} flag={} vocab={}\n", .{ path, has_label, has_flag, has_vocab });
        }
        try std.testing.expect(!has_label);
        try std.testing.expect(!has_flag);
        try std.testing.expect(!has_vocab);
    }
}
