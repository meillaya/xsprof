const std = @import("std");
const journal = @import("../stream/journal.zig");
const metrics_mod = @import("../analyze/metrics.zig");
const metrics_json = @import("../analyze/metrics_json.zig");
const compare_mod = @import("../analyze/compare.zig");

const Writer = std.Io.Writer;

fn loadMetrics(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
) !metrics_mod.Metrics {
    const events = try journal.read(io, allocator, path);
    var index = metrics_mod.Index.init(allocator);
    defer index.deinit();
    try index.append(events);
    return index.snapshot(allocator);
}

pub fn cmdMetrics(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    out: *Writer,
    err: *Writer,
) !u8 {
    var input: ?[]const u8 = null;
    var top: usize = 64;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--input") and i + 1 < args.len) {
            i += 1;
            input = args[i];
        } else if (std.mem.eql(u8, arg, "--top") and i + 1 < args.len) {
            i += 1;
            top = std.fmt.parseInt(usize, args[i], 10) catch {
                try err.writeAll("metrics: invalid --top\n");
                return 2;
            };
        } else {
            try err.print("metrics: unknown option {s}\n", .{arg});
            return 2;
        }
    }
    const path = input orelse {
        try err.writeAll("metrics: --input <journal> is required\n");
        return 2;
    };
    const values = loadMetrics(io, allocator, path) catch |load_error| {
        try err.print("metrics: {s}\n", .{@errorName(load_error)});
        return 1;
    };
    try metrics_json.writeJson(out, values, top);
    try out.writeByte('\n');
    return 0;
}

fn parseThreshold(text: []const u8) !f64 {
    const equals = std.mem.indexOfScalar(u8, text, '=') orelse return error.InvalidThreshold;
    const metric = std.mem.trim(u8, text[0..equals], " ");
    if (!std.mem.eql(u8, metric, "wait.p95")) return error.UnsupportedMetric;
    var value = std.mem.trim(u8, text[equals + 1 ..], " ");
    if (std.mem.endsWith(u8, value, "%")) value = value[0 .. value.len - 1];
    const parsed = std.fmt.parseFloat(f64, value) catch return error.InvalidThreshold;
    if (parsed < 0) return error.InvalidThreshold;
    return parsed;
}

pub fn cmdCompare(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    out: *Writer,
    err: *Writer,
) !u8 {
    var base: ?[]const u8 = null;
    var candidate: ?[]const u8 = null;
    var html_path: ?[]const u8 = null;
    var markdown = false;
    var threshold: f64 = 10.0;
    var threshold_set = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--base") and i + 1 < args.len) {
            i += 1;
            base = args[i];
        } else if (std.mem.eql(u8, arg, "--candidate") and i + 1 < args.len) {
            i += 1;
            candidate = args[i];
        } else if (std.mem.eql(u8, arg, "--html") and i + 1 < args.len) {
            i += 1;
            html_path = args[i];
        } else if (std.mem.eql(u8, arg, "--md")) {
            markdown = true;
        } else if (std.mem.eql(u8, arg, "--fail-on") and i + 1 < args.len) {
            i += 1;
            threshold = parseThreshold(args[i]) catch {
                try err.writeAll("compare: --fail-on supports wait.p95=<percent>\n");
                return 2;
            };
            threshold_set = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            continue;
        } else {
            try err.print("compare: unknown option {s}\n", .{arg});
            return 2;
        }
    }
    const base_path = base orelse {
        try err.writeAll("compare: --base <journal> is required\n");
        return 2;
    };
    const candidate_path = candidate orelse {
        try err.writeAll("compare: --candidate <journal> is required\n");
        return 2;
    };
    const base_metrics = loadMetrics(io, allocator, base_path) catch |load_error| {
        try err.print("compare: base: {s}\n", .{@errorName(load_error)});
        return 1;
    };
    const candidate_metrics = loadMetrics(io, allocator, candidate_path) catch |load_error| {
        try err.print("compare: candidate: {s}\n", .{@errorName(load_error)});
        return 1;
    };
    const report = compare_mod.build(
        allocator,
        base_path,
        base_metrics,
        candidate_path,
        candidate_metrics,
        threshold,
    ) catch |build_error| {
        try err.print("compare: {s}\n", .{@errorName(build_error)});
        return 1;
    };
    if (html_path) |path| {
        var allocating = std.Io.Writer.Allocating.init(allocator);
        defer allocating.deinit();
        try compare_mod.writeHtml(&allocating.writer, report);
        const file = std.Io.Dir.createFileAbsolute(io, path, .{}) catch |open_error| {
            try err.print("compare: cannot open {s}: {s}\n", .{ path, @errorName(open_error) });
            return 1;
        };
        defer file.close(io);
        try file.writeStreamingAll(io, allocating.written());
    } else if (markdown) {
        try compare_mod.writeMarkdown(out, report);
    } else {
        try compare_mod.writeJson(out, report);
        try out.writeByte('\n');
    }
    if (threshold_set and report.regressions > 0) return 3;
    return 0;
}
