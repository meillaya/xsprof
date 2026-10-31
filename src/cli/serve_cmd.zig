const std = @import("std");
const server = @import("../serve/server.zig");

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
        } else if (std.mem.eql(u8, arg, "--assets-dir") and i + 1 < args.len) {
            i += 1;
            assets_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--addr") and i + 1 < args.len) {
            i += 1;
            addr = args[i];
        } else if (std.mem.eql(u8, arg, "--live")) {
            live_capture = true;
        }
    }
    if (!std.mem.eql(u8, addr, "127.0.0.1") and !std.mem.eql(u8, addr, "::1")) {
        try err.writeAll("serve: refusing non-loopback address\n");
        return 2;
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
    try out.print("http://{s}:{d}/?token={s}\n", .{ addr, port, token[0..] });
    try out.flush();
    server.run(io, allocator, .{
        .addr = addr,
        .port = port,
        .journal_path = journal_path,
        .assets_dir = assets_dir,
        .token = token[0..],
        .live = live_capture,
    }) catch |serve_error| {
        try err.print("serve: {s}\n", .{@errorName(serve_error)});
        return 1;
    };
    return 0;
}
