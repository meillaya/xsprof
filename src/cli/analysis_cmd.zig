const std = @import("std");
const journal = @import("../stream/journal.zig");
const event_mod = @import("../core/event.zig");
const metrics_mod = @import("../analyze/metrics.zig");
const metrics_json = @import("../analyze/metrics_json.zig");
const compare_mod = @import("../analyze/compare.zig");
const perf_script_import = @import("../viz/perf_script_import.zig");

const Writer = std.Io.Writer;
const Exit = @import("exit.zig").Exit;

const max_rules = 32;

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

/// One comparison input: the scalar metrics plus the per-comm histograms the
/// noise-aware gate merges across repeated captures.
fn loadRun(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
) !compare_mod.RunInput {
    const events = try journal.read(io, allocator, path);
    var index = metrics_mod.Index.init(allocator);
    defer index.deinit();
    try index.append(events);
    return .{
        .source = path,
        .metrics = try index.snapshot(allocator),
        .comms = try compare_mod.extractComms(allocator, &index),
    };
}

pub fn cmdMetrics(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    out: *Writer,
    err: *Writer,
) !Exit {
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
                return .usage;
            };
        } else if (std.mem.eql(u8, arg, "--json")) {
            // Metrics output is always canonical JSON; the flag is accepted
            // for automation symmetry with the documented usage.
        } else {
            try err.print("metrics: unknown option {s}\n", .{arg});
            return .usage;
        }
    }
    const path = input orelse {
        try err.writeAll("metrics: --input <journal> is required\n");
        return .usage;
    };
    const values = loadMetrics(io, allocator, path) catch |load_error| {
        try err.print("metrics: {s}\n", .{@errorName(load_error)});
        return .refuse;
    };
    try metrics_json.writeJson(out, values, top);
    try out.writeByte('\n');
    return .ok;
}

const CompareOptions = struct {
    bases: std.ArrayList([]const u8) = .empty,
    candidates: std.ArrayList([]const u8) = .empty,
    rules: std.ArrayList(compare_mod.Rule) = .empty,
    min_runs: usize = 1,
    threshold_pct: f64 = compare_mod.default_threshold_pct,
    html_path: ?[]const u8 = null,
    markdown: bool = false,

    fn deinit(self: *CompareOptions, allocator: std.mem.Allocator) void {
        self.bases.deinit(allocator);
        self.candidates.deinit(allocator);
        self.rules.deinit(allocator);
    }
};

fn parseCompareOptions(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    err: *Writer,
) !CompareOptions {
    var options = CompareOptions{};
    errdefer options.deinit(allocator);
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--base")) {
            i += 1;
            if (i >= args.len) {
                try err.writeAll("compare: --base requires a capture path\n");
                return error.BadArgs;
            }
            if (options.bases.items.len >= compare_mod.max_runs_per_side) {
                try err.print("compare: at most {d} --base captures are supported\n", .{compare_mod.max_runs_per_side});
                return error.BadArgs;
            }
            try options.bases.append(allocator, args[i]);
        } else if (std.mem.eql(u8, arg, "--candidate")) {
            i += 1;
            if (i >= args.len) {
                try err.writeAll("compare: --candidate requires a capture path\n");
                return error.BadArgs;
            }
            if (options.candidates.items.len >= compare_mod.max_runs_per_side) {
                try err.print("compare: at most {d} --candidate captures are supported\n", .{compare_mod.max_runs_per_side});
                return error.BadArgs;
            }
            try options.candidates.append(allocator, args[i]);
        } else if (std.mem.eql(u8, arg, "--min-runs")) {
            i += 1;
            if (i >= args.len) {
                try err.writeAll("compare: --min-runs requires a value\n");
                return error.BadArgs;
            }
            const parsed = std.fmt.parseInt(usize, args[i], 10) catch {
                try err.writeAll("compare: --min-runs must be an integer between 1 and 8\n");
                return error.BadArgs;
            };
            if (parsed < 1 or parsed > compare_mod.max_runs_per_side) {
                try err.writeAll("compare: --min-runs must be an integer between 1 and 8\n");
                return error.BadArgs;
            }
            options.min_runs = parsed;
        } else if (std.mem.eql(u8, arg, "--fail-on")) {
            i += 1;
            if (i >= args.len) {
                try err.writeAll("compare: --fail-on requires a metric threshold\n");
                return error.BadArgs;
            }
            const rule = compare_mod.parseRule(args[i]) catch {
                try err.print(
                    "compare: invalid --fail-on {s}; expected wait.p50|p95|p99|max|offcpu.p95=<percent> " ++
                        "or preemptions|migrations|loss=<absolute>\n",
                    .{args[i]},
                );
                return error.BadArgs;
            };
            if (options.rules.items.len >= max_rules) {
                try err.print("compare: at most {d} --fail-on rules are supported\n", .{max_rules});
                return error.BadArgs;
            }
            switch (rule) {
                .latency => |latency| {
                    if (latency.metric == .wait_p95) options.threshold_pct = latency.threshold_pct;
                },
                .counter => {},
            }
            try options.rules.append(allocator, rule);
        } else if (std.mem.eql(u8, arg, "--html")) {
            i += 1;
            if (i >= args.len) {
                try err.writeAll("compare: --html requires a path\n");
                return error.BadArgs;
            }
            options.html_path = args[i];
        } else if (std.mem.eql(u8, arg, "--md")) {
            options.markdown = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            // JSON is the default output; accepted for automation symmetry.
        } else {
            try err.print("compare: unknown option {s}\n", .{arg});
            return error.BadArgs;
        }
    }
    return options;
}

fn loadInputs(
    io: std.Io,
    allocator: std.mem.Allocator,
    paths: []const []const u8,
    side: []const u8,
    err: *Writer,
) !?std.ArrayList(compare_mod.RunInput) {
    var inputs: std.ArrayList(compare_mod.RunInput) = .empty;
    errdefer inputs.deinit(allocator);
    for (paths) |path| {
        const input = loadRun(io, allocator, path) catch |load_error| {
            try err.print("compare: {s} {s}: {s}\n", .{ side, path, @errorName(load_error) });
            return null;
        };
        try inputs.append(allocator, input);
    }
    return inputs;
}

pub fn cmdCompare(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    out: *Writer,
    err: *Writer,
) !Exit {
    var options = parseCompareOptions(allocator, args, err) catch return .usage;
    defer options.deinit(allocator);
    if (options.bases.items.len == 0) {
        try err.writeAll("compare: at least one --base <capture> is required\n");
        return .usage;
    }
    if (options.candidates.items.len == 0) {
        try err.writeAll("compare: at least one --candidate <capture> is required\n");
        return .usage;
    }
    if (options.min_runs > 1 and
        (options.bases.items.len < options.min_runs or options.candidates.items.len < options.min_runs))
    {
        try err.print(
            "compare: --min-runs {d} requires at least {d} --base and {d} --candidate captures (got {d} and {d})\n",
            .{ options.min_runs, options.min_runs, options.min_runs, options.bases.items.len, options.candidates.items.len },
        );
        return .usage;
    }
    for (options.rules.items) |rule| switch (rule) {
        .counter => |counter_rule| if (!compare_mod.counterAvailable(counter_rule.metric)) {
            try err.print(
                "compare: --fail-on {s} is unavailable in this build (requires causal-latency metrics)\n",
                .{compare_mod.counterName(counter_rule.metric)},
            );
            return .usage;
        },
        .latency => {},
    };

    var base_inputs = try loadInputs(io, allocator, options.bases.items, "base", err) orelse return .refuse;
    defer base_inputs.deinit(allocator);
    var candidate_inputs = try loadInputs(io, allocator, options.candidates.items, "candidate", err) orelse return .refuse;
    defer candidate_inputs.deinit(allocator);

    const report = compare_mod.build(allocator, base_inputs.items, candidate_inputs.items, .{
        .threshold_pct = options.threshold_pct,
        .rules = options.rules.items,
    }) catch |build_error| {
        try err.print("compare: {s}\n", .{@errorName(build_error)});
        return .refuse;
    };
    if (options.html_path) |path| {
        var allocating = std.Io.Writer.Allocating.init(allocator);
        defer allocating.deinit();
        try compare_mod.writeHtml(&allocating.writer, report);
        const file = std.Io.Dir.createFileAbsolute(io, path, .{}) catch |open_error| {
            try err.print("compare: cannot open {s}: {s}\n", .{ path, @errorName(open_error) });
            return .refuse;
        };
        defer file.close(io);
        try file.writeStreamingAll(io, allocating.written());
    } else if (options.markdown) {
        try compare_mod.writeMarkdown(out, report);
    } else {
        try compare_mod.writeJson(out, report);
        try out.writeByte('\n');
    }
    if (report.fail_reasons.len != 0) return .internal;
    if (report.unavailable_rules.len != 0) {
        for (report.unavailable_rules) |name| {
            try err.print(
                "compare: --fail-on {s}: no comparable data (unknown, not a pass)\n",
                .{name},
            );
        }
        return .refuse;
    }
    return .ok;
}

fn readTextFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    max_bytes: usize,
) ?[]u8 {
    const file = if (path.len != 0 and path[0] == '/')
        std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null
    else
        std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    return reader.interface.allocRemaining(allocator, .limited(max_bytes)) catch null;
}

/// `import --perf-script FILE [--out FILE]`: strict, bounded conversion of the
/// documented `perf script` subset to canonical `xsprof/event/v1` NDJSON.
/// A file with any rejected line is refused whole; no partial rows are written.
pub fn cmdImport(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    out: *Writer,
    err: *Writer,
) !Exit {
    var input: ?[]const u8 = null;
    var output: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--perf-script")) {
            i += 1;
            if (i >= args.len) {
                try err.writeAll("import: --perf-script requires a file\n");
                return .usage;
            }
            input = args[i];
        } else if (std.mem.eql(u8, arg, "--out")) {
            i += 1;
            if (i >= args.len) {
                try err.writeAll("import: --out requires a file\n");
                return .usage;
            }
            output = args[i];
        } else {
            try err.print("import: unknown option {s}\n", .{arg});
            return .usage;
        }
    }
    const path = input orelse {
        try err.writeAll("import: --perf-script <file> is required\n");
        return .usage;
    };
    const text = readTextFile(io, allocator, path, perf_script_import.max_input_bytes + 1) orelse {
        try err.print("import: cannot read {s}\n", .{path});
        return .refuse;
    };
    var result = perf_script_import.import(allocator, text, .{}) catch |import_error| {
        try err.print("import: {s}\n", .{@errorName(import_error)});
        return .refuse;
    };
    defer result.deinit(allocator);
    if (!result.ok()) {
        for (result.diagnostics) |diagnostic| {
            try err.print("import: line {d}: {s}\n", .{
                diagnostic.line,
                perf_script_import.reasonName(diagnostic.reason),
            });
        }
        if (result.errors_truncated) try err.writeAll("import: further rejected lines suppressed\n");
        try err.print(
            "import: {d} of {d} lines rejected; refusing the file (no rows written)\n",
            .{ result.rejected, result.lines },
        );
        return .refuse;
    }
    if (result.events.len == 0) {
        try err.writeAll("import: no supported scheduler lines found\n");
        return .refuse;
    }
    var allocating = std.Io.Writer.Allocating.init(allocator);
    defer allocating.deinit();
    for (result.events) |entry| {
        try event_mod.writeJson(&allocating.writer, entry);
        try allocating.writer.writeByte('\n');
    }
    if (output) |out_path| {
        const file = if (out_path.len != 0 and out_path[0] == '/')
            std.Io.Dir.createFileAbsolute(io, out_path, .{}) catch |open_error| {
                try err.print("import: cannot open {s}: {s}\n", .{ out_path, @errorName(open_error) });
                return .refuse;
            }
        else
            std.Io.Dir.cwd().createFile(io, out_path, .{}) catch |open_error| {
                try err.print("import: cannot open {s}: {s}\n", .{ out_path, @errorName(open_error) });
                return .refuse;
            };
        defer file.close(io);
        file.writeStreamingAll(io, allocating.written()) catch |write_error| {
            try err.print("import: write failed: {s}\n", .{@errorName(write_error)});
            return .refuse;
        };
    } else {
        try out.writeAll(allocating.written());
    }
    return .ok;
}

fn expectUsage(args: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var out_buffer: [256]u8 = undefined;
    var err_buffer: [1024]u8 = undefined;
    var out = Writer.fixed(&out_buffer);
    var err = Writer.fixed(&err_buffer);
    try std.testing.expectEqual(
        Exit.usage,
        try cmdCompare(std.testing.io, arena.allocator(), args, &out, &err),
    );
}

test "compare requires at least one capture per side" {
    try expectUsage(&.{});
    try expectUsage(&.{"--base"});
    try expectUsage(&.{ "--base", "b.ndjson" });
    try expectUsage(&.{ "--candidate", "c.ndjson" });
}

test "compare validates the fail-on grammar and run bounds" {
    try expectUsage(&.{ "--base", "b", "--candidate", "c", "--fail-on", "wait.p90=5" });
    try expectUsage(&.{ "--base", "b", "--candidate", "c", "--fail-on", "loss=1%" });
    try expectUsage(&.{ "--base", "b", "--candidate", "c", "--min-runs", "0" });
    try expectUsage(&.{ "--base", "b", "--candidate", "c", "--min-runs", "9" });
    try expectUsage(&.{ "--base", "b", "--candidate", "c", "--min-runs", "x" });
    try expectUsage(&.{ "--base", "b", "--candidate", "c", "--nope" });
    // --min-runs K needs K captures on each side before any file is opened.
    try expectUsage(&.{ "--base", "b", "--candidate", "c", "--min-runs", "2" });
    try expectUsage(&.{ "--base", "b1", "--base", "b2", "--candidate", "c", "--min-runs", "2" });
}
