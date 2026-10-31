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
        } else if (std.mem.eql(u8, arg, "--duration") and i + 1 < args.len) {
            i += 1;
            options.duration_ms = std.fmt.parseInt(u32, args[i], 10) catch {
                try err.writeAll("daemon: invalid --duration\n");
                return 2;
            };
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
        .{ .key = "dir", .value = .{ .string = result.dir } },
        .{ .key = "events", .value = .{ .unsigned = result.events } },
        .{ .key = "host_mutation", .value = .{ .boolean = false } },
        .{ .key = "reason", .value = .{ .string = result.reason } },
        .{ .key = "schema", .value = .{ .string = "xsprof/recorder-result/v1" } },
        .{ .key = "session_id", .value = .{ .string = result.session_id } },
        .{ .key = "state", .value = .{ .string = @tagName(result.state) } },
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
    const data = extract.extract(io, allocator, .{
        .dir = resolved_dir,
        .last_ms = last_ms,
    }) catch |extract_error| {
        try err.print("capture: {s}\n", .{@errorName(extract_error)});
        return 1;
    };
    if (output) |path| {
        const file = std.Io.Dir.createFileAbsolute(io, path, .{}) catch |open_error| {
            try err.print("capture: cannot open {s}: {s}\n", .{ path, @errorName(open_error) });
            return 1;
        };
        defer file.close(io);
        file.writeStreamingAll(io, data) catch |write_error| {
            try err.print("capture: cannot write {s}: {s}\n", .{ path, @errorName(write_error) });
            return 1;
        };
    } else {
        try out.writeAll(data);
    }
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
