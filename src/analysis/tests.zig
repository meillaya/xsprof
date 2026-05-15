const std = @import("std");
const analysis = @import("root.zig");

const export_fixture_path = "docs/examples/exports/multicore-contention-fcfs.report.json";
const markdown_golden_path = "docs/examples/analysis/multicore-contention-fcfs.md";
const svg_golden_path = "docs/examples/analysis/multicore-contention-fcfs.svg";

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .unlimited);
}

test "markdown analysis stays reproducible for committed export fixture" {
    const allocator = std.testing.allocator;

    const expected = try readFileAlloc(allocator, markdown_golden_path);
    defer allocator.free(expected);

    const actual = try analysis.analyzeFile(allocator, export_fixture_path, .markdown);
    defer allocator.free(actual);

    try std.testing.expectEqualStrings(expected, actual);
}

test "svg analysis stays reproducible for committed export fixture" {
    const allocator = std.testing.allocator;

    const expected = try readFileAlloc(allocator, svg_golden_path);
    defer allocator.free(expected);

    const actual = try analysis.analyzeFile(allocator, export_fixture_path, .svg);
    defer allocator.free(actual);

    try std.testing.expectEqualStrings(expected, actual);
}

test "analysis rejects unsupported export versions" {
    const allocator = std.testing.allocator;
    const baseline = try readFileAlloc(allocator, export_fixture_path);
    defer allocator.free(baseline);

    const unsupported = try std.mem.replaceOwned(u8, allocator, baseline, "\"version\":1", "\"version\":2");
    defer allocator.free(unsupported);

    try std.testing.expectError(error.UnsupportedVersion, analysis.analyzeBytes(allocator, unsupported, .markdown));
}

test "analysis parser tolerates additive version-1 fields" {
    const allocator = std.testing.allocator;
    const baseline = try readFileAlloc(allocator, export_fixture_path);
    defer allocator.free(baseline);

    const extension = "\"version\":1,\"analysis_extension\":{\"kind\":\"additive\"}";
    const extended = try std.mem.replaceOwned(u8, allocator, baseline, "\"version\":1", extension);
    defer allocator.free(extended);

    const rendered = try analysis.analyzeBytes(allocator, extended, .markdown);
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "# zig-scheduler analysis report") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "multicore-contention") != null);
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

test "analysis docs expose export to analysis workflow" {
    const allocator = std.testing.allocator;
    const readme = try readFileAlloc(allocator, "README.md");
    defer allocator.free(readme);
    const workflow_doc = try readFileAlloc(allocator, "docs/analysis-workflow.md");
    defer allocator.free(workflow_doc);

    try std.testing.expect(std.mem.indexOf(u8, readme, "zig build analyze -- --input docs/examples/exports/multicore-contention-fcfs.report.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, workflow_doc, "docs/examples/analysis/multicore-contention-fcfs.svg") != null);
    try std.testing.expect(std.mem.indexOf(u8, workflow_doc, "unsupported export version") != null);
}
