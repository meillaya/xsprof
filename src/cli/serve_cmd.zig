const std = @import("std");
const server = @import("../serve/server.zig");
const live = @import("../capture/live.zig");
const journal = @import("../stream/journal.zig");
const capability = @import("capability.zig");

const Writer = std.Io.Writer;

pub fn cmdServe(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    out: *Writer,
    err: *Writer,
) !u8 {
    var port: u16 = 8787;
    var journal_path: []const u8 = "fixtures/ui/healthy.ndjson";
    var assets_dir: []const u8 = "zig-out/web";
    var addr: []const u8 = "127.0.0.1";
    var live_capture = false;
    var live_stride: u32 = 80;
    var live_dir: ?[]const u8 = null;
    var recorder_dir: ?[]const u8 = null;
    var journal_explicit = false;
    var assets_explicit = false;
    var demo = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--port") and i + 1 < args.len) {
            i += 1;
            port = std.fmt.parseInt(u16, args[i], 10) catch {
                try err.writeAll("serve: invalid --port\n");
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "--journal") and i + 1 < args.len) {
            i += 1;
            journal_path = args[i];
            journal_explicit = true;
        } else if (std.mem.eql(u8, arg, "--assets-dir") and i + 1 < args.len) {
            i += 1;
            assets_dir = args[i];
            assets_explicit = true;
        } else if (std.mem.eql(u8, arg, "--demo")) {
            demo = true;
        } else if (std.mem.eql(u8, arg, "--addr") and i + 1 < args.len) {
            i += 1;
            addr = args[i];
        } else if (std.mem.eql(u8, arg, "--live")) {
            live_capture = true;
        } else if (std.mem.eql(u8, arg, "--recorder-dir") and i + 1 < args.len) {
            i += 1;
            recorder_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--live-dir") and i + 1 < args.len) {
            i += 1;
            live_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--live-stride") and i + 1 < args.len) {
            i += 1;
            live_stride = std.fmt.parseInt(u32, args[i], 10) catch {
                try err.writeAll("serve: invalid --live-stride\n");
                return 2;
            };
        }
    }
    if (demo and !journal_explicit) {
        journal_path = findFixture(io) orelse {
            try err.writeAll("serve: demo fixture not found\n");
            return 1;
        };
    }
    if (!assets_explicit) {
        assets_dir = findAssets(io) orelse assets_dir;
    }
    if (!std.mem.eql(u8, addr, "127.0.0.1") and !std.mem.eql(u8, addr, "::1")) {
        try err.writeAll("serve: refusing non-loopback address\n");
        return 2;
    }
    if (live_dir != null) live_capture = true;
    if (live_capture and live_dir == null) {
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
    }
    if (!live_capture) {
        journal.validateFile(io, allocator, journal_path) catch |validate_error| {
            try err.print(
                "serve: refusing invalid journal {s}: {s}\n",
                .{ journal_path, @errorName(validate_error) },
            );
            return 1;
        };
    }
    var raw: [16]u8 = undefined;
    std.Io.randomSecure(io, &raw) catch {
        try err.writeAll("serve: entropy unavailable\n");
        return 1;
    };
    var token: [32]u8 = undefined;
    const hex = "0123456789abcdef";
    for (raw, 0..) |byte, index| {
        token[index * 2] = hex[byte >> 4];
        token[index * 2 + 1] = hex[byte & 0x0f];
    }
    try out.print("http://{s}:{d}/#token={s}\n", .{ addr, port, token[0..] });
    try out.flush();
    server.run(io, allocator, .{
        .addr = addr,
        .port = port,
        .journal_path = journal_path,
        .assets_dir = assets_dir,
        .token = token[0..],
        .live = live_capture,
        .live_stride = live_stride,
        .live_dir = live_dir,
        .recorder_dir = recorder_dir,
    }) catch |serve_error| {
        try err.print("serve: {s}\n", .{@errorName(serve_error)});
        return 1;
    };
    return 0;
}

fn exists(io: std.Io, path: []const u8) bool {
    if (path.len != 0 and path[0] == '/') {
        std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    } else {
        std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    }
    return true;
}

fn findAssets(io: std.Io) ?[]const u8 {
    if (std.c.getenv("XSPROF_WEB_DIR")) |value| {
        const path = std.mem.span(value);
        if (exists(io, path)) return path;
    }
    inline for ([_][]const u8{
        "zig-out/web",
        "share/xsprof/web",
        "/usr/share/xsprof/web",
        "/usr/local/share/xsprof/web",
    }) |candidate| {
        if (exists(io, candidate)) return candidate;
    }
    return null;
}

var fixture_buffer: [1024]u8 = undefined;

fn fixtureCandidate(io: std.Io, env_dir: ?[]const u8) ?[]const u8 {
    if (env_dir) |dir| {
        if (dir.len != 0) {
            const joined = std.fmt.bufPrint(&fixture_buffer, "{s}/healthy.ndjson", .{dir}) catch null;
            if (joined) |candidate| {
                if (exists(io, candidate)) return candidate;
            }
        }
    }
    inline for ([_][]const u8{
        "fixtures/ui/healthy.ndjson",
        "share/xsprof/fixtures/healthy.ndjson",
        "/usr/share/xsprof/fixtures/healthy.ndjson",
        "/usr/local/share/xsprof/fixtures/healthy.ndjson",
    }) |candidate| {
        if (exists(io, candidate)) return candidate;
    }
    return null;
}

/// Locate the demo fixture. XSPROF_FIXTURES_DIR wins for packaged runtimes;
/// repo-relative and install prefixes remain as fallbacks.
fn findFixture(io: std.Io) ?[]const u8 {
    const env_dir = if (std.c.getenv("XSPROF_FIXTURES_DIR")) |value| std.mem.span(value) else null;
    return fixtureCandidate(io, env_dir);
}

// Checks XSPROF_FIXTURES_DIR candidate lookup with an explicit temp directory.
test "fixture env directory wins over repo candidates" {
    const allocator = std.testing.allocator;
    const root = try std.fmt.allocPrint(allocator, "/tmp/xsprof-fixtures-{d}", .{std.testing.random_seed});
    defer allocator.free(root);
    std.Io.Dir.createDirAbsolute(std.testing.io, root, .default_dir) catch {};
    defer std.Io.Dir.deleteDirAbsolute(std.testing.io, root) catch {};
    const file_path = try std.fmt.allocPrint(allocator, "{s}/healthy.ndjson", .{root});
    defer allocator.free(file_path);
    {
        const file = try std.Io.Dir.createFileAbsolute(std.testing.io, file_path, .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "{}\n");
    }
    const found = fixtureCandidate(std.testing.io, root) orelse return error.FixtureNotFound;
    try std.testing.expectEqualStrings(file_path, found);
}
