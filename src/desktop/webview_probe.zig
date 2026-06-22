const std = @import("std");
const webview_c = @import("webview_c.zig");

const ProbeResult = struct {
    available: bool,
    detail: []const u8,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;

    const explicit_pkg_config_path = try hasEnvironmentVariable(allocator, init, "PKG_CONFIG_PATH");

    try out.print("desktop-webview-probe legacy_binding_probe={s}\n", .{webview_c.abi_name});
    try out.print("desktop-webview-probe action=dependency-check runtime=system-webview gui=not-started\n", .{});

    const gtk = try pkgConfig(allocator, io, "gtk+-3.0", explicit_pkg_config_path);
    defer if (gtk.available) allocator.free(gtk.detail);
    const webkit41 = try pkgConfig(allocator, io, "webkit2gtk-4.1", explicit_pkg_config_path);
    defer if (webkit41.available) allocator.free(webkit41.detail);
    const webkit40 = if (!webkit41.available) try pkgConfig(allocator, io, "webkit2gtk-4.0", explicit_pkg_config_path) else ProbeResult{ .available = false, .detail = "not checked" };
    defer if (webkit40.available) allocator.free(webkit40.detail);

    if (!gtk.available) {
        try printSkip(io, out, "pkg-config could not resolve gtk+-3.0");
    } else if (!webkit41.available and !webkit40.available) {
        try printSkip(io, out, "pkg-config could not resolve webkit2gtk-4.1 or webkit2gtk-4.0");
    } else {
        const webkit_name = if (webkit41.available) "webkit2gtk-4.1" else "webkit2gtk-4.0";
        const webkit_version = if (webkit41.available) webkit41.detail else webkit40.detail;
        try out.print("success webview dependency available gtk+-3.0={s} {s}={s}\n", .{ std.mem.trim(u8, gtk.detail, " \t\r\n"), webkit_name, std.mem.trim(u8, webkit_version, " \t\r\n") });
        try out.print("desktop-webview-probe note=system-webkitgtk-dependency-probe product-host=linux_webview_host.c legacy-c-abi-not-product-runtime\n", .{});
    }

    try stdout_writer.interface.flush();
}

fn printSkip(_: std.Io, out: *std.Io.Writer, reason: []const u8) !void {
    try out.print("dependency unavailable reason: {s}\n", .{reason});
    try out.print("actionable packages: {s}\n", .{webview_c.dependencyGuidance()});
    try out.print("desktop-webview-probe note=build-graph-healthy-runtime-gui-not-started\n", .{});
    try out.print("SKIP webview dependency unavailable: {s}\n", .{reason});
}

fn hasEnvironmentVariable(allocator: std.mem.Allocator, init: std.process.Init, name: []const u8) !bool {
    const value = init.minimal.environ.getAlloc(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableMissing => return false,
        else => |e| return e,
    };
    defer allocator.free(value);
    return value.len != 0;
}

fn pkgConfig(allocator: std.mem.Allocator, io: std.Io, name: []const u8, env_only: bool) !ProbeResult {
    const default_argv = [_][]const u8{ "pkg-config", "--modversion", name };
    const env_only_argv = [_][]const u8{ "pkg-config", "--env-only", "--modversion", name };
    const argv: []const []const u8 = if (env_only) &env_only_argv else &default_argv;
    const result = std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
        .expand_arg0 = .expand,
    }) catch |err| switch (err) {
        error.FileNotFound => return .{ .available = false, .detail = "pkg-config not found" },
        else => |e| return e,
    };
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        allocator.free(result.stdout);
        return .{ .available = false, .detail = "pkg-config returned non-zero" };
    }
    return .{ .available = true, .detail = result.stdout };
}
