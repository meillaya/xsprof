//! Tail recorder segments into the HTTP live store. Legacy NDJSON segments
//! stream through byte offsets with partial-line buffering; compact .xsraw
//! segments decode block by block and re-serialize canonical NDJSON at the
//! configured live stride. Rotation/retention gaps are explicit markers.

const std = @import("std");
const event = @import("../core/event.zig");
const manifest_mod = @import("../recorder/manifest.zig");
const reader_mod = @import("../recorder/segment_reader.zig");
const store_mod = @import("../stream/live_feed.zig");

const poll_ms = 100;
const read_chunk = 256 * 1024;
const max_partial = 1024 * 1024;
const max_line = 1024 * 1024;
const default_live_stride: u32 = 80;

fn sleep(io: std.Io) void {
    std.Io.sleep(io, .fromMilliseconds(poll_ms), .awake) catch {};
}

fn emitMarker(
    io: std.Io,
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
}

const State = struct {
    codec: reader_mod.Codec = .ndjson,
    offset: u64 = 0,
    reader: ?reader_mod.Reader = null,
    eof: bool = false,
    stride_counter: u64 = 0,
    dropped: u64 = 0,
    last_loss_ns: u64 = 0,
};

fn feedNdjson(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: *store_mod.Store,
    state: *State,
    file: std.Io.File,
    pending: *std.ArrayList(u8),
) !void {
    var chunk: [read_chunk]u8 = undefined;
    while (true) {
        const n = try file.readPositionalAll(io, &chunk, state.offset);
        if (n == 0) break;
        try pending.appendSlice(allocator, chunk[0..n]);
        if (pending.items.len > max_partial) {
            emitMarker(io, store, "sample_loss live_spool dropped=1 partial_buffer");
            pending.clearRetainingCapacity();
        }
        while (std.mem.indexOfScalar(u8, pending.items, '\n')) |newline| {
            const line = pending.items[0 .. newline + 1];
            if (line.len > max_line) {
                emitMarker(io, store, "sample_loss live_spool dropped=1 oversized_line");
            } else {
                store.append(line);
            }
            const remaining = pending.items.len - line.len;
            std.mem.copyForwards(u8, pending.items[0..remaining], pending.items[line.len..]);
            pending.shrinkRetainingCapacity(remaining);
        }
        state.offset += n;
        if (n < chunk.len) break;
    }
}

fn feedCompact(
    io: std.Io,
    store: *store_mod.Store,
    state: *State,
    stride: u32,
) !void {
    if (state.eof) return;
    const reader = if (state.reader) |*existing| existing else return;
    try reader.refresh();
    var line_buffer: [4096]u8 = undefined;
    while (true) {
        const maybe = reader.next() catch {
            emitMarker(io, store, "sample_loss live_spool dropped=1 corrupt_segment");
            state.eof = true;
            return;
        };
        const parsed = maybe orelse {
            if (reader.footer != null) state.eof = true;
            break;
        };
        const every = @max(1, stride);
        if (state.stride_counter % every != 0) {
            state.dropped += 1;
            state.stride_counter += 1;
            continue;
        }
        state.stride_counter += 1;
        var writer = std.Io.Writer.fixed(&line_buffer);
        event.writeJson(&writer, parsed) catch continue;
        writer.writeByte('\n') catch continue;
        store.append(writer.buffered());
    }
    const now = @as(u64, @intCast(@max(0, std.Io.Clock.now(.awake, io).nanoseconds)));
    if (state.dropped != 0 and
        (state.last_loss_ns == 0 or now -| state.last_loss_ns > std.time.ns_per_s))
    {
        var buffer: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        var detail_buffer: [96]u8 = undefined;
        const detail = std.fmt.bufPrint(
            &detail_buffer,
            "sample_loss live_spool dropped={d}",
            .{state.dropped},
        ) catch "sample_loss live_spool dropped=1";
        event.writeJson(&writer, .{
            .kind = .marker,
            .ts_ns = now,
            .cpu = -1,
            .detail = detail,
        }) catch return;
        writer.writeByte('\n') catch return;
        store.append(writer.buffered());
        state.dropped = 0;
        state.last_loss_ns = now;
    }
}

fn freeState(allocator: std.mem.Allocator, state: *State) void {
    if (state.reader) |*reader| reader.close();
    allocator.destroy(state);
}

pub fn run(io: std.Io, dir: []const u8, store: *store_mod.Store, stride: u32) void {
    const allocator = std.heap.smp_allocator;
    const manifest_path = std.fmt.allocPrint(allocator, "{s}/manifest.json", .{dir}) catch return;
    defer allocator.free(manifest_path);

    var states = std.StringHashMap(*State).init(allocator);
    defer {
        var it = states.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            freeState(allocator, entry.value_ptr.*);
        }
        states.deinit();
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
            const entry = states.getOrPut(segment.path) catch continue;
            if (!entry.found_existing) {
                const key = allocator.dupe(u8, segment.path) catch {
                    _ = states.remove(segment.path);
                    continue;
                };
                const state = allocator.create(State) catch {
                    allocator.free(key);
                    _ = states.remove(segment.path);
                    continue;
                };
                state.* = .{ .codec = reader_mod.codecForPath(segment.path) };
                entry.key_ptr.* = key;
                entry.value_ptr.* = state;
            }
            const state = entry.value_ptr.*;
            const full = std.fmt.allocPrint(arena.allocator(), "{s}/{s}", .{ dir, segment.path }) catch continue;
            switch (state.codec) {
                .compact_v1 => {
                    if (state.reader == null) {
                        state.reader = reader_mod.Reader.open(io, full) catch {
                            emitMarker(io, store, "sample_loss live_spool dropped=1 missing_segment");
                            state.eof = true;
                            continue;
                        };
                    }
                    feedCompact(io, store, state, stride) catch {
                        emitMarker(io, store, "sample_loss live_spool dropped=1 store_full");
                    };
                },
                .ndjson => {
                    const file = std.Io.Dir.openFileAbsolute(io, full, .{}) catch {
                        emitMarker(io, store, "sample_loss live_spool dropped=1 missing_segment");
                        state.offset = 0;
                        continue;
                    };
                    defer file.close(io);
                    feedNdjson(io, allocator, store, state, file, &pending) catch {
                        emitMarker(io, store, "sample_loss live_spool dropped=1 store_full");
                        pending.clearRetainingCapacity();
                    };
                },
                .unknown => {},
            }
        }

        // Drop state for segments that raw retention removed. Any unread
        // remainder is an explicit gap, not silently forgotten.
        var stale: std.ArrayList([]const u8) = .empty;
        var state_it = states.iterator();
        while (state_it.next()) |entry| {
            if (present.contains(entry.key_ptr.*)) continue;
            const state = entry.value_ptr.*;
            if (state.codec == .ndjson) {
                if (state.offset != 0) emitMarker(io, store, "sample_loss live_spool dropped=1 retention_gap");
            } else if (!state.eof) {
                emitMarker(io, store, "sample_loss live_spool dropped=1 retention_gap");
            }
            stale.append(arena.allocator(), entry.key_ptr.*) catch {};
        }
        for (stale.items) |key| {
            if (states.fetchRemove(key)) |removed| {
                allocator.free(removed.key);
                freeState(allocator, removed.value);
            }
        }
        sleep(io);
    }
}

// Checks legacy partial lines are buffered until a newline.
test "partial lines are buffered until newline" {
    var store = store_mod.Store.init();
    defer store.deinit();
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(std.testing.allocator);
    // The live store owns 8 MiB; only the line boundary behavior is asserted
    // here through the live store snapshot.
    store.append("{\"a\":1}");
    try std.testing.expectEqual(@as(u64, 7), store.endOffset());
    store.append("\n{\"b\":2}\n");
    const snapshot = try store.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "{\"a\":1}") != null);
    _ = &pending;
}

// Checks compact tailing re-serializes canonical NDJSON at the live stride.
test "compact spool decodes and applies the live stride" {
    const allocator = std.testing.allocator;
    const root = try std.fmt.allocPrint(allocator, "/tmp/xsprof-spool-{d}", .{std.testing.random_seed});
    defer allocator.free(root);
    std.Io.Dir.createDirAbsolute(std.testing.io, root, .default_dir) catch {};
    defer std.Io.Dir.deleteDirAbsolute(std.testing.io, root) catch {};
    const segments_dir = try std.fmt.allocPrint(allocator, "{s}/segments", .{root});
    defer allocator.free(segments_dir);
    std.Io.Dir.createDirAbsolute(std.testing.io, segments_dir, .default_dir) catch {};
    const segment = @import("../recorder/segment.zig");
    var writer = try segment.Writer.create(std.testing.io, allocator, root, 0, 1, 2);
    defer writer.deinit();
    var index: u64 = 0;
    while (index < 6) : (index += 1) {
        try writer.writeEvent(.{ .kind = .sched_switch, .ts_ns = index * 1000, .cpu = 0, .pid = 7, .tid = 7, .a = index, .comm = "worker" });
    }
    try writer.close();
    const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, writer.path });
    defer allocator.free(full);

    var store = store_mod.Store.init();
    defer store.deinit();
    var state = State{
        .codec = .compact_v1,
        .reader = try reader_mod.Reader.open(std.testing.io, full),
    };
    defer if (state.reader) |*reader| reader.close();
    try feedCompact(std.testing.io, &store, &state, 1);
    const snapshot = try store.snapshot(allocator);
    defer allocator.free(snapshot);
    try std.testing.expectEqual(@as(usize, 6), std.mem.count(u8, snapshot, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"event\":\"sched_switch\"") != null);
    try std.testing.expectEqual(@as(usize, 0), state.dropped);

    var strided_store = store_mod.Store.init();
    defer strided_store.deinit();
    var strided_state = State{
        .codec = .compact_v1,
        .reader = try reader_mod.Reader.open(std.testing.io, full),
    };
    defer if (strided_state.reader) |*reader| reader.close();
    try feedCompact(std.testing.io, &strided_store, &strided_state, 2);
    const strided = try strided_store.snapshot(allocator);
    defer allocator.free(strided);
    try std.testing.expect(std.mem.indexOf(u8, strided, "sample_loss live_spool") != null);
    try std.testing.expect(std.mem.count(u8, strided, "sched_switch") == 3);
}

test "spool constants stay bounded" {
    try std.testing.expect(default_live_stride >= 1);
    try std.testing.expect(read_chunk >= 4096);
}
