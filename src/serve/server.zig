//! Loopback-only, read-only HTTP bridge. GET/HEAD only.
//! Replay mode serves a journal; live mode adds a downsampled perf stream and
//! an SSE endpoint. Nothing here mutates the host.

const std = @import("std");
const event = @import("../core/event.zig");
const live = @import("../capture/live.zig");
const Store = @import("../stream/live_feed.zig").Store;
const spool = @import("spool.zig");

const Writer = std.Io.Writer;

pub const Options = struct {
    addr: []const u8 = "127.0.0.1",
    port: u16 = 8787,
    journal_path: []const u8,
    assets_dir: []const u8 = "zig-out/web",
    token: []const u8,
    live: bool = false,
    live_stride: u32 = 80,
    live_dir: ?[]const u8 = null,
    recorder_dir: ?[]const u8 = null,
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
    if (std.mem.endsWith(u8, path, ".json")) return "application/json; charset=utf-8";
    return "application/octet-stream";
}

fn assetPath(path: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html")) return "index.html";
    inline for ([_][]const u8{
        "/main.js",                      "/gl.js",
        "/style.css",                    "/shaders/ui.vert.glsl",
        "/shaders/ui.frag.glsl",         "/assets/xsprof-web.wasm",
        "/assets/design-demo.json",      "/scenarios/healthy.json",
        "/scenarios/loss.json",          "/scenarios/empty.json",
        "/scenarios/scheduler-mix.json",
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
    const is_head = request.head.method == .HEAD;
    try request.respond(if (is_head) "" else body, .{
        .status = status,
        .keep_alive = false,
        .extra_headers = &.{
            .{ .name = "content-type", .value = content_type },
            .{ .name = "cache-control", .value = "no-store" },
            .{ .name = "x-content-type-options", .value = "nosniff" },
            .{ .name = "x-frame-options", .value = "DENY" },
            .{ .name = "referrer-policy", .value = "no-referrer" },
            .{
                .name = "content-security-policy",
                .value = "default-src 'none'; script-src 'self' 'wasm-unsafe-eval'; " ++
                    "style-src 'self'; img-src 'self' data:; connect-src 'self'; " ++
                    "font-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
            },
        },
    });
}

fn tokensEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |left, right| diff |= left ^ right;
    return diff == 0;
}

fn respondWithOffset(
    request: *std.http.Server.Request,
    body: []const u8,
    content_type: []const u8,
    offset: u64,
) !void {
    var offset_buf: [32]u8 = undefined;
    const offset_text = try std.fmt.bufPrint(&offset_buf, "{d}", .{offset});
    const is_head = request.head.method == .HEAD;
    try request.respond(if (is_head) "" else body, .{
        .status = .ok,
        .keep_alive = false,
        .extra_headers = &.{
            .{ .name = "content-type", .value = content_type },
            .{ .name = "cache-control", .value = "no-store" },
            .{ .name = "x-content-type-options", .value = "nosniff" },
            .{ .name = "x-frame-options", .value = "DENY" },
            .{ .name = "referrer-policy", .value = "no-referrer" },
            .{ .name = "x-xsprof-offset", .value = offset_text },
            .{
                .name = "content-security-policy",
                .value = "default-src 'none'; script-src 'self' 'wasm-unsafe-eval'; " ++
                    "style-src 'self'; img-src 'self' data:; connect-src 'self'; " ++
                    "font-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
            },
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

fn worker(io: std.Io, store: *Store, stride: u32) void {
    const allocator = std.heap.smp_allocator;
    const every = @max(1, stride);
    var capture: ?live.Capture = null;
    var last_capability: u64 = 0;
    var pending_dropped: u64 = 0;
    var last_loss_marker: u64 = 0;

    while (true) {
        if (capture == null) {
            capture = live.Capture.open(io, allocator, .{}) catch |capture_error| {
                appendCapability(io, store, "SKIP", @errorName(capture_error));
                std.Io.sleep(io, .fromMilliseconds(2000), .awake) catch {};
                continue;
            };
        }
        const current = &capture.?;
        _ = current.poll(100) catch {
            current.deinit();
            capture = null;
            appendCapability(io, store, "REFUSE", "live capture poll failed");
            std.Io.sleep(io, .fromMilliseconds(2000), .awake) catch {};
            continue;
        };
        var batch = current.take() catch {
            current.deinit();
            capture = null;
            appendCapability(io, store, "REFUSE", "live capture batch failed");
            std.Io.sleep(io, .fromMilliseconds(2000), .awake) catch {};
            continue;
        };
        defer batch.deinit();
        const now_ns = @as(u64, @intCast(@max(0, std.Io.Clock.now(.awake, io).nanoseconds)));
        if (last_capability == 0 or now_ns -| last_capability > 10 * std.time.ns_per_s) {
            appendCapability(io, store, "READY", "perf sched tracepoints active");
            last_capability = now_ns;
        }

        var allocating = Writer.Allocating.init(allocator);
        var dropped: usize = 0;
        var last_ts: u64 = 0;
        for (batch.events, 0..) |entry, index| {
            last_ts = entry.ts_ns;
            if (index % every != 0) {
                dropped += 1;
                continue;
            }
            event.writeJson(&allocating.writer, entry) catch continue;
            allocating.writer.writeByte('\n') catch continue;
        }
        pending_dropped += dropped;
        if (pending_dropped != 0 and
            (last_loss_marker == 0 or now_ns -| last_loss_marker > std.time.ns_per_s))
        {
            var detail_buf: [96]u8 = undefined;
            const detail = std.fmt.bufPrint(
                &detail_buf,
                "sample_loss live_downsample dropped={d}",
                .{pending_dropped},
            ) catch "sample_loss live_downsample";
            event.writeJson(&allocating.writer, .{
                .kind = .marker,
                .ts_ns = last_ts,
                .cpu = -1,
                .detail = detail,
            }) catch {};
            allocating.writer.writeByte('\n') catch {};
            pending_dropped = 0;
            last_loss_marker = now_ns;
        }
        const data = allocating.toOwnedSlice() catch {
            std.Io.sleep(io, .fromMilliseconds(100), .awake) catch {};
            continue;
        };
        defer allocator.free(data);
        store.append(data);
        if (batch.events.len == 0) {
            std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
        }
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
        if (!tokensEqual(token, opts.token)) {
            try respond(&request, .unauthorized, "invalid token\n", "text/plain");
            return;
        }
        if (std.mem.eql(u8, path, "/api/recorder")) {
            if (opts.recorder_dir) |dir| {
                const manifest_path = try std.fmt.allocPrint(allocator, "{s}/manifest.json", .{dir});
                const body = readFile(io, allocator, manifest_path, 4 * 1024 * 1024) catch {
                    try respond(&request, .not_found, "recorder manifest unavailable\n", "text/plain");
                    return;
                };
                try respond(&request, .ok, body, "application/json");
                return;
            }
            try respond(&request, .not_found, "recorder not attached\n", "text/plain");
            return;
        }
        if (std.mem.eql(u8, path, "/api/journal")) {
            if (opts.live) {
                const body = try store.snapshot(allocator);
                try respondWithOffset(&request, body, "application/x-ndjson", store.endOffset());
            } else {
                try respond(&request, .ok, journal, "application/x-ndjson");
            }
            return;
        }
        if (std.mem.eql(u8, path, "/api/meta")) {
            const body = if (opts.live) try store.snapshot(allocator) else journal;
            const rows = std.mem.count(u8, body, "\n");
            const offset = if (opts.live) store.endOffset() else 0;
            const doc = try std.fmt.allocPrint(
                allocator,
                "{{\"event_count\":{d},\"host_mutation\":false,\"offset\":{d},\"schema\":\"xsprof/ui-session/v1\",\"source\":\"{s}\"}}",
                .{ rows, offset, if (opts.live) "live" else "replay" },
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
    const body = readFile(io, allocator, full, 32 * 1024 * 1024) catch {
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
        if (opts.live_dir) |dir| {
            _ = std.Thread.spawn(.{}, spool.run, .{ io, dir, &store }) catch return error.CaptureThreadFailed;
        } else {
            _ = std.Thread.spawn(.{}, worker, .{ io, &store, opts.live_stride }) catch return error.CaptureThreadFailed;
        }
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
