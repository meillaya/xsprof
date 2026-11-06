//! `xsprof top`: one live, read-only scheduler view with no daemon required.

const std = @import("std");
const live = @import("../capture/live.zig");
const metrics_mod = @import("../analyze/metrics.zig");
const metrics_json = @import("../analyze/metrics_json.zig");
const extract = @import("../recorder/extract.zig");
const dashboard = @import("../tui/dashboard.zig");
const capability = @import("capability.zig");

const Writer = std.Io.Writer;
const max_cpus = 256;

const Options = struct {
    duration_ms: u64 = 5000,
    interval_ms: u64 = 500,
    top_n: usize = 12,
    json: bool = false,
    once: bool = false,
    help: bool = false,
    live: live.Options = .{},
};

fn parseDuration(text: []const u8) !u64 {
    return extract.parseDuration(text);
}

fn parseArgs(args: []const []const u8, out: *Writer, err: *Writer) !?Options {
    var options: Options = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--duration")) {
            if (i + 1 >= args.len) {
                try err.writeAll("top: --duration requires a value\n");
                return null;
            }
            i += 1;
            options.duration_ms = parseDuration(args[i]) catch {
                try err.writeAll("top: invalid --duration\n");
                return null;
            };
        } else if (std.mem.eql(u8, arg, "--interval")) {
            if (i + 1 >= args.len) {
                try err.writeAll("top: --interval requires a value\n");
                return null;
            }
            i += 1;
            options.interval_ms = @max(100, parseDuration(args[i]) catch {
                try err.writeAll("top: invalid --interval\n");
                return null;
            });
        } else if (std.mem.eql(u8, arg, "--preset")) {
            if (i + 1 >= args.len) {
                try err.writeAll("top: --preset requires a value\n");
                return null;
            }
            i += 1;
            const preset = live.parsePreset(args[i]) orelse {
                try err.writeAll("top: unknown preset\n");
                return null;
            };
            options.live = live.presetOptions(preset);
        } else if (std.mem.eql(u8, arg, "--top")) {
            if (i + 1 >= args.len) {
                try err.writeAll("top: --top requires a number\n");
                return null;
            }
            i += 1;
            options.top_n = std.fmt.parseInt(usize, args[i], 10) catch {
                try err.writeAll("top: invalid --top\n");
                return null;
            };
        } else if (std.mem.eql(u8, arg, "--json")) {
            options.json = true;
        } else if (std.mem.eql(u8, arg, "--once")) {
            options.once = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            options.help = true;
            try out.writeAll(
                \\xsprof top [--duration 5s] [--interval 500ms] [--preset scheduler|memory|deep]
                \\  [--top N] [--json] [--once]
                \\Live read-only scheduler view. Exits non-zero with SKIP/REFUSE when
                \\perf tracepoints are unavailable.
                \\
            );
            return options;
        } else {
            try err.print("top: unknown option {s}\n", .{arg});
            return null;
        }
    }
    return options;
}

pub fn cmdTop(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    out: *Writer,
    err: *Writer,
) !u8 {
    const options = (try parseArgs(args, out, err)) orelse return 2;
    if (options.help) return 0;
    const probe = live.probe(io, allocator) catch |probe_error| {
        try capability.writeCapabilityEvent(out, "live_capture", "SKIP", @errorName(probe_error));
        return 1;
    };
    if (probe.state != .READY) {
        try capability.writeCapabilityEvent(
            out,
            "live_capture",
            capability.stateName(probe.state),
            probe.reason,
        );
        return 1;
    }

    var capture = live.Capture.open(io, allocator, options.live) catch |open_error| {
        try capability.writeCapabilityEvent(out, "live_capture", "SKIP", @errorName(open_error));
        return 1;
    };
    defer capture.deinit();

    var index = metrics_mod.Index.init(allocator);
    defer index.deinit();
    var snapshot_arena = std.heap.ArenaAllocator.init(allocator);
    defer snapshot_arena.deinit();
    var snapshot: ?metrics_mod.Metrics = null;
    const started = std.Io.Clock.now(.awake, io).nanoseconds;
    const deadline = started + @as(i96, @intCast(options.duration_ms)) * std.time.ns_per_ms;
    var last_render = started;
    const tty = std.Io.File.stdout().isTty(io) catch false;

    while (std.Io.Clock.now(.awake, io).nanoseconds < deadline) {
        const remaining_ns = deadline - std.Io.Clock.now(.awake, io).nanoseconds;
        const timeout_ms: u32 = @intCast(@min(
            @divTrunc(remaining_ns, std.time.ns_per_ms),
            100,
        ));
        const polled = capture.poll(@max(1, timeout_ms)) catch break;
        if (polled != 0) {
            var batch = capture.take() catch break;
            defer batch.deinit();
            index.append(batch.events) catch break;
        }
        const now = std.Io.Clock.now(.awake, io).nanoseconds;
        if (options.once and index.events != 0) {
            _ = snapshot_arena.reset(.retain_capacity);
            snapshot = index.snapshot(snapshot_arena.allocator()) catch null;
            break;
        }
        if (!options.json and now - last_render >= @as(i96, @intCast(options.interval_ms)) * std.time.ns_per_ms) {
            _ = snapshot_arena.reset(.retain_capacity);
            snapshot = index.snapshot(snapshot_arena.allocator()) catch null;
            if (snapshot) |metrics| {
                if (tty) try dashboard.render(out, "xsprof top", metrics, .{
                    .clear = true,
                    .top_n = options.top_n,
                    .window_ms = options.duration_ms,
                });
            }
            last_render = now;
        }
    }

    if (snapshot == null) {
        _ = snapshot_arena.reset(.retain_capacity);
        snapshot = index.snapshot(snapshot_arena.allocator()) catch null;
    }
    const metrics = snapshot orelse {
        try err.writeAll("top: no metric snapshot\n");
        return 1;
    };
    if (options.json) {
        try metrics_json.writeJson(out, metrics, options.top_n);
        try out.writeByte('\n');
    } else if (!tty) {
        try dashboard.render(out, "xsprof top", metrics, .{
            .top_n = options.top_n,
            .window_ms = options.duration_ms,
        });
    }
    return 0;
}

test "top options parse durations and top count" {
    var out_buffer: [512]u8 = undefined;
    var err_buffer: [512]u8 = undefined;
    var out = Writer.fixed(&out_buffer);
    var err = Writer.fixed(&err_buffer);
    const args = [_][]const u8{ "--duration", "2s", "--interval", "100ms", "--top", "5", "--json" };
    const parsed = (try parseArgs(&args, &out, &err)).?;
    try std.testing.expectEqual(@as(u64, 2000), parsed.duration_ms);
    try std.testing.expectEqual(@as(u64, 100), parsed.interval_ms);
    try std.testing.expectEqual(@as(usize, 5), parsed.top_n);
    try std.testing.expect(parsed.json);
}

test "top rejects unknown options" {
    var out_buffer: [256]u8 = undefined;
    var err_buffer: [256]u8 = undefined;
    var out = Writer.fixed(&out_buffer);
    var err = Writer.fixed(&err_buffer);
    const args = [_][]const u8{"--nope"};
    try std.testing.expect((try parseArgs(&args, &out, &err)) == null);
}
