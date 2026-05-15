const std = @import("std");
const list_writer = @import("list_writer");
const analysis = @import("analysis_root");
const bench = @import("bench_root");
const scheduler = @import("zig_scheduler_internal");

pub const ArtifactKind = enum {
    example_export_json,
    example_analysis_markdown,
    example_analysis_svg,
    benchmark_markdown,
    benchmark_json,
    notebook_markdown,
};

pub const ArtifactSpec = struct {
    kind: ArtifactKind,
    path: []const u8,
};

const analysis_case = struct {
    scenario_path: []const u8,
    policy: scheduler.PolicyKind,
    export_path: []const u8,
    markdown_path: []const u8,
    svg_path: []const u8,
}{
    .scenario_path = "scenarios/basic/multicore-contention.zon",
    .policy = .fcfs,
    .export_path = "docs/examples/exports/multicore-contention-fcfs.report.json",
    .markdown_path = "docs/examples/analysis/multicore-contention-fcfs.md",
    .svg_path = "docs/examples/analysis/multicore-contention-fcfs.svg",
};

const benchmark_artifacts = struct {
    markdown_path: []const u8,
    json_path: []const u8,
}{
    .markdown_path = "docs/benchmarks/baselines.md",
    .json_path = "docs/benchmarks/baselines.json",
};

const notebook_path = "docs/labs/reproducible-report-pack.md";

pub const artifacts = [_]ArtifactSpec{
    .{ .kind = .example_export_json, .path = analysis_case.export_path },
    .{ .kind = .example_analysis_markdown, .path = analysis_case.markdown_path },
    .{ .kind = .example_analysis_svg, .path = analysis_case.svg_path },
    .{ .kind = .benchmark_markdown, .path = benchmark_artifacts.markdown_path },
    .{ .kind = .benchmark_json, .path = benchmark_artifacts.json_path },
    .{ .kind = .notebook_markdown, .path = notebook_path },
};

pub fn writeAll(allocator: std.mem.Allocator) !void {
    return writeAllToDir(allocator, std.Io.Dir.cwd());
}

pub fn writeAllToPath(allocator: std.mem.Allocator, path: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), path);
    var dir = try std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), path, .{});
    defer dir.close(std.Io.Threaded.global_single_threaded.io());
    try writeAllToDir(allocator, dir);
}

pub fn writeAllToDir(allocator: std.mem.Allocator, dir: std.Io.Dir) !void {
    for (artifacts) |artifact| {
        const rendered = try renderArtifact(allocator, artifact.kind);
        defer allocator.free(rendered);
        try writeFile(dir, artifact.path, rendered);
    }
}

pub fn checkAll(allocator: std.mem.Allocator) !bool {
    return checkAllInDir(allocator, std.Io.Dir.cwd());
}

pub fn checkAllInPath(allocator: std.mem.Allocator, path: []const u8) !bool {
    var dir = try std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), path, .{});
    defer dir.close(std.Io.Threaded.global_single_threaded.io());
    return checkAllInDir(allocator, dir);
}

pub fn checkAllInDir(allocator: std.mem.Allocator, dir: std.Io.Dir) !bool {
    for (artifacts) |artifact| {
        const expected = renderArtifact(allocator, artifact.kind) catch |err| {
            std.debug.print("report pipeline failed to render {s}: {s}\n", .{ artifact.path, @errorName(err) });
            return err;
        };
        defer allocator.free(expected);

        const actual = dir.readFileAlloc(std.Io.Threaded.global_single_threaded.io(), artifact.path, allocator, .unlimited) catch |err| {
            std.debug.print("report pipeline drift: missing artifact {s} ({s})\n", .{ artifact.path, @errorName(err) });
            return false;
        };
        defer allocator.free(actual);

        if (!std.mem.eql(u8, expected, actual)) {
            std.debug.print("report pipeline drift: {s}\n", .{artifact.path});
            return false;
        }
    }

    return true;
}

pub fn renderArtifact(allocator: std.mem.Allocator, kind: ArtifactKind) ![]u8 {
    return switch (kind) {
        .example_export_json => renderExampleExport(allocator),
        .example_analysis_markdown => renderExampleAnalysis(allocator, .markdown),
        .example_analysis_svg => renderExampleAnalysis(allocator, .svg),
        .benchmark_markdown => bench.render(allocator, .markdown),
        .benchmark_json => bench.render(allocator, .json),
        .notebook_markdown => renderNotebook(allocator),
    };
}

fn renderExampleExport(allocator: std.mem.Allocator) ![]u8 {
    var scenario = try scheduler.loadScenarioFile(allocator, analysis_case.scenario_path);
    defer scenario.deinit();

    var result = try scheduler.simulate(allocator, &scenario, analysis_case.policy);
    defer result.deinit();

    const source: scheduler.cli.SourceInfo = .{
        .kind = .file,
        .value = analysis_case.scenario_path,
    };
    const report = scheduler.cli.SimulationReport.init(source, &scenario, &result);

    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(allocator);
    var writer = list_writer.writer(&buffer, allocator);
    try scheduler.cli.writeJsonReport(&writer, report);
    return try buffer.toOwnedSlice(allocator);
}

fn renderExampleAnalysis(allocator: std.mem.Allocator, output_format: analysis.OutputFormat) ![]u8 {
    const export_bytes = try renderExampleExport(allocator);
    defer allocator.free(export_bytes);
    return try analysis.analyzeBytes(allocator, export_bytes, output_format);
}

fn renderNotebook(allocator: std.mem.Allocator) ![]u8 {
    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(allocator);
    var writer = list_writer.writer(&buffer, allocator);

    try writer.writeAll("# zig-scheduler reproducible report pack\n\n");
    try writer.writeAll("> Generated by `zig build reports`. Do not hand-edit this file.\n\n");
    try writer.writeAll("This notebook indexes the curated simulator-local artifacts that the report pipeline regenerates from committed fixtures.\n\n");
    try writer.writeAll("## Regeneration path\n\n");
    try writer.writeAll("```sh\n");
    try writer.writeAll("zig build reports\n");
    try writer.writeAll("```\n\n");
    try writer.writeAll("Optional drift check:\n\n");
    try writer.writeAll("```sh\n");
    try writer.writeAll("zig build reports -- --check\n");
    try writer.writeAll("```\n\n");

    try writer.writeAll("## Analysis fixture\n\n");
    try writer.print("- Scenario fixture: `{s}`\n", .{analysis_case.scenario_path});
    try writer.print("- Policy: `{s}`\n", .{@tagName(analysis_case.policy)});
    try writer.print("- Export artifact: `{s}`\n", .{analysis_case.export_path});
    try writer.print("- Markdown artifact: `{s}`\n", .{analysis_case.markdown_path});
    try writer.print("- SVG artifact: `{s}`\n", .{analysis_case.svg_path});
    try writer.writeAll("\n");

    try writer.writeAll("## Benchmark baseline matrix\n\n");
    try writer.print("- Markdown artifact: `{s}`\n", .{benchmark_artifacts.markdown_path});
    try writer.print("- JSON artifact: `{s}`\n", .{benchmark_artifacts.json_path});
    try writer.writeAll("\n");
    try writer.writeAll("| case | scenario | policy |\n");
    try writer.writeAll("| --- | --- | --- |\n");
    for (bench.default_cases) |entry| {
        try writer.print("| `{s}` | `{s}` | `{s}` |\n", .{ entry.name, entry.scenario_path, @tagName(entry.policy) });
    }
    try writer.writeAll("\n");

    try writer.writeAll("## Determinism rules\n\n");
    try writer.writeAll("- Only committed scenario fixtures and committed export contracts feed this report pack.\n");
    try writer.writeAll("- Output bytes are expected to be stable across repeated runs unless code or fixtures intentionally change.\n");
    try writer.writeAll("- Simulator-local wording remains in force; these are teaching/research artifacts, not Linux-performance claims.\n");

    return try buffer.toOwnedSlice(allocator);
}

fn writeFile(dir: std.Io.Dir, relative_path: []const u8, contents: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    if (std.fs.path.dirname(relative_path)) |parent| {
        try dir.createDirPath(io, parent);
    }

    try dir.writeFile(io, .{ .sub_path = relative_path, .data = contents });
}

test {
    _ = @import("tests.zig");
}
