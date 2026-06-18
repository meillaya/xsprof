const std = @import("std");

pub const FollowFlush = struct {
    enabled: bool,
    flushed_bytes: *usize,

    pub fn flush(self: *FollowFlush, bytes: []const u8) !void {
        if (!self.enabled) return;
        try flushNewOutput(bytes, self.flushed_bytes);
    }
};

pub fn readGitSha(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const head = std.Io.Dir.cwd().readFileAlloc(io, ".git/HEAD", allocator, .limited(1024)) catch {
        return allocator.dupe(u8, "unknown");
    };
    defer allocator.free(head);
    const trimmed = std.mem.trim(u8, head, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "ref: ")) {
        const ref_path = try std.fmt.allocPrint(allocator, ".git/{s}", .{std.mem.trim(u8, trimmed[5..], " \t\r\n")});
        defer allocator.free(ref_path);
        const ref_value = std.Io.Dir.cwd().readFileAlloc(io, ref_path, allocator, .limited(128)) catch {
            return allocator.dupe(u8, "unknown");
        };
        defer allocator.free(ref_value);
        return allocator.dupe(u8, std.mem.trim(u8, ref_value, " \t\r\n"));
    }
    return allocator.dupe(u8, trimmed);
}

fn flushNewOutput(bytes: []const u8, flushed_bytes: *usize) !void {
    if (flushed_bytes.* >= bytes.len) return;
    try writeStdout(bytes[flushed_bytes.*..]);
    flushed_bytes.* = bytes.len;
}

fn writeStdout(bytes: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), bytes);
}
