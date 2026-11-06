const std = @import("std");
const json = @import("../core/json.zig");
const daemon = @import("../recorder/daemon.zig");
const live = @import("../capture/live.zig");
const recording = @import("../capture/recording.zig");
const extract = @import("../recorder/extract.zig");

const Writer = std.Io.Writer;

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
    args: []const []const u8,
    out: *Writer,
    err: *Writer,
) !u8 {
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
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "--max-bytes") and i + 1 < args.len) {
            i += 1;
            options.max_bytes = parseSize(args[i]) catch {
                try err.writeAll("daemon: invalid --max-bytes\n");
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "--history-interval") and i + 1 < args.len) {
            i += 1;
            options.history_interval_ms = extract.parseDuration(args[i]) catch {
                try err.writeAll("daemon: invalid --history-interval\n");
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "--history-retain") and i + 1 < args.len) {
            i += 1;
            options.history_retain_ms = extract.parseDuration(args[i]) catch {
                try err.writeAll("daemon: invalid --history-retain\n");
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "--duration") and i + 1 < args.len) {
            i += 1;
            const duration = extract.parseDuration(args[i]) catch {
                try err.writeAll("daemon: invalid --duration\n");
                return 2;
            };
            if (duration > std.math.maxInt(u32)) {
                try err.writeAll("daemon: --duration too large\n");
                return 2;
            }
            options.duration_ms = @intCast(duration);
        } else if (std.mem.eql(u8, arg, "--preset") and i + 1 < args.len) {
            i += 1;
            const preset = live.parsePreset(args[i]) orelse {
                try err.writeAll("daemon: unknown preset\n");
                return 2;
            };
            live_options = live.presetOptions(preset);
        } else if (std.mem.eql(u8, arg, "--foreground")) {
            continue;
        } else {
            try err.print("daemon: unknown option {s}\n", .{arg});
            return 2;
        }
    }
    options.live_options = live_options;
    const result = daemon.run(io, allocator, options) catch |run_error| {
        try err.print("daemon: {s}\n", .{@errorName(run_error)});
        return 1;
    };
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
        .{ .key = "rss_kb", .value = .{ .unsigned = result.overhead.rss_kb } },
        .{ .key = "schema", .value = .{ .string = "xsprof/recorder-result/v1" } },
        .{ .key = "session_id", .value = .{ .string = result.session_id } },
        .{ .key = "sidecar_errors", .value = .{ .unsigned = result.sidecar_errors } },
        .{ .key = "state", .value = .{ .string = @tagName(result.state) } },
        .{ .key = "wall_ms", .value = .{ .unsigned = result.overhead.wall_ms } },
    } });
    try out.writeByte('\n');
    return if (result.state == .READY) 0 else 1;
}

pub fn cmdCapture(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    out: *Writer,
    err: *Writer,
) !u8 {
    var dir: ?[]const u8 = null;
    var last_text: ?[]const u8 = null;
    var output: ?[]const u8 = null;
    var force = false;
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
        } else {
            try err.print("capture: unknown option {s}\n", .{arg});
            return 2;
        }
    }
    const last = last_text orelse {
        try err.writeAll("capture: --last <duration> is required\n");
        return 2;
    };
    const last_ms = extract.parseDuration(last) catch {
        try err.writeAll("capture: invalid --last duration\n");
        return 2;
    };
    const resolved_dir = if (dir) |value| value else try defaultDir(allocator);
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
                return 1;
            }
        else
            std.Io.Dir.cwd().createFile(io, path, options) catch |open_error| {
                try err.print("capture: cannot open {s}: {s}\n", .{ path, @errorName(open_error) });
                return 1;
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
    }, writer) catch |extract_error| {
        try err.print("capture: {s}\n", .{@errorName(extract_error)});
        return 1;
    };
    try writer.flush();
    return 0;
}

fn defaultDir(allocator: std.mem.Allocator) ![]const u8 {
    if (std.c.getenv("XDG_STATE_HOME")) |value| {
        return std.fmt.allocPrint(allocator, "{s}/xsprof", .{std.mem.span(value)});
    }
    if (std.c.getenv("HOME")) |value| {
        return std.fmt.allocPrint(allocator, "{s}/.local/state/xsprof", .{std.mem.span(value)});
    }
    return error.NoStateDirectory;
}
