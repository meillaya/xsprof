const std = @import("std");

pub const LaunchError = error{
    SystemWebViewUnavailable,
    HtmlStageFailed,
    HelperSpawnFailed,
    HelperExitedNonZero,
    InvalidStateDir,
};

pub fn run(allocator: std.mem.Allocator, io: std.Io, app_path: []const u8, state_dir: []const u8, daemon_path: []const u8, title: []const u8, html: []const u8) !void {
    try validateStateDirForWrite(io, state_dir);
    const helper_path = try helperPath(allocator, app_path);
    defer allocator.free(helper_path);
    const html_path = try stageHtml(allocator, io, state_dir, html);
    defer allocator.free(html_path);

    var child = std.process.spawn(io, .{
        .argv = &.{ helper_path, title, html_path, app_path, state_dir, daemon_path },
        .expand_arg0 = .no_expand,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch return LaunchError.HelperSpawnFailed;
    const term = child.wait(io) catch return LaunchError.HelperExitedNonZero;
    if (term != .exited or term.exited != 0) return LaunchError.HelperExitedNonZero;
}

fn helperPath(allocator: std.mem.Allocator, app_path: []const u8) ![]u8 {
    const dir = std.fs.path.dirname(app_path) orelse "zig-out/bin";
    return std.fs.path.join(allocator, &.{ dir, "zig-scheduler-live-vm-webview-host" });
}

fn stageHtml(allocator: std.mem.Allocator, io: std.Io, state_dir: []const u8, html: []const u8) ![]u8 {
    try validateStateDirForWrite(io, state_dir);
    var state = std.Io.Dir.cwd().createDirPathOpen(io, state_dir, .{
        .open_options = .{ .follow_symlinks = false },
    }) catch return LaunchError.HtmlStageFailed;
    defer state.close(io);
    try rejectExistingSymlink(io, state, "desktop-offline.html");
    const path = try std.fs.path.join(allocator, &.{ state_dir, "desktop-offline.html" });
    errdefer allocator.free(path);
    var file = state.createFile(io, "desktop-offline.html", .{ .truncate = true, .resolve_beneath = true }) catch return LaunchError.HtmlStageFailed;
    defer file.close(io);
    file.writeStreamingAll(io, html) catch return LaunchError.HtmlStageFailed;
    return path;
}

pub fn validateStateDir(path: []const u8) LaunchError!void {
    if (path.len == 0 or path.len > 240) return LaunchError.InvalidStateDir;
    for (path) |byte| {
        if (byte <= 0x20 or byte == 0x7f or byte == '=' or byte == '"' or byte == '\'' or byte == '`') return LaunchError.InvalidStateDir;
        switch (byte) {
            '$', '&', '|', ';', '<', '>', '(', ')', '\\' => return LaunchError.InvalidStateDir,
            else => {},
        }
    }
    if (std.fs.path.isAbsolute(path) and !isAllowedAbsoluteStateDir(path)) return LaunchError.InvalidStateDir;
    try validateStateDirSegments(path);
}

pub fn validateStateDirForWrite(io: std.Io, path: []const u8) LaunchError!void {
    try validateStateDir(path);
    try rejectSymlinkComponents(io, path);
}

fn isAllowedAbsoluteStateDir(path: []const u8) bool {
    return hasPathPrefix(path, "/tmp/zig-scheduler-live-vm-desktop") or
        hasPathPrefix(path, "/var/tmp/zig-scheduler-live-vm-desktop") or
        std.mem.startsWith(u8, path, "/tmp/zig-scheduler-live-controller-timeout-");
}

fn hasPathPrefix(path: []const u8, prefix: []const u8) bool {
    return std.mem.eql(u8, path, prefix) or
        (std.mem.startsWith(u8, path, prefix) and path.len > prefix.len and path[prefix.len] == '/');
}

fn validateStateDirSegments(path: []const u8) LaunchError!void {
    const segment_path = if (std.fs.path.isAbsolute(path)) path[1..] else path;
    var parts = std.mem.splitScalar(u8, segment_path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return LaunchError.InvalidStateDir;
        if (isSensitiveStateDirSegment(part)) return LaunchError.InvalidStateDir;
    }
}

fn isSensitiveStateDirSegment(part: []const u8) bool {
    return std.mem.eql(u8, part, "sys") or
        std.mem.eql(u8, part, "proc") or
        std.mem.eql(u8, part, "cgroup") or
        std.mem.eql(u8, part, "cgroups") or
        std.mem.eql(u8, part, "cpuset") or
        std.mem.eql(u8, part, "cpusets");
}

fn rejectSymlinkComponents(io: std.Io, path: []const u8) LaunchError!void {
    var checked_path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    if (path.len >= checked_path.len) return LaunchError.InvalidStateDir;

    var cursor: usize = 0;
    if (std.fs.path.isAbsolute(path)) {
        checked_path[0] = '/';
        cursor = 1;
    }

    const segment_path = if (std.fs.path.isAbsolute(path)) path[1..] else path;
    var parts = std.mem.splitScalar(u8, segment_path, '/');
    while (parts.next()) |part| {
        if (cursor > 0 and checked_path[cursor - 1] != '/') {
            if (cursor >= checked_path.len) return LaunchError.InvalidStateDir;
            checked_path[cursor] = '/';
            cursor += 1;
        }
        if (cursor + part.len >= checked_path.len) return LaunchError.InvalidStateDir;
        @memcpy(checked_path[cursor..][0..part.len], part);
        cursor += part.len;

        const current = checked_path[0..cursor];
        const stat = std.Io.Dir.cwd().statFile(io, current, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return LaunchError.InvalidStateDir,
        };
        if (stat.kind == .sym_link) return LaunchError.InvalidStateDir;
        if (stat.kind != .directory) return LaunchError.InvalidStateDir;
    }
}

fn rejectExistingSymlink(io: std.Io, dir: std.Io.Dir, path: []const u8) LaunchError!void {
    const stat = dir.statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return LaunchError.InvalidStateDir,
    };
    if (stat.kind == .sym_link) return LaunchError.InvalidStateDir;
}

test "desktop webview state dir validator accepts established safe roots" {
    inline for (.{
        "/tmp/zig-scheduler-live-vm-desktop/state",
        "/tmp/zig-scheduler-live-vm-desktop/task-03-state",
        "/tmp/zig-scheduler-live-controller-timeout-abcd",
        ".omo/evidence/f4-state-dir/state",
        ".omo/state/live-vm-desktop/state",
        "zig-out/live-vm-desktop/state",
        "evidence/lab/tui-e2e/live/daemon-state",
    }) |path| {
        try validateStateDir(path);
    }
}

test "desktop webview state dir validator refuses host-sensitive and traversal paths" {
    inline for (.{
        "/sys/fs/cgroup/zigsched-hostile",
        "/proc/sys/zigsched-hostile",
        "/sys/devices/system/cpu/cpuset-hostile",
        "/tmp/zig-scheduler-live-vm-desktop/../zigsched-hostile",
        "../zigsched-hostile",
        ".omo/evidence/../zigsched-hostile",
        "sys/fs/cgroup/zigsched-hostile",
        "proc/sys/zigsched-hostile",
        "safe/cgroup/zigsched-hostile",
        "safe/cpuset/zigsched-hostile",
        "/tmp/arbitrary-zigsched-hostile",
        "/var/lib/zigsched-hostile",
    }) |path| {
        try std.testing.expectError(LaunchError.InvalidStateDir, validateStateDir(path));
    }
}

test "desktop webview state dir write validator refuses symlink escape" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var path_buf: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, "/tmp/zig-scheduler-live-vm-desktop/zigtest-symlink-{d}", .{std.os.linux.getpid()});
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    var root_dir = try std.Io.Dir.cwd().createDirPathOpen(io, root, .{});
    defer root_dir.close(io);
    try root_dir.createDirPath(io, "allowed/ordinary");
    try root_dir.createDirPath(io, "outside");
    try root_dir.symLink(io, "../outside", "allowed/state-link", .{});

    const ordinary = try std.fs.path.join(std.testing.allocator, &.{ root, "allowed", "ordinary" });
    defer std.testing.allocator.free(ordinary);
    const link = try std.fs.path.join(std.testing.allocator, &.{ root, "allowed", "state-link" });
    defer std.testing.allocator.free(link);

    try validateStateDirForWrite(io, ordinary);
    try std.testing.expectError(LaunchError.InvalidStateDir, validateStateDirForWrite(io, link));
}
