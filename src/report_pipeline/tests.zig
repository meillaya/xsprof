const std = @import("std");
const report_pipeline = @import("root.zig");

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .unlimited);
}

test "report pipeline reproduces committed artifacts" {
    const allocator = std.testing.allocator;

    for (report_pipeline.artifacts) |artifact| {
        const expected = try readFileAlloc(allocator, artifact.path);
        defer allocator.free(expected);

        const actual = try report_pipeline.renderArtifact(allocator, artifact.kind);
        defer allocator.free(actual);

        try std.testing.expectEqualStrings(expected, actual);
    }
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

test "M16 docs expose the report regeneration path" {
    const allocator = std.testing.allocator;
    const readme = try readFileAlloc(allocator, "README.md");
    defer allocator.free(readme);
    const workflow = try readFileAlloc(allocator, "docs/m16-report-pipeline.md");
    defer allocator.free(workflow);
    const phase1 = try readFileAlloc(allocator, "docs/phase1-simulator.md");
    defer allocator.free(phase1);
    const m4 = try readFileAlloc(allocator, "docs/m4-analysis-workflow.md");
    defer allocator.free(m4);
    const m45 = try readFileAlloc(allocator, "docs/m45-benchmark-workflow.md");
    defer allocator.free(m45);
    const architecture = try readFileAlloc(allocator, "docs/project-architecture-and-status.md");
    defer allocator.free(architecture);
    const tui_render = try readFileAlloc(allocator, "src/tui/render.zig");
    defer allocator.free(tui_render);

    try std.testing.expect(std.mem.indexOf(u8, readme, "zig build reports") != null);
    try std.testing.expect(std.mem.indexOf(u8, workflow, "zig build reports") != null);
    try std.testing.expect(std.mem.indexOf(u8, phase1, "zig build reports") != null);
    try std.testing.expect(std.mem.indexOf(u8, m4, "zig build reports") != null);
    try std.testing.expect(std.mem.indexOf(u8, m45, "zig build reports") != null);
    try std.testing.expect(std.mem.indexOf(u8, architecture, "zig build reports") != null);
    try std.testing.expect(std.mem.indexOf(u8, workflow, "docs/labs/reproducible-report-pack.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, workflow, "zig build reports -- --output-dir zig-out/m16-smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, workflow, "zig build reports -- --check") != null);
    try std.testing.expect(std.mem.indexOf(u8, tui_render, "zig build sim -- --scenario-file <path> --format json | zig-out/bin/zig-scheduler --stdin --snapshot") != null);
}
