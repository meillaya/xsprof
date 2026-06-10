const std = @import("std");
const report_pipeline = @import("root.zig");

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .unlimited);
}

test "report pipeline writes the full artifact pack into a temp directory" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try report_pipeline.writeAllToDir(allocator, tmp.dir);

    for (report_pipeline.artifacts) |artifact| {
        const expected = try report_pipeline.renderArtifact(allocator, artifact.kind);
        defer allocator.free(expected);

        const actual = try tmp.dir.readFileAlloc(std.Io.Threaded.global_single_threaded.io(), artifact.path, allocator, .unlimited);
        defer allocator.free(actual);

        try std.testing.expectEqualStrings(expected, actual);
    }
}

test "report pipeline renders deterministically" {
    const allocator = std.testing.allocator;

    for (report_pipeline.artifacts) |artifact| {
        const first = try report_pipeline.renderArtifact(allocator, artifact.kind);
        defer allocator.free(first);
        const second = try report_pipeline.renderArtifact(allocator, artifact.kind);
        defer allocator.free(second);
        try std.testing.expectEqualStrings(first, second);
    }
}
