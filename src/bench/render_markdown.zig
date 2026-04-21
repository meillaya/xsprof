const std = @import("std");
const bench = @import("root.zig");

pub fn render(allocator: std.mem.Allocator, report: *const bench.Report) ![]u8 {
    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(allocator);
    var writer = buffer.writer(allocator);

    try writer.writeAll("# zig-scheduler benchmark baselines\n\n");
    try writer.print("- Contract: `{s}` v{d}\n", .{ report.schema, report.version });
    for (report.notes) |note| {
        try writer.print("- {s}\n", .{note});
    }
    try writer.writeAll("\n## Case matrix\n\n");
    try writer.writeAll("| case | policy | cores | tasks | trace_events | export_bytes | analysis_md_bytes | analysis_svg_bytes |\n");
    try writer.writeAll("| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |\n");
    for (report.cases) |case| {
        try writer.print(
            "| {s} | {s} | {d} | {d} | {d} | {d} | {d} | {d} |\n",
            .{ case.name, @tagName(case.policy), case.core_count, case.task_count, case.trace_events, case.export_bytes, case.analysis_markdown_bytes, case.analysis_svg_bytes },
        );
    }

    try writer.writeAll("\n## Aggregate totals\n\n");
    try writer.writeAll("| metric | value |\n");
    try writer.writeAll("| --- | ---: |\n");
    try writer.print("| case_count | {d} |\n", .{report.aggregate.case_count});
    try writer.print("| total_export_bytes | {d} |\n", .{report.aggregate.total_export_bytes});
    try writer.print("| total_analysis_markdown_bytes | {d} |\n", .{report.aggregate.total_analysis_markdown_bytes});
    try writer.print("| total_analysis_svg_bytes | {d} |\n", .{report.aggregate.total_analysis_svg_bytes});
    try writer.print("| total_trace_events | {d} |\n", .{report.aggregate.total_trace_events});
    try writer.print("| max_export_bytes | {d} |\n", .{report.aggregate.max_export_bytes});
    try writer.print("| max_trace_events | {d} |\n", .{report.aggregate.max_trace_events});
    try writer.writeAll("\n");

    try writer.writeAll("## Fixture coverage\n\n");
    for (report.cases) |case| {
        try writer.print("- `{s}` -> `{s}` (`{s}`)\n", .{ case.scenario_path, case.name, @tagName(case.policy) });
    }

    return try buffer.toOwnedSlice(allocator);
}
