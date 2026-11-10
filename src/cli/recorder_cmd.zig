const std = @import("std");
const json = @import("../core/json.zig");
const daemon = @import("../recorder/daemon.zig");
const live = @import("../capture/live.zig");
const recording = @import("../capture/recording.zig");
const extract = @import("../recorder/extract.zig");

const Writer = std.Io.Writer;
const Exit = @import("exit.zig").Exit;
const state_paths = @import("../platform/state_paths.zig");

fn parseSize(text: []const u8) !u64 {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len == 0) return error.InvalidSize;
    var unit: u64 = 1;
    var number = trimmed;
    if (std.mem.endsWith(u8, trimmed, "G")) {
        unit = 1024 * 1024 * 1024;
        number = trimmed[0 .. trimmed.len - 1];
    } else if (std.mem.endsWith(u8, trimmed, "M")) {
        unit = 1024 * 1024;
        number = trimmed[0 .. trimmed.len - 1];
    } else if (std.mem.endsWith(u8, trimmed, "K")) {
        unit = 1024;
        number = trimmed[0 .. trimmed.len - 1];
    }
    const value = std.fmt.parseInt(u64, number, 10) catch return error.InvalidSize;
    return std.math.mul(u64, value, unit) catch error.InvalidSize;
}

pub fn cmdDaemon(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: state_paths.Env,
    args: []const []const u8,
    out: *Writer,
    err: *Writer,
) !Exit {
    var options: daemon.Options = .{};
    var live_options: live.Options = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--dir") and i + 1 < args.len) {
            i += 1;
            options.dir = args[i];
        } else if (std.mem.eql(u8, arg, "--retain") and i + 1 < args.len) {
            i += 1;
            options.max_age_ms = extract.parseDuration(args[i]) catch {
                try err.writeAll("daemon: invalid --retain\n");
                return .usage;
            };
        } else if (std.mem.eql(u8, arg, "--max-bytes") and i + 1 < args.len) {
            i += 1;
            options.max_bytes = parseSize(args[i]) catch {
                try err.writeAll("daemon: invalid --max-bytes\n");
                return .usage;
            };
        } else if (std.mem.eql(u8, arg, "--history-interval") and i + 1 < args.len) {
            i += 1;
            options.history_interval_ms = extract.parseDuration(args[i]) catch {
                try err.writeAll("daemon: invalid --history-interval\n");
                return .usage;
            };
        } else if (std.mem.eql(u8, arg, "--history-retain") and i + 1 < args.len) {
            i += 1;
            options.history_retain_ms = extract.parseDuration(args[i]) catch {
                try err.writeAll("daemon: invalid --history-retain\n");
                return .usage;
            };
        } else if (std.mem.eql(u8, arg, "--duration") and i + 1 < args.len) {
            i += 1;
            const duration = extract.parseDuration(args[i]) catch {
                try err.writeAll("daemon: invalid --duration\n");
                return .usage;
            };
            if (duration > std.math.maxInt(u32)) {
                try err.writeAll("daemon: --duration too large\n");
                return .usage;
            }
            options.duration_ms = @intCast(duration);
        } else if (std.mem.eql(u8, arg, "--preset") and i + 1 < args.len) {
            i += 1;
            const preset = live.parsePreset(args[i]) orelse {
                try err.writeAll("daemon: unknown preset\n");
                return .usage;
            };
            live_options = live.presetOptions(preset);
        } else if (std.mem.eql(u8, arg, "--foreground")) {
            continue;
        } else {
            try err.print("daemon: unknown option {s}\n", .{arg});
            return .usage;
        }
    }
    options.live_options = live_options;
    if (options.dir == null or options.dir.?.len == 0) {
        options.dir = state_paths.stateDirWith(env, allocator) catch |dir_error| {
            try err.print("daemon: cannot resolve state dir: {s}\n", .{@errorName(dir_error)});
            return .refuse;
        };
    }
    const result = daemon.run(io, allocator, options) catch |run_error| {
        try err.print("daemon: {s}\n", .{@errorName(run_error)});
        return .refuse;
    };
    try writeDaemonResult(out, result);
    try out.writeByte('\n');
    // DEGRADED means the recorder ran with partial collector coverage; the JSON
    // state and per-ring session markers carry the shortfall. It is not a
    // failure to record, so only SKIP/REFUSE exit non-zero.
    return if (result.state == .READY or result.state == .DEGRADED) .ok else .refuse;
}

/// Canonical `xsprof/recorder-result/v1` document. Keys are strictly ascending.
/// `recovered_orphans` is additive: orphan segments adopted at daemon start.
fn writeDaemonResult(out: *Writer, result: daemon.Result) !void {
    try json.write(out, .{ .object = &.{
        .{ .key = "bytes", .value = .{ .unsigned = result.bytes } },
        .{ .key = "bytes_per_sec", .value = .{ .unsigned = result.overhead.bytes_per_sec } },
        .{ .key = "cpu_ms", .value = .{ .unsigned = result.overhead.cpu_ms } },
        .{ .key = "dir", .value = .{ .string = result.dir } },
        .{ .key = "events", .value = .{ .unsigned = result.events } },
        .{ .key = "events_per_sec", .value = .{ .unsigned = result.overhead.events_per_sec } },
        .{ .key = "history_dropped", .value = .{ .unsigned = result.history_dropped } },
        .{ .key = "history_sidecars", .value = .{ .unsigned = result.history_sidecars } },
        .{ .key = "host_mutation", .value = .{ .boolean = false } },
        .{ .key = "overhead_available", .value = .{ .boolean = result.overhead.available } },
        .{ .key = "overhead_bp", .value = .{ .unsigned = result.overhead.overhead_bp } },
        .{ .key = "reason", .value = .{ .string = result.reason } },
        .{ .key = "recovered_orphans", .value = .{ .unsigned = result.recovered_orphans } },
        .{ .key = "rss_kb", .value = .{ .unsigned = result.overhead.rss_kb } },
        .{ .key = "schema", .value = .{ .string = "xsprof/recorder-result/v1" } },
        .{ .key = "session_id", .value = .{ .string = result.session_id } },
        .{ .key = "sidecar_errors", .value = .{ .unsigned = result.sidecar_errors } },
        .{ .key = "state", .value = .{ .string = @tagName(result.state) } },
        .{ .key = "wall_ms", .value = .{ .unsigned = result.overhead.wall_ms } },
    } });
}

test "daemon result serializes recovered orphans canonically" {
    const result: daemon.Result = .{
        .state = .DEGRADED,
        .reason = "recording stopped",
        .dir = "/var/lib/xsprof",
        .session_id = "abc123",
        .events = 10,
        .bytes = 128,
        .history_sidecars = 1,
        .history_dropped = 0,
        .sidecar_errors = 0,
        .recovered_orphans = 3,
    };
    var buffer: [2048]u8 = undefined;
    var out = Writer.fixed(&buffer);
    try writeDaemonResult(&out, result);
    const text = out.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "\"recovered_orphans\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"state\":\"DEGRADED\"") != null);
    // Canonical ascending keys: reason < recovered_orphans < rss_kb.
    const reason_at = std.mem.indexOf(u8, text, "\"reason\"").?;
    const orphans_at = std.mem.indexOf(u8, text, "\"recovered_orphans\"").?;
    const rss_at = std.mem.indexOf(u8, text, "\"rss_kb\"").?;
    try std.testing.expect(reason_at < orphans_at and orphans_at < rss_at);
    // The recovered-orphans count survives a JSON round-trip.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), text, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(i64, 3), object.get("recovered_orphans").?.integer);
    try std.testing.expect(!object.get("host_mutation").?.bool);
}

pub fn cmdCapture(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: state_paths.Env,
    args: []const []const u8,
    out: *Writer,
    err: *Writer,
) !Exit {
    var dir: ?[]const u8 = null;
    var last_text: ?[]const u8 = null;
    var output: ?[]const u8 = null;
    var force = false;
    var markers_only = false;
    var max_events: u64 = 0;
    var max_window_bytes: u64 = 0;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--dir") and i + 1 < args.len) {
            i += 1;
            dir = args[i];
        } else if (std.mem.eql(u8, arg, "--last") and i + 1 < args.len) {
            i += 1;
            last_text = args[i];
        } else if (std.mem.eql(u8, arg, "--out") and i + 1 < args.len) {
            i += 1;
            output = args[i];
        } else if (std.mem.eql(u8, arg, "--force")) {
            force = true;
        } else if (std.mem.eql(u8, arg, "--markers-only")) {
            markers_only = true;
        } else if (std.mem.eql(u8, arg, "--max-events")) {
            if (i + 1 >= args.len) {
                try err.writeAll("capture: --max-events requires a number\n");
                return .usage;
            }
            i += 1;
            max_events = std.fmt.parseInt(u64, args[i], 10) catch {
                try err.writeAll("capture: invalid --max-events\n");
                return .usage;
            };
        } else if (std.mem.eql(u8, arg, "--max-window-bytes")) {
            if (i + 1 >= args.len) {
                try err.writeAll("capture: --max-window-bytes requires a size\n");
                return .usage;
            }
            i += 1;
            max_window_bytes = parseSize(args[i]) catch {
                try err.writeAll("capture: invalid --max-window-bytes\n");
                return .usage;
            };
        } else {
            try err.print("capture: unknown option {s}\n", .{arg});
            return .usage;
        }
    }
    const last = last_text orelse {
        try err.writeAll("capture: --last <duration> is required\n");
        return .usage;
    };
    const last_ms = extract.parseDuration(last) catch {
        try err.writeAll("capture: invalid --last duration\n");
        return .usage;
    };
    const resolved_dir = if (dir) |value| value else try state_paths.stateDirWith(env, allocator);
    const stdout_mode = if (output) |path| std.mem.eql(u8, path, "-") else true;

    var file: ?std.Io.File = null;
    if (!stdout_mode) {
        const path = output.?;
        const options: std.Io.Dir.CreateFileOptions = .{
            .exclusive = !force,
            .truncate = force,
        };
        file = if (path.len != 0 and path[0] == '/')
            std.Io.Dir.createFileAbsolute(io, path, options) catch |open_error| {
                try err.print("capture: cannot open {s}: {s}\n", .{ path, @errorName(open_error) });
                return .refuse;
            }
        else
            std.Io.Dir.cwd().createFile(io, path, options) catch |open_error| {
                try err.print("capture: cannot open {s}: {s}\n", .{ path, @errorName(open_error) });
                return .refuse;
            };
    }
    defer if (file) |opened| opened.close(io);

    var buffer: [64 * 1024]u8 = undefined;
    var file_writer: ?std.Io.File.Writer = null;
    if (file) |opened| file_writer = opened.writer(io, &buffer);
    const writer: *std.Io.Writer = if (file_writer) |*fw| &fw.interface else out;
    extract.writeTo(io, allocator, .{
        .dir = resolved_dir,
        .last_ms = last_ms,
        .markers_only = markers_only,
        .max_events = max_events,
        .max_bytes = max_window_bytes,
    }, writer) catch |extract_error| {
        try err.print("capture: {s}\n", .{@errorName(extract_error)});
        return .refuse;
    };
    try writer.flush();
    return .ok;
}
