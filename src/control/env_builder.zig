const std = @import("std");
const commands = @import("commands.zig");

const qemu_name = "qemu-system-x86_64";

pub fn build(
    allocator: std.mem.Allocator,
    vars: []const commands.EnvVar,
    inject_qemu: bool,
    environ: ?std.process.Environ,
) !std.process.Environ.Map {
    const qemu_override = if (environ) |env| try envValue(allocator, env, "ZIG_SCHEDULER_QEMU_BIN") else null;
    defer if (qemu_override) |value| allocator.free(value);

    const path_value = if (environ) |env| try envValue(allocator, env, "PATH") else null;
    defer if (path_value) |value| allocator.free(value);

    const home_value = if (environ) |env| try envValue(allocator, env, "HOME") else null;
    defer if (home_value) |value| allocator.free(value);

    return buildFromEnv(allocator, vars, inject_qemu, qemu_override, path_value, home_value);
}

fn buildFromEnv(
    allocator: std.mem.Allocator,
    vars: []const commands.EnvVar,
    inject_qemu: bool,
    qemu_override: ?[]const u8,
    path_value: ?[]const u8,
    home_value: ?[]const u8,
) !std.process.Environ.Map {
    var map = std.process.Environ.Map.init(allocator);
    errdefer map.deinit();
    for (vars) |env_var| try map.put(env_var.name, env_var.value);
    if (inject_qemu) {
        if (try resolveQemuBinFromEnv(allocator, qemu_override, path_value, home_value)) |qemu_bin| {
            defer allocator.free(qemu_bin);
            try map.put("ZIG_SCHEDULER_QEMU_BIN", qemu_bin);
        }
    }
    return map;
}

fn resolveQemuBinFromEnv(
    allocator: std.mem.Allocator,
    qemu_override: ?[]const u8,
    path_value: ?[]const u8,
    home_value: ?[]const u8,
) !?[]const u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    if (qemu_override) |override_path| {
        if (try probeExecutable(allocator, io, override_path)) |resolved| return resolved;
    }
    if (path_value) |path| {
        if (try resolveFromPath(allocator, io, path)) |resolved| return resolved;
    }
    if (home_value) |home| {
        if (try resolveFromHome(allocator, io, home)) |resolved| return resolved;
    }
    return null;
}

fn resolveFromPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    path_value: []const u8,
) !?[]const u8 {
    var dirs = std.mem.splitScalar(u8, path_value, ':');
    while (dirs.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, qemu_name });
        defer allocator.free(candidate);
        if (try probeExecutable(allocator, io, candidate)) |resolved| return resolved;
    }
    return null;
}

fn resolveFromHome(
    allocator: std.mem.Allocator,
    io: std.Io,
    home_value: []const u8,
) !?[]const u8 {
    const candidate = try std.fmt.allocPrint(allocator, "{s}/.nix-profile/bin/{s}", .{ home_value, qemu_name });
    defer allocator.free(candidate);
    return try probeExecutable(allocator, io, candidate);
}

fn probeExecutable(
    allocator: std.mem.Allocator,
    io: std.Io,
    absolute_path: []const u8,
) !?[]const u8 {
    const file = std.Io.Dir.openFileAbsolute(io, absolute_path, .{}) catch return null;
    file.close(io);
    return try allocator.dupe(u8, absolute_path);
}

fn envValue(
    allocator: std.mem.Allocator,
    environ: std.process.Environ,
    key: []const u8,
) !?[]const u8 {
    return environ.getAlloc(allocator, key) catch |err| switch (err) {
        error.EnvironmentVariableMissing => return null,
        else => |e| return e,
    };
}

test "resolveQemuBinFromEnv falls back to HOME when PATH is sanitized" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    try makePath(&tmp.dir, ".nix-profile/bin");
    try tmp.dir.writeFile(io, .{
        .sub_path = ".nix-profile/bin/qemu-system-x86_64",
        .data = "#!/bin/sh\n",
    });

    const home_abs = try tmpPath(std.testing.allocator, tmp, ".");
    defer std.testing.allocator.free(home_abs);
    const sanitized_path = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";

    const resolved = try resolveQemuBinFromEnv(std.testing.allocator, null, sanitized_path, home_abs);
    try std.testing.expect(resolved != null);
    defer std.testing.allocator.free(resolved.?);
    try std.testing.expect(std.mem.endsWith(u8, resolved.?, "/.nix-profile/bin/qemu-system-x86_64"));
}

test "build injects explicit qemu override into the daemon child env" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    try makePath(&tmp.dir, ".nix-profile/bin");
    try tmp.dir.writeFile(io, .{
        .sub_path = ".nix-profile/bin/qemu-system-x86_64",
        .data = "#!/bin/sh\n",
    });

    const home_abs = try tmpPath(std.testing.allocator, tmp, ".");
    defer std.testing.allocator.free(home_abs);
    const path_value = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";
    const vars = &.{ .{ .name = "PATH", .value = path_value }, .{ .name = "HOME", .value = "/tmp" } };

    var map = try buildFromEnv(std.testing.allocator, vars, true, null, path_value, home_abs);
    defer map.deinit();

    const expected = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/.nix-profile/bin/{s}",
        .{ home_abs, qemu_name },
    );
    defer std.testing.allocator.free(expected);

    try std.testing.expectEqualStrings(expected, map.get("ZIG_SCHEDULER_QEMU_BIN").?);
}

fn makePath(dir: *std.Io.Dir, sub_path: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var child = try dir.createDirPathOpen(io, sub_path, .{});
    child.close(io);
}

fn tmpPath(allocator: std.mem.Allocator, tmp: std.testing.TmpDir, sub_path: []const u8) ![]u8 {
    const relative = if (std.mem.eql(u8, sub_path, "."))
        try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path})
    else
        try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/{s}", .{ &tmp.sub_path, sub_path });
    defer allocator.free(relative);
    return std.Io.Dir.cwd().realPathFileAlloc(std.Io.Threaded.global_single_threaded.io(), relative, allocator);
}
