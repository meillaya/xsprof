//! Loopback-only, read-only HTTP bridge. GET/HEAD only.
//! Replay mode serves a journal; live mode adds a downsampled perf stream and
//! an SSE endpoint. Nothing here mutates the host.

const std = @import("std");
const event = @import("../core/event.zig");
const recording = @import("../capture/recording.zig");
const Store = @import("live_store.zig").Store;

const Writer = std.Io.Writer;

pub const Options = struct {
    addr: []const u8 = "127.0.0.1",
    port: u16 = 8787,
    journal_path: []const u8,
    assets_dir: []const u8 = "zig-out/web",
    token: []const u8,
    live: bool = false,
};

fn isLoopback(addr: []const u8) bool {
    return std.mem.eql(u8, addr, "127.0.0.1") or std.mem.eql(u8, addr, "::1");
}

fn readFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8, max: usize) ![]u8 {
    const file = if (path.len != 0 and path[0] == '/')
        try std.Io.Dir.openFileAbsolute(io, path, .{})
    else
        try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    return reader.interface.allocRemaining(allocator, .limited(max));
}

fn contentType(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".html")) return "text/html; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".js")) return "text/javascript; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".css")) return "text/css; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".glsl")) return "text/plain; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".wasm")) return "application/wasm";
    if (std.mem.endsWith(u8, path, ".ndjson")) return "application/x-ndjson";
    return "application/octet-stream";
}

fn assetPath(path: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html")) return "index.html";
    inline for ([_][]const u8{
        "/main.js",              "/gl.js",
        "/style.css",            "/shaders/ui.vert.glsl",
        "/shaders/ui.frag.glsl", "/assets/xsprof-web.wasm",
    }) |candidate| {
        if (std.mem.eql(u8, path, candidate)) return candidate[1..];
    }
    return null;
}

fn queryParam(target: []const u8, key: []const u8) ?[]const u8 {
    const at = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var it = std.mem.splitScalar(u8, target[at + 1 ..], '&');
    while (it.next()) |pair| {
        if (std.mem.startsWith(u8, pair, key) and pair.len > key.len and pair[key.len] == '=') {
            return pair[key.len + 1 ..];
        }
    }
    return null;
}

fn lastEventId(request: *const std.http.Server.Request) ?[]const u8 {
    var it = request.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "last-event-id")) return header.value;
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

fn appendCapability(io: std.Io, store: *Store, state: []const u8, reason: []const u8) void {
    var detail_buf: [256]u8 = undefined;
    const detail = std.fmt.bufPrint(
        &detail_buf,
        "live_capture:{s}:{s}",
        .{ state, reason },
    ) catch return;
    var output: [768]u8 = undefined;
    var writer = Writer.fixed(&output);
    const now = std.Io.Clock.now(.awake, io).nanoseconds;
    event.writeJson(&writer, .{
        .kind = .capability,
        .ts_ns = if (now > 0) @intCast(@min(now, std.math.maxInt(u64))) else 0,
        .comm = "live_capture",
        .detail = detail,
    }) catch return;
    store.append(writer.buffered());
    store.append("\n");
}

fn worker(io: std.Io, store: *Store) void {
    var sent_ready = false;
    while (true) {
        var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
        defer arena.deinit();
        const result = recording.record(io, arena.allocator(), 350) catch |capture_error| {
            appendCapability(io, store, "SKIP", @errorName(capture_error));
            std.Io.sleep(io, .fromMilliseconds(2000), .awake) catch {};
            continue;
        };
        if (result.state != .READY) {
            appendCapability(io, store, switch (result.state) {
                .READY => "READY",
                .DEGRADED => "DEGRADED",
                .SKIP => "SKIP",
                .REFUSE => "REFUSE",
            }, result.reason);
            std.Io.sleep(io, .fromMilliseconds(2000), .awake) catch {};
            continue;
        }
        if (!sent_ready) {
            appendCapability(io, store, "READY", "perf sched tracepoints active");
            sent_ready = true;
        }
        var allocating = Writer.Allocating.init(arena.allocator());
        var dropped: usize = 0;
        var last_ts: u64 = 0;
        for (result.events, 0..) |e, index| {
            last_ts = e.ts_ns;
            if (index % 80 != 0) {
                dropped += 1;
                continue;
            }
            event.writeJson(&allocating.writer, e) catch continue;
            allocating.writer.writeByte('\n') catch continue;
        }
        if (dropped != 0) {
            var detail_buf: [96]u8 = undefined;
            const detail = std.fmt.bufPrint(
                &detail_buf,
                "sample_loss live_downsample dropped={d}",
                .{dropped},
            ) catch "sample_loss live_downsample";
            event.writeJson(&allocating.writer, .{
                .kind = .marker,
                .ts_ns = last_ts,
                .cpu = -1,
                .detail = detail,
            }) catch {};
            allocating.writer.writeByte('\n') catch {};
        }
        const data = allocating.toOwnedSlice() catch {
            std.Io.sleep(io, .fromMilliseconds(500), .awake) catch {};
            continue;
        };
        store.append(data);
        std.Io.sleep(io, .fromMilliseconds(120), .awake) catch {};
    }
}

fn buildSse(allocator: std.mem.Allocator, snap: anytype) ![]u8 {
    var allocating = Writer.Allocating.init(allocator);
    var count: usize = 0;
    if (snap.reset) {
        try allocating.writer.writeAll(
            "event: reset\ndata: {\"reason\":\"live buffer trimmed\"}\n\n",
        );
    }
    var offset: u64 = snap.start;
    var lines = std.mem.splitScalar(u8, snap.data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        offset += line.len + 1;
        try allocating.writer.print("id: {d}\ndata: {s}\n\n", .{ offset, line });
        count += 1;
    }
    if (count == 0 and !snap.reset) {
        try allocating.writer.writeAll("retry: 1000\n: keepalive\n\n");
    }
    return allocating.toOwnedSlice();
}

fn handle(
    io: std.Io,
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
    journal: []const u8,
    store: *Store,
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
        const token = queryParam(target, "token") orelse {
            try respond(&request, .unauthorized, "missing token\n", "text/plain");
            return;
        };
        if (!std.mem.eql(u8, token, opts.token)) {
            try respond(&request, .unauthorized, "invalid token\n", "text/plain");
            return;
        }
        if (std.mem.eql(u8, path, "/api/journal")) {
            const body = if (opts.live) try store.snapshot(allocator) else journal;
            try respond(&request, .ok, body, "application/x-ndjson");
            return;
        }
        if (std.mem.eql(u8, path, "/api/meta")) {
            const body = if (opts.live) try store.snapshot(allocator) else journal;
            const rows = std.mem.count(u8, body, "\n");
            const doc = try std.fmt.allocPrint(
                allocator,
                "{{\"event_count\":{d},\"host_mutation\":false,\"schema\":\"xsprof/ui-session/v1\",\"source\":\"{s}\"}}",
                .{ rows, if (opts.live) "live" else "replay" },
            );
            try respond(&request, .ok, doc, "application/json");
            return;
        }
        if (std.mem.eql(u8, path, "/api/events")) {
            if (!opts.live) {
                try respond(&request, .not_found, "live stream not enabled\n", "text/plain");
                return;
            }
            var since: u64 = 0;
            if (lastEventId(&request)) |header| {
                since = std.fmt.parseInt(u64, header, 10) catch 0;
            } else if (queryParam(target, "since")) |query| {
                since = std.fmt.parseInt(u64, query, 10) catch 0;
            }
            const snap = try store.since(allocator, since);
            const body = try buildSse(allocator, snap);
            try respond(&request, .ok, body, "text/event-stream; charset=utf-8");
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
    var store: Store = .init();
    defer store.deinit();
    if (opts.live) {
        _ = std.Thread.spawn(.{}, worker, .{ io, &store }) catch return error.CaptureThreadFailed;
    }
    const address = try std.Io.net.IpAddress.parse(opts.addr, opts.port);
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    const journal = if (opts.live)
        ""
    else
        try readFile(io, allocator, opts.journal_path, 256 * 1024 * 1024);
    while (true) {
        const stream = listener.accept(io) catch continue;
        defer stream.close(io);
        handle(io, allocator, stream, journal, &store, opts) catch {};
    }
}

test "loopback guard and routes" {
    try std.testing.expect(isLoopback("127.0.0.1"));
    try std.testing.expect(isLoopback("::1"));
    try std.testing.expect(!isLoopback("0.0.0.0"));
    try std.testing.expectEqualStrings("main.js", assetPath("/main.js").?);
    try std.testing.expect(assetPath("/../etc/passwd") == null);
    try std.testing.expectEqualStrings("abc", queryParam("/x?token=abc", "token").?);
}
