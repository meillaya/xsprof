//! Loopback-only, read-only HTTP bridge for the web frontend.
//! GET/HEAD only; static assets plus /api/meta and /api/journal.

const std = @import("std");

pub const Options = struct {
    addr: []const u8 = "127.0.0.1",
    port: u16 = 8787,
    journal_path: []const u8,
    assets_dir: []const u8 = "zig-out/web",
    token: []const u8,
};

fn isLoopback(addr: []const u8) bool {
    return std.mem.eql(u8, addr, "127.0.0.1") or std.mem.eql(u8, addr, "::1");
}

fn readFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    max: usize,
) ![]u8 {
    const file = if (path.len != 0 and path[0] == '/')
        try std.Io.Dir.openFileAbsolute(io, path, .{})
    else
        try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &buffer);
    return reader.interface.allocRemaining(allocator, .limited(max));
}

fn contentType(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".html")) return "text/html; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".js")) return "text/javascript; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".css")) return "text/css; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".glsl")) return "text/plain; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".wasm")) return "application/wasm";
    if (std.mem.endsWith(u8, path, ".json")) return "application/json";
    if (std.mem.endsWith(u8, path, ".ndjson")) return "application/x-ndjson";
    return "application/octet-stream";
}

fn assetPath(path: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html")) return "index.html";
    inline for ([_][]const u8{
        "/main.js",              "/gl.js",                "/style.css",
        "/shaders/ui.vert.glsl", "/shaders/ui.frag.glsl", "/assets/xsprof-web.wasm",
    }) |candidate| {
        if (std.mem.eql(u8, path, candidate)) return candidate[1..];
    }
    return null;
}

fn queryToken(target: []const u8) ?[]const u8 {
    const at = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var it = std.mem.splitScalar(u8, target[at + 1 ..], '&');
    while (it.next()) |pair| {
        if (std.mem.startsWith(u8, pair, "token=")) return pair[6..];
    }
    return null;
}

fn respond(
    request: *std.http.Server.Request,
    status: std.http.Status,
    body: []const u8,
    content_type: []const u8,
) !void {
    try request.respond(body, .{
        .status = status,
        .keep_alive = false,
        .extra_headers = &.{
            .{ .name = "content-type", .value = content_type },
            .{ .name = "cache-control", .value = "no-store" },
            .{ .name = "x-content-type-options", .value = "nosniff" },
        },
    });
}

fn handle(
    io: std.Io,
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
    journal: []const u8,
    opts: Options,
) !void {
    var read_buffer: [16 * 1024]u8 = undefined;
    var write_buffer: [64 * 1024]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var writer = stream.writer(io, &write_buffer);
    var server = std.http.Server.init(&reader.interface, &writer.interface);
    var request = server.receiveHead() catch return;
    if (request.head.method != .GET and request.head.method != .HEAD) {
        try respond(&request, .method_not_allowed, "read-only: GET/HEAD only\n", "text/plain");
        return;
    }
    const target = request.head.target;
    const path_end = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    const path = target[0..path_end];

    if (std.mem.startsWith(u8, path, "/api/")) {
        const token = queryToken(target) orelse {
            try respond(&request, .unauthorized, "missing token\n", "text/plain");
            return;
        };
        if (!std.mem.eql(u8, token, opts.token)) {
            try respond(&request, .unauthorized, "invalid token\n", "text/plain");
            return;
        }
        if (std.mem.eql(u8, path, "/api/journal")) {
            try respond(&request, .ok, journal, "application/x-ndjson");
            return;
        }
        if (std.mem.eql(u8, path, "/api/meta")) {
            const rows = std.mem.count(u8, journal, "\n");
            const body = try std.fmt.allocPrint(
                allocator,
                "{{\"event_count\":{d},\"host_mutation\":false,\"schema\":\"xsprof/ui-session/v1\",\"source\":\"replay\"}}",
                .{rows},
            );
            try respond(&request, .ok, body, "application/json");
            return;
        }
        try respond(&request, .not_found, "unknown api\n", "text/plain");
        return;
    }

    const rel = assetPath(path) orelse {
        try respond(&request, .not_found, "not found\n", "text/plain");
        return;
    };
    var path_buffer: [512]u8 = undefined;
    const full = std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ opts.assets_dir, rel }) catch {
        try respond(&request, .internal_server_error, "path too long\n", "text/plain");
        return;
    };
    const body = readFile(io, allocator, full, 8 * 1024 * 1024) catch {
        try respond(
            &request,
            .service_unavailable,
            "asset missing; run `zig build web` first\n",
            "text/plain",
        );
        return;
    };
    try respond(&request, .ok, body, contentType(rel));
}

pub fn run(io: std.Io, allocator: std.mem.Allocator, opts: Options) !void {
    if (!isLoopback(opts.addr)) return error.NonLoopbackRefused;
    const address = try std.Io.net.IpAddress.parse(opts.addr, opts.port);
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    const journal = try readFile(io, allocator, opts.journal_path, 256 * 1024 * 1024);
    while (true) {
        const stream = listener.accept(io) catch continue;
        defer stream.close(io);
        handle(io, allocator, stream, journal, opts) catch {};
    }
}

test "loopback guard and asset mapping" {
    try std.testing.expect(isLoopback("127.0.0.1"));
    try std.testing.expect(isLoopback("::1"));
    try std.testing.expect(!isLoopback("0.0.0.0"));
    try std.testing.expectEqualStrings("main.js", assetPath("/main.js").?);
    try std.testing.expect(assetPath("/../etc/passwd") == null);
    try std.testing.expectEqualStrings("abc", queryToken("/x?token=abc").?);
}
