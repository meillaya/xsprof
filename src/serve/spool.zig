//! Tail the recorder's active segment into the HTTP live store. The reader is
//! bounded and never opens anything outside the manifest paths.

const std = @import("std");
const manifest_mod = @import("../recorder/manifest.zig");
const store_mod = @import("live_store.zig");

const poll_ms = 100;
const read_chunk = 256 * 1024;

fn sleep(io: std.Io) void {
    std.Io.sleep(io, .fromMilliseconds(poll_ms), .awake) catch {};
}

pub fn run(io: std.Io, dir: []const u8, store: *store_mod.Store) void {
    const allocator = std.heap.smp_allocator;
    const manifest_path = std.fmt.allocPrint(allocator, "{s}/manifest.json", .{dir}) catch return;
    defer allocator.free(manifest_path);
    var active_path: ?[]u8 = null;
    defer if (active_path) |path| allocator.free(path);
    var offset: u64 = 0;

    while (true) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const manifest = manifest_mod.read(io, arena.allocator(), manifest_path) catch null orelse {
            sleep(io);
            continue;
        };
        if (manifest.segments.len == 0) {
            sleep(io);
            continue;
        }
        const active = manifest.segments[manifest.segments.len - 1];
        const changed = active_path == null or !std.mem.eql(u8, active_path.?, active.path);
        if (changed) {
            if (active_path) |old| allocator.free(old);
            active_path = allocator.dupe(u8, active.path) catch null;
            offset = 0;
        }
        const path = active_path orelse {
            sleep(io);
            continue;
        };
        const full = std.fmt.allocPrint(arena.allocator(), "{s}/{s}", .{ dir, path }) catch {
            sleep(io);
            continue;
        };
        const file = std.Io.Dir.openFileAbsolute(io, full, .{}) catch {
            sleep(io);
            continue;
        };
        defer file.close(io);

        var chunk: [read_chunk]u8 = undefined;
        while (true) {
            const n = file.readPositionalAll(io, &chunk, offset) catch break;
            if (n == 0) break;
            store.append(chunk[0..n]);
            offset += n;
            if (n < chunk.len) break;
        }
        sleep(io);
    }
}
