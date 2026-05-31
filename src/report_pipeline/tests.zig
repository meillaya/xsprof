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

test "report docs expose the regeneration path" {
    const allocator = std.testing.allocator;
    const readme = try readFileAlloc(allocator, "README.md");
    defer allocator.free(readme);
    const workflow = try readFileAlloc(allocator, "docs/report-pipeline.md");
    defer allocator.free(workflow);
    const simulator_baseline = try readFileAlloc(allocator, "docs/simulator-semantics.md");
    defer allocator.free(simulator_baseline);
    const analysis_doc = try readFileAlloc(allocator, "docs/analysis-workflow.md");
    defer allocator.free(analysis_doc);
    const benchmark_doc = try readFileAlloc(allocator, "docs/benchmark-workflow.md");
    defer allocator.free(benchmark_doc);
    const architecture = try readFileAlloc(allocator, "docs/project-architecture-and-status.md");
    defer allocator.free(architecture);
    const tui_render = try readFileAlloc(allocator, "src/tui/render.zig");
    defer allocator.free(tui_render);

    try std.testing.expect(std.mem.indexOf(u8, readme, "zig build reports") != null);
    try std.testing.expect(std.mem.indexOf(u8, workflow, "zig build reports") != null);
    try std.testing.expect(std.mem.indexOf(u8, simulator_baseline, "zig build reports") != null);
    try std.testing.expect(std.mem.indexOf(u8, analysis_doc, "zig build reports") != null);
    try std.testing.expect(std.mem.indexOf(u8, benchmark_doc, "zig build reports") != null);
    try std.testing.expect(std.mem.indexOf(u8, architecture, "zig build reports") != null);
    try std.testing.expect(std.mem.indexOf(u8, workflow, "docs/labs/reproducible-report-pack.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, workflow, "zig build reports -- --output-dir zig-out/report-smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, workflow, "zig build reports -- --check") != null);
    try std.testing.expect(std.mem.indexOf(u8, tui_render, "zig build sim -- --scenario-file <path> --format json | zig-out/bin/zig-scheduler --stdin --snapshot") != null);
}
