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

    const dirty_snapshot = if (environ) |env| try envValue(allocator, env, "ZIG_SCHEDULER_DIRTY_SNAPSHOT_SHA") else null;
    defer if (dirty_snapshot) |value| allocator.free(value);
    const lifecycle_fixture = if (environ) |env| try envValue(allocator, env, "ZIG_SCHEDULER_MICROVM_LIFECYCLE_FIXTURE") else null;
    defer if (lifecycle_fixture) |value| allocator.free(value);

    return buildFromEnv(allocator, vars, inject_qemu, qemu_override, path_value, home_value, dirty_snapshot, lifecycle_fixture);
}

fn buildFromEnv(
    allocator: std.mem.Allocator,
    vars: []const commands.EnvVar,
    inject_qemu: bool,
    qemu_override: ?[]const u8,
    path_value: ?[]const u8,
    home_value: ?[]const u8,
    dirty_snapshot: ?[]const u8,
    lifecycle_fixture: ?[]const u8,
) !std.process.Environ.Map {
    var map = std.process.Environ.Map.init(allocator);
    errdefer map.deinit();
    for (vars) |env_var| try map.put(env_var.name, env_var.value);
    if (dirty_snapshot) |value| {
        if (isHexSha256(value)) try map.put("ZIG_SCHEDULER_DIRTY_SNAPSHOT_SHA", value);
    }
    if (lifecycle_fixture) |value| {
        if (std.mem.eql(u8, value, "1")) try map.put("ZIG_SCHEDULER_MICROVM_LIFECYCLE_FIXTURE", value);
    }
    if (inject_qemu) {
        if (try resolveQemuBinFromEnv(allocator, qemu_override, path_value, home_value)) |qemu_bin| {
            defer allocator.free(qemu_bin);
            try map.put("ZIG_SCHEDULER_QEMU_BIN", qemu_bin);
        }
    }
    return map;
}

fn isHexSha256(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |byte| {
        if (!std.ascii.isHex(byte)) return false;
    }
    return true;
}

fn resolveQemuBinFromEnv(
    allocator: std.mem.Allocator,
    qemu_override: ?[]const u8,
    path_value: ?[]const u8,
    home_value: ?[]const u8,
) !?[]const u8 {
    _ = path_value;
    _ = home_value;
    const io = std.Io.Threaded.global_single_threaded.io();
    if (qemu_override) |override_path| return try resolveExplicitQemuOverride(allocator, io, override_path);
    return null;
}

fn resolveExplicitQemuOverride(
    allocator: std.mem.Allocator,
    io: std.Io,
    override_path: []const u8,
) !?[]const u8 {
    if (!isSafeExplicitQemuPathSyntax(override_path)) return null;
    const canonical = std.Io.Dir.realPathFileAbsoluteAlloc(io, override_path, allocator) catch return null;
    errdefer allocator.free(canonical);
    if (!isTrustedCanonicalQemuPath(canonical)) {
        allocator.free(canonical);
        return null;
    }
    return canonical;
}

fn isSafeExplicitQemuPathSyntax(path: []const u8) bool {
    if (path.len == 0) return false;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return false;
    if (!std.fs.path.isAbsolute(path)) return false;
    if (!std.mem.eql(u8, std.fs.path.basename(path), qemu_name)) return false;
    if (hasDotPathComponent(path)) return false;
    if (hasPathPrefix(path, "/home/")) return false;
    if (hasPathPrefix(path, "/tmp/")) return false;
    if (hasPathPrefix(path, "/var/tmp/")) return false;
    if (hasPathPrefix(path, "/dev/shm/")) return false;
    if (std.mem.indexOf(u8, path, "/.zig-cache/") != null) return false;
    if (std.mem.indexOf(u8, path, "/.omo/") != null) return false;
    if (std.mem.indexOf(u8, path, "/.omx/") != null) return false;
    return true;
}

fn isTrustedCanonicalQemuPath(path: []const u8) bool {
    if (std.mem.eql(u8, path, "/usr/bin/" ++ qemu_name)) return true;
    if (std.mem.eql(u8, path, "/run/current-system/sw/bin/" ++ qemu_name)) return true;
    return isTrustedNixStoreQemuPath(path);
}

fn isTrustedNixStoreQemuPath(path: []const u8) bool {
    const prefix = "/nix/store/";
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    const rest = path[prefix.len..];
    const first_slash = std.mem.indexOfScalar(u8, rest, '/') orelse return false;
    if (first_slash == 0) return false;
    return std.mem.eql(u8, rest[first_slash..], "/bin/" ++ qemu_name);
}

fn hasDotPathComponent(path: []const u8) bool {
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return true;
    }
    return false;
}

fn hasPathPrefix(path: []const u8, prefix: []const u8) bool {
    return std.mem.eql(u8, path, prefix[0 .. prefix.len - 1]) or std.mem.startsWith(u8, path, prefix);
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

test "resolveQemuBinFromEnv ignores ambient PATH and HOME candidates" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    try makePath(&tmp.dir, "hostile-bin");
    try makePath(&tmp.dir, ".nix-profile/bin");
    try tmp.dir.writeFile(io, .{
        .sub_path = "hostile-bin/qemu-system-x86_64",
        .data = "#!/bin/sh\n",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = ".nix-profile/bin/qemu-system-x86_64",
        .data = "#!/bin/sh\n",
    });

    const home_abs = try tmpPath(std.testing.allocator, tmp, ".");
    defer std.testing.allocator.free(home_abs);
    const path_value = try tmpPath(std.testing.allocator, tmp, "hostile-bin");
    defer std.testing.allocator.free(path_value);

    const resolved = try resolveQemuBinFromEnv(std.testing.allocator, null, path_value, home_abs);
    try std.testing.expectEqual(@as(?[]const u8, null), resolved);
}

test "build injects only canonical trusted explicit qemu override into the daemon child env" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const qemu_bin = "/usr/bin/qemu-system-x86_64";
    const path_value = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";
    const vars = &.{ .{ .name = "PATH", .value = path_value }, .{ .name = "HOME", .value = "/tmp" } };

    var map = try buildFromEnv(std.testing.allocator, vars, true, qemu_bin, path_value, "/tmp", null, null);
    defer map.deinit();

    if (try resolveQemuBinFromEnv(std.testing.allocator, qemu_bin, path_value, "/tmp")) |resolved| {
        defer std.testing.allocator.free(resolved);
        try std.testing.expectEqualStrings(resolved, map.get("ZIG_SCHEDULER_QEMU_BIN").?);
    } else {
        try std.testing.expectEqual(@as(?[]const u8, null), map.get("ZIG_SCHEDULER_QEMU_BIN"));
    }
}

test "explicit qemu override syntax rejects traversal relative home and wrong basename" {
    try std.testing.expect(!isSafeExplicitQemuPathSyntax("qemu-system-x86_64"));
    try std.testing.expect(!isSafeExplicitQemuPathSyntax("/usr/../tmp/qemu-system-x86_64"));
    try std.testing.expect(!isSafeExplicitQemuPathSyntax("/usr/bin/./qemu-system-x86_64"));
    try std.testing.expect(!isSafeExplicitQemuPathSyntax("/home/operator/bin/qemu-system-x86_64"));
    try std.testing.expect(!isSafeExplicitQemuPathSyntax("/usr/bin/sh"));
    try std.testing.expect(isSafeExplicitQemuPathSyntax("/usr/bin/qemu-system-x86_64"));
    try std.testing.expect(isSafeExplicitQemuPathSyntax("/run/current-system/sw/bin/qemu-system-x86_64"));
    try std.testing.expect(isSafeExplicitQemuPathSyntax("/nix/store/abc123-qemu/bin/qemu-system-x86_64"));
}

test "canonical qemu override allowlist rejects symlink escape destinations" {
    try std.testing.expect(isTrustedCanonicalQemuPath("/usr/bin/qemu-system-x86_64"));
    try std.testing.expect(isTrustedCanonicalQemuPath("/run/current-system/sw/bin/qemu-system-x86_64"));
    try std.testing.expect(isTrustedCanonicalQemuPath("/nix/store/abc123-qemu/bin/qemu-system-x86_64"));
    try std.testing.expect(!isTrustedCanonicalQemuPath("/home/operator/.nix-profile/bin/qemu-system-x86_64"));
    try std.testing.expect(!isTrustedCanonicalQemuPath("/tmp/qemu-system-x86_64"));
    try std.testing.expect(!isTrustedCanonicalQemuPath("/usr/local/bin/qemu-system-x86_64"));
    try std.testing.expect(!isTrustedCanonicalQemuPath("/nix/store/abc123-qemu/sbin/qemu-system-x86_64"));
    try std.testing.expect(!isTrustedCanonicalQemuPath("/nix/store/abc123-qemu/bin/qemu-kvm"));
}

test "build rejects explicit qemu override from home and traversal paths" {
    const path_value = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";
    const vars = &.{ .{ .name = "PATH", .value = path_value }, .{ .name = "HOME", .value = "/home/operator" } };
    const rejected = [_][]const u8{
        "/home/operator/bin/qemu-system-x86_64",
        "/usr/../home/operator/bin/qemu-system-x86_64",
        "/usr/bin/../local/bin/qemu-system-x86_64",
        "/usr/bin/qemu-kvm",
    };
    for (rejected) |override_path| {
        var map = try buildFromEnv(std.testing.allocator, vars, true, override_path, path_value, "/home/operator", null, null);
        defer map.deinit();
        try std.testing.expectEqual(@as(?[]const u8, null), map.get("ZIG_SCHEDULER_QEMU_BIN"));
    }
}

test "build does not inject explicit qemu override from writable temp paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();

    try tmp.dir.writeFile(io, .{
        .sub_path = "qemu-system-x86_64",
        .data = "#!/bin/sh\n",
    });

    const tmp_abs = try tmpPath(std.testing.allocator, tmp, "qemu-system-x86_64");
    defer std.testing.allocator.free(tmp_abs);
    const path_value = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";
    const vars = &.{ .{ .name = "PATH", .value = path_value }, .{ .name = "HOME", .value = "/tmp" } };

    var map = try buildFromEnv(std.testing.allocator, vars, true, tmp_abs, path_value, "/tmp", null, null);
    defer map.deinit();

    try std.testing.expectEqual(@as(?[]const u8, null), map.get("ZIG_SCHEDULER_QEMU_BIN"));
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

test "build propagates validated dirty snapshot traceability hash" {
    const vars = &.{.{ .name = "PATH", .value = "/usr/bin" }};
    var map = try buildFromEnv(std.testing.allocator, vars, false, null, "/usr/bin", "/tmp", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", null);
    defer map.deinit();
    try std.testing.expectEqualStrings("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", map.get("ZIG_SCHEDULER_DIRTY_SNAPSHOT_SHA").?);

    var rejected = try buildFromEnv(std.testing.allocator, vars, false, null, "/usr/bin", "/tmp", "not-a-sha", null);
    defer rejected.deinit();
    try std.testing.expectEqual(@as(?[]const u8, null), rejected.get("ZIG_SCHEDULER_DIRTY_SNAPSHOT_SHA"));
}
