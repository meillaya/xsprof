//! Tail recorder segments into the HTTP live store. The reader tracks a byte
//! offset per segment, buffers partial lines, and reports rotation/retention
//! gaps explicitly instead of publishing a truncated JSON line.

const std = @import("std");
const event = @import("../core/event.zig");
const manifest_mod = @import("../recorder/manifest.zig");
const store_mod = @import("../stream/live_feed.zig");

const poll_ms = 100;
const read_chunk = 256 * 1024;
const max_partial = 1024 * 1024;
const max_line = 1024 * 1024;

fn sleep(io: std.Io) void {
    std.Io.sleep(io, .fromMilliseconds(poll_ms), .awake) catch {};
}

fn emitMarker(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: *store_mod.Store,
    detail: []const u8,
) void {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    event.writeJson(&writer, .{
        .kind = .marker,
        .ts_ns = @intCast(@max(0, std.Io.Clock.now(.awake, io).nanoseconds)),
        .cpu = -1,
        .detail = detail,
    }) catch return;
    writer.writeByte('\n') catch return;
    store.append(writer.buffered());
    _ = allocator;
}

fn feed(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: *store_mod.Store,
    pending: *std.ArrayList(u8),
    bytes: []const u8,
) !void {
    try pending.appendSlice(allocator, bytes);
    if (pending.items.len > max_partial) {
        emitMarker(io, allocator, store, "sample_loss live_spool dropped=1 partial_buffer");
        pending.clearRetainingCapacity();
    }
    while (std.mem.indexOfScalar(u8, pending.items, '\n')) |newline| {
        const line = pending.items[0 .. newline + 1];
        if (line.len > max_line) {
            emitMarker(io, allocator, store, "sample_loss live_spool dropped=1 oversized_line");
        } else {
            store.append(line);
        }
        const remaining = pending.items.len - line.len;
        std.mem.copyForwards(u8, pending.items[0..remaining], pending.items[line.len..]);
        pending.shrinkRetainingCapacity(remaining);
    }
}

pub fn run(io: std.Io, dir: []const u8, store: *store_mod.Store) void {
    const allocator = std.heap.smp_allocator;
    const manifest_path = std.fmt.allocPrint(allocator, "{s}/manifest.json", .{dir}) catch return;
    defer allocator.free(manifest_path);

    var offsets = std.StringHashMap(u64).init(allocator);
    defer {
        var it = offsets.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        offsets.deinit();
    }
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(allocator);

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

        var present = std.StringHashMap(void).init(arena.allocator());
        for (manifest.segments) |segment| {
            present.put(segment.path, {}) catch continue;
            const entry = offsets.getOrPut(segment.path) catch continue;
            if (!entry.found_existing) {
                entry.key_ptr.* = allocator.dupe(u8, segment.path) catch {
                    _ = offsets.remove(segment.path);
                    continue;
                };
                entry.value_ptr.* = 0;
            }
            const full = std.fmt.allocPrint(arena.allocator(), "{s}/{s}", .{ dir, segment.path }) catch continue;
            const file = std.Io.Dir.openFileAbsolute(io, full, .{}) catch {
                // A retained manifest entry that disappeared is a real gap.
                emitMarker(io, allocator, store, "sample_loss live_spool dropped=1 missing_segment");
                entry.value_ptr.* = 0;
                continue;
            };
            defer file.close(io);
            var chunk: [read_chunk]u8 = undefined;
            while (true) {
                const n = file.readPositionalAll(io, &chunk, entry.value_ptr.*) catch break;
                if (n == 0) break;
                feed(io, allocator, store, &pending, chunk[0..n]) catch {
                    emitMarker(io, allocator, store, "sample_loss live_spool dropped=1 store_full");
                    pending.clearRetainingCapacity();
                    break;
                };
                entry.value_ptr.* += n;
                if (n < chunk.len) break;
            }
        }

        // Drop offsets for segments that raw retention removed. Any unread
        // remainder is an explicit gap, not silently forgotten.
        var stale: std.ArrayList([]const u8) = .empty;
        var offset_it = offsets.iterator();
        while (offset_it.next()) |entry| {
            if (present.contains(entry.key_ptr.*)) continue;
            if (entry.value_ptr.* != 0) {
                emitMarker(io, allocator, store, "sample_loss live_spool dropped=1 retention_gap");
            }
            stale.append(arena.allocator(), entry.key_ptr.*) catch {};
        }
        for (stale.items) |key| {
            if (offsets.fetchRemove(key)) |removed| allocator.free(removed.key);
        }
        sleep(io);
    }
}

test "partial lines are buffered until newline" {
    var store = store_mod.Store.init();
    defer store.deinit();
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(std.testing.allocator);
    try feed(std.testing.io, std.testing.allocator, &store, &pending, "{\"a\":1}");
    try std.testing.expectEqual(@as(usize, 0), store.bytes.items.len);
    try feed(std.testing.io, std.testing.allocator, &store, &pending, "\n{\"b\":2}\n");
    try std.testing.expectEqualStrings(
        "{\"a\":1}\n{\"b\":2}\n",
        store.bytes.items,
    );
}
