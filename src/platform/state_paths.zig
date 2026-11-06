//! Platform state/output paths, bounded settings persistence, and the packaged
//! demo fixture lookup. Portable `std.Io` file IO; the only OS convention is
//! XDG/HOME resolution (overridable with XSPROF_STATE_DIR / XSPROF_FIXTURES_DIR
//! for tests and packaged installs). Nothing here mutates host policy.

const std = @import("std");
const safety = @import("../core/safety.zig");

pub const settings_file = "ui-settings.json";
pub const max_settings_bytes = 64 * 1024;
pub const max_path_bytes = 512;

fn env(name: [:0]const u8) ?[]const u8 {
    if (std.c.getenv(name)) |value| return std.mem.span(value);
    return null;
}

pub fn stateDir(allocator: std.mem.Allocator) ![]u8 {
    if (env("XSPROF_STATE_DIR")) |value| return allocator.dupe(u8, value);
    if (env("XDG_STATE_HOME")) |value| return std.fmt.allocPrint(allocator, "{s}/xsprof", .{value});
    if (env("HOME")) |value| return std.fmt.allocPrint(allocator, "{s}/.local/state/xsprof", .{value});
    return error.NoStateDirectory;
}

pub fn settingsPath(allocator: std.mem.Allocator) ![]u8 {
    const dir = try stateDir(allocator);
    defer allocator.free(dir);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, settings_file });
}

/// Default recorder state dir (matches the recorder daemon default).
pub fn recorderFallbackDir(allocator: std.mem.Allocator) ![]u8 {
    return stateDir(allocator);
}

pub fn exportsDir(allocator: std.mem.Allocator) ![]u8 {
    const dir = try stateDir(allocator);
    defer allocator.free(dir);
    return std.fmt.allocPrint(allocator, "{s}/exports", .{dir});
}

/// Reads ui-settings.json. A missing file is null (first run); malformed or
/// oversized data is also null so a corrupt file cannot brick the console.
pub fn loadSettings(io: std.Io, allocator: std.mem.Allocator) !?[]u8 {
    const path = try settingsPath(allocator);
    defer allocator.free(path);
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io);
    var buffer: [16 * 1024]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    const data = reader.interface.allocRemaining(allocator, .limited(max_settings_bytes)) catch |err| switch (err) {
        error.StreamTooLong => return null,
        else => return err,
    };
    return data;
}

/// Atomic settings write (temp + rename) under the state dir.
pub fn saveSettings(io: std.Io, allocator: std.mem.Allocator, data: []const u8) !void {
    const dir = try stateDir(allocator);
    defer allocator.free(dir);
    try std.Io.Dir.cwd().createDirPath(io, dir);
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, settings_file });
    defer allocator.free(path);
    const temp = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(temp);
    const file = try std.Io.Dir.createFileAbsolute(io, temp, .{});
    var write_buffer: [16 * 1024]u8 = undefined;
    var writer = file.writer(io, &write_buffer);
    errdefer file.close(io);
    try writer.interface.writeAll(data);
    try writer.interface.flush();
    try file.sync(io);
    file.close(io);
    try std.Io.Dir.renameAbsolute(temp, path, io);
}

/// Packaged bundled capture used by Effect.load_demo. Checks an explicit
/// fixtures root first, then the source tree and XDG install locations.
pub fn demoFixture(io: std.Io, allocator: std.mem.Allocator) ![]u8 {
    if (env("XSPROF_FIXTURES_DIR")) |base| {
        const full = try std.fmt.allocPrint(allocator, "{s}/ui/design/demo.json", .{base});
        if (fileExists(io, full)) return full;
        allocator.free(full);
    }
    const candidates = [_][]const u8{
        "fixtures/ui/design/demo.json",
        "/usr/share/xsprof/fixtures/ui/design/demo.json",
        "/usr/local/share/xsprof/fixtures/ui/design/demo.json",
    };
    for (candidates) |candidate| {
        if (fileExists(io, candidate)) return allocator.dupe(u8, candidate);
    }
    return error.DemoFixtureMissing;
}

fn fileExists(io: std.Io, path: []const u8) bool {
    const file = if (path.len != 0 and path[0] == '/')
        std.Io.Dir.openFileAbsolute(io, path, .{}) catch return false
    else
        std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

fn startsWithBoundary(path: []const u8, prefix: []const u8) bool {
    if (prefix.len == 0 or path.len < prefix.len) return false;
    if (!std.mem.eql(u8, path[0..prefix.len], prefix)) return false;
    return path.len == prefix.len or path[prefix.len] == '/' or prefix[prefix.len - 1] == '/';
}

/// True when an export target is inside the user state dir, HOME, or /tmp, and
/// has no parent-traversal components. Relative paths must be safe relatives.
pub fn pathIsWritableTarget(allocator: std.mem.Allocator, path: []const u8) bool {
    if (path.len == 0 or path.len > max_path_bytes) return false;
    if (std.mem.indexOf(u8, path, "..") != null) return false;
    if (path[0] != '/') return safety.isSafeRelative(path);
    if (env("HOME")) |home| if (startsWithBoundary(path, home)) return true;
    if (env("XSPROF_STATE_DIR")) |state| if (startsWithBoundary(path, state)) return true;
    const state = stateDir(allocator) catch return startsWithBoundary(path, "/tmp/");
    defer allocator.free(state);
    if (startsWithBoundary(path, state)) return true;
    return startsWithBoundary(path, "/tmp/");
}

/// Resolves an export directory: empty means the state exports dir, otherwise
/// the caller-selected recorder/output dir must pass the writability check.
pub fn exportDir(allocator: std.mem.Allocator, requested: []const u8) ![]u8 {
    if (requested.len == 0) return exportsDir(allocator);
    if (!pathIsWritableTarget(allocator, requested)) return error.UnsafeExportPath;
    return allocator.dupe(u8, requested);
}

/// Absolute or cwd-relative file creation used by exporters.
pub fn createOutputFile(io: std.Io, path: []const u8) !std.Io.File {
    if (path.len != 0 and path[0] == '/') return std.Io.Dir.createFileAbsolute(io, path, .{});
    return std.Io.Dir.cwd().createFile(io, path, .{});
}

/// Creates the parent directory of `path` (absolute or relative).
pub fn ensureParentDir(io: std.Io, path: []const u8) !void {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return;
    if (slash == 0) return;
    const dir = path[0..slash];
    if (dir.len != 0 and dir[0] == '/') {
        try std.Io.Dir.cwd().createDirPath(io, dir);
    } else {
        try std.Io.Dir.cwd().createDirPath(io, dir);
    }
}

test "state paths honor overrides and reject traversal" {
    // Pure checks that do not depend on HOME existing.
    try std.testing.expect(!pathIsWritableTarget(std.testing.allocator, ""));
    try std.testing.expect(!pathIsWritableTarget(std.testing.allocator, "../escape.ndjson"));
    try std.testing.expect(!pathIsWritableTarget(std.testing.allocator, "/etc/passwd"));
    try std.testing.expect(pathIsWritableTarget(std.testing.allocator, "exports/journal.ndjson"));
    const dir = exportDir(std.testing.allocator, "") catch return error.TestUnexpectedResult;
    defer std.testing.allocator.free(dir);
    try std.testing.expect(std.mem.endsWith(u8, dir, "exports"));
}
