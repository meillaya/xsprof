const std = @import("std");
const list_writer = @import("list_writer");
const derive = @import("derive.zig");
const model = @import("model.zig");

pub fn render(allocator: std.mem.Allocator, report: *const model.Report, summary: *const derive.Derived) ![]u8 {
    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(allocator);
    var writer = list_writer.writer(&buffer, allocator);

    const width: u32 = 760;
    const left_margin: u32 = 180;
    const right_margin: u32 = 32;
    const top_margin: u32 = 84;
    const group_height: u32 = 44;
    const chart_width: u32 = width - left_margin - right_margin;
    const chart_height: u32 = @intCast(summary.tasks_by_input_order.len * group_height + 48);
    const height: u32 = top_margin + chart_height + 48;
    const max_metric = @max(@as(u32, 1), summary.max_turnaround_time);

    try writer.print(
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{d}\" height=\"{d}\" viewBox=\"0 0 {d} {d}\" role=\"img\" aria-labelledby=\"title desc\">\n",
        .{ width, height, width, height },
    );
    try writer.writeAll(
        "<style>\n" ++ ".title{font:700 20px sans-serif;fill:#111827;}\n" ++ ".subtitle,.axis,.legend,.label,.value{font:12px monospace;fill:#374151;}\n" ++ ".waiting{fill:#2563eb;}\n" ++ ".turnaround{fill:#f59e0b;}\n" ++ ".grid{stroke:#e5e7eb;stroke-width:1;}\n" ++ ".baseline{stroke:#9ca3af;stroke-width:1;}\n" ++ "</style>\n",
    );
    try writer.writeAll("<title id=\"title\">zig-scheduler waiting vs turnaround analysis</title>\n");
    try writer.writeAll("<desc id=\"desc\">Deterministic SVG derived from exported zig-scheduler/report JSON.</desc>\n");
    try writer.print("<text class=\"title\" x=\"24\" y=\"32\">Analysis: waiting vs turnaround time</text>\n", .{});
    try writer.writeAll("<text class=\"subtitle\" x=\"24\" y=\"52\">");
    try xmlEscapeWrite(&writer, report.scenario.name);
    try writer.writeAll(" · ");
    try xmlEscapeWrite(&writer, report.policy.display_name);
    try writer.print(" · contract v{d}</text>\n", .{report.version});
    try writer.writeAll("<rect x=\"24\" y=\"62\" width=\"12\" height=\"12\" class=\"waiting\"/><text class=\"legend\" x=\"42\" y=\"72\">waiting_time</text>\n");
    try writer.writeAll("<rect x=\"160\" y=\"62\" width=\"12\" height=\"12\" class=\"turnaround\"/><text class=\"legend\" x=\"178\" y=\"72\">turnaround_time</text>\n");

    const ticks = [_]u32{ 0, max_metric / 4, max_metric / 2, (max_metric * 3) / 4, max_metric };
    for (ticks) |tick| {
        const x = left_margin + scaledWidth(chart_width, max_metric, tick);
        try writer.print("<line class=\"grid\" x1=\"{d}\" y1=\"{d}\" x2=\"{d}\" y2=\"{d}\"/>\n", .{ x, top_margin, x, top_margin + chart_height - 24 });
        try writer.print("<text class=\"axis\" x=\"{d}\" y=\"{d}\" text-anchor=\"middle\">{d}</text>\n", .{ x, top_margin + chart_height, tick });
    }
    try writer.print("<line class=\"baseline\" x1=\"{d}\" y1=\"{d}\" x2=\"{d}\" y2=\"{d}\"/>\n", .{ left_margin, top_margin + chart_height - 24, left_margin + chart_width, top_margin + chart_height - 24 });

    for (summary.tasks_by_input_order, 0..) |task, index| {
        const y = top_margin + @as(u32, @intCast(index)) * group_height;
        const waiting_width = scaledWidth(chart_width, max_metric, task.waiting_time);
        const turnaround_width = scaledWidth(chart_width, max_metric, task.turnaround_time);

        try writer.print("<text class=\"label\" x=\"{d}\" y=\"{d}\" text-anchor=\"end\">", .{ left_margin - 12, y + 16 });
        try xmlEscapeWrite(&writer, task.id);
        try writer.writeAll("</text>\n");
        try writer.print("<text class=\"label\" x=\"{d}\" y=\"{d}\" text-anchor=\"end\">wait/turn</text>\n", .{ left_margin - 12, y + 30 });

        try writer.print("<rect class=\"waiting\" x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"10\" rx=\"2\"/>\n", .{ left_margin, y + 8, waiting_width });
        try writer.print("<rect class=\"turnaround\" x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"10\" rx=\"2\"/>\n", .{ left_margin, y + 22, turnaround_width });
        try writer.print("<text class=\"value\" x=\"{d}\" y=\"{d}\">{d} / {d}</text>\n", .{ left_margin + chart_width + 8, y + 18, task.waiting_time, task.turnaround_time });
    }

    try writer.writeAll("</svg>\n");
    return try buffer.toOwnedSlice(allocator);
}

fn scaledWidth(chart_width: u32, max_metric: u32, value: u32) u32 {
    if (value == 0) return 0;
    const width = (@as(u64, value) * chart_width) / max_metric;
    return @max(@as(u32, 1), @as(u32, @intCast(width)));
}

fn xmlEscapeWrite(writer: anytype, text: []const u8) !void {
    for (text) |char| {
        switch (char) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '"' => try writer.writeAll("&quot;"),
            '\'' => try writer.writeAll("&apos;"),
            else => try writer.writeByte(char),
        }
    }
}
