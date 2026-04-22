const std = @import("std");
const analysis = @import("analysis_root");
const scheduler = @import("zig_scheduler_internal");
const matrix = @import("matrix.zig");

pub const args = @import("args.zig");
pub const OutputFormat = args.OutputFormat;
pub const Options = args.Options;
pub const parseArgs = args.parseArgs;
pub const default_cases = matrix.default_cases;

pub const schema_name = "zig-scheduler/benchmark-baseline";
pub const schema_version: u32 = 1;

pub const CaseResult = struct {
    name: []const u8,
    scenario_path: []const u8,
    policy: scheduler.PolicyKind,
    core_count: u32,
    task_count: u32,
    trace_events: u32,
    completion_count: u32,
    export_bytes: u32,
    analysis_markdown_bytes: u32,
    analysis_svg_bytes: u32,
};

pub const Aggregate = struct {
    case_count: u32,
    total_export_bytes: u32,
    total_analysis_markdown_bytes: u32,
    total_analysis_svg_bytes: u32,
    total_trace_events: u32,
    max_export_bytes: u32,
    max_trace_events: u32,
};

pub const Report = struct {
    schema: []const u8,
    version: u32,
    notes: []const []const u8,
    cases: []CaseResult,
    aggregate: Aggregate,

    pub fn deinit(self: *Report, allocator: std.mem.Allocator) void {
        allocator.free(self.cases);
        self.* = undefined;
    }
};

const benchmark_notes = [_][]const u8{
    "Simulator-local benchmark baseline only; not a Linux performance claim.",
    "Metrics are deterministic output-size and trace-volume baselines over committed fixtures.",
};

pub fn run(allocator: std.mem.Allocator) !Report {
    var cases = try allocator.alloc(CaseResult, default_cases.len);
    errdefer allocator.free(cases);

    var aggregate: Aggregate = .{
        .case_count = @intCast(default_cases.len),
        .total_export_bytes = 0,
        .total_analysis_markdown_bytes = 0,
        .total_analysis_svg_bytes = 0,
        .total_trace_events = 0,
        .max_export_bytes = 0,
        .max_trace_events = 0,
    };

    for (default_cases, 0..) |entry, index| {
        var scenario = try scheduler.loadScenarioFile(allocator, entry.scenario_path);
        defer scenario.deinit();

        var result = try scheduler.simulate(allocator, &scenario, entry.policy);
        defer result.deinit();

        const source: scheduler.cli.SourceInfo = .{ .kind = .file, .value = entry.scenario_path };
        const sim_report = scheduler.cli.SimulationReport.init(source, &scenario, &result);

        var export_buffer: std.ArrayList(u8) = .empty;
        defer export_buffer.deinit(allocator);
        var export_writer = export_buffer.writer(allocator);
        try scheduler.cli.writeJsonReport(&export_writer, sim_report);
        const export_bytes: u32 = @intCast(export_buffer.items.len);

        const markdown = try analysis.analyzeBytes(allocator, export_buffer.items, .markdown);
        defer allocator.free(markdown);
        const svg = try analysis.analyzeBytes(allocator, export_buffer.items, .svg);
        defer allocator.free(svg);

        cases[index] = .{
            .name = entry.name,
            .scenario_path = entry.scenario_path,
            .policy = entry.policy,
            .core_count = result.core_count,
            .task_count = @intCast(result.tasks.len),
            .trace_events = @intCast(result.trace.len),
            .completion_count = @intCast(result.completion_order.len),
            .export_bytes = export_bytes,
            .analysis_markdown_bytes = @intCast(markdown.len),
            .analysis_svg_bytes = @intCast(svg.len),
        };

        aggregate.total_export_bytes += cases[index].export_bytes;
        aggregate.total_analysis_markdown_bytes += cases[index].analysis_markdown_bytes;
        aggregate.total_analysis_svg_bytes += cases[index].analysis_svg_bytes;
        aggregate.total_trace_events += cases[index].trace_events;
        aggregate.max_export_bytes = @max(aggregate.max_export_bytes, cases[index].export_bytes);
        aggregate.max_trace_events = @max(aggregate.max_trace_events, cases[index].trace_events);
    }

    return .{
        .schema = schema_name,
        .version = schema_version,
        .notes = benchmark_notes[0..],
        .cases = cases,
        .aggregate = aggregate,
    };
}

pub fn render(allocator: std.mem.Allocator, output_format: OutputFormat) ![]u8 {
    var report = try run(allocator);
    defer report.deinit(allocator);

    return switch (output_format) {
        .json => renderJson(allocator, &report),
        .markdown => @import("render_markdown.zig").render(allocator, &report),
    };
}

fn renderJson(allocator: std.mem.Allocator, report: *const Report) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    var writer = list.writer(allocator);
    var bridge_buffer: [256]u8 = undefined;
    var adapter = writer.adaptToNewApi(&bridge_buffer);
    try std.json.Stringify.value(report.*, .{}, &adapter.new_interface);
    if (adapter.err) |err| return err;
    try adapter.new_interface.flush();
    try list.append(allocator, '\n');
    return try list.toOwnedSlice(allocator);
}

test {
    _ = @import("args.zig");
    _ = @import("tests.zig");
}
