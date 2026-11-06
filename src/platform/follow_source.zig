//! Stoppable recorder-directory tail for the native live controllers.
//!
//! Recorder segments are compact `.xsraw` (v1) or legacy `.ndjson`. Compact
//! segments go through `recorder/segment_reader.zig` (`Reader.refresh`/`next`)
//! and are re-serialized as canonical `xsprof/event/v1` NDJSON lines into the
//! bounded live feed; NDJSON segments keep a byte-offset line tail. Missing,
//! rotated, unknown-codec, and corrupt segments produce explicit loss markers
//! instead of publishing garbage. No serve/spool files are modified.

const std = @import("std");
const event_mod = @import("../core/event.zig");
const manifest_mod = @import("../recorder/manifest.zig");
const segment_reader = @import("../recorder/segment_reader.zig");
const live_feed = @import("../stream/live_feed.zig");
const live_mod = @import("../app/design/live.zig");

const poll_ms = 100;
const read_chunk = 128 * 1024;
const max_partial = 1024 * 1024;
const max_line = 1024 * 1024;
const max_segments = 64;
const max_events_per_poll = 4096;

pub const Source = struct {
    allocator: std.mem.Allocator = undefined,
    io: std.Io = undefined,
    dir: []const u8 = "",
    feed: ?*live_feed.Store = null,
    thread: ?std.Thread = null,
    stop_flag: std.atomic.Value(bool) = .init(false),
    events: std.atomic.Value(u64) = .init(0),
    lost: std.atomic.Value(u64) = .init(0),
    failed: std.atomic.Value(bool) = .init(false),
    dir_buf: [512]u8 = @splat(0),

    pub fn source(self: *Source) live_mod.Source {
        return .{ .context = @ptrCast(self), .vtable = &vtable };
    }

    /// Starts the tail thread directly (used by the Linux recording source,
    /// which owns a second thread for the recorder daemon).
    pub fn begin(self: *Source, allocator: std.mem.Allocator, io: std.Io, feed: *live_feed.Store, dir: []const u8) bool {
        if (dir.len == 0 or dir.len > self.dir_buf.len) return false;
        self.allocator = allocator;
        self.io = io;
        self.feed = feed;
        @memcpy(self.dir_buf[0..dir.len], dir[0..dir.len]);
        self.dir = self.dir_buf[0..dir.len];
        self.stop_flag.store(false, .release);
        self.failed.store(false, .release);
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch {
            self.feed = null;
            return false;
        };
        return true;
    }

    fn startImpl(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        io: std.Io,
        feed: *live_feed.Store,
        options: live_mod.SourceOptions,
    ) live_mod.StartResult {
        _ = options;
        const self: *Source = @ptrCast(@alignCast(ctx));
        if (!self.begin(allocator, io, feed, self.dir)) {
            return .{ .unavailable = .{ .state = .refuse, .reason = "recorder tail could not start" } };
        }
        return .running;
    }

    pub fn stop(self: *Source) void {
        self.stop_flag.store(true, .release);
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        self.feed = null;
    }

    pub fn stats(self: *const Source) live_mod.SourceStats {
        return .{
            .events = self.events.load(.acquire),
            .lost = self.lost.load(.acquire),
            .failed = self.failed.load(.acquire),
        };
    }

    fn stopImpl(ctx: *anyopaque) void {
        const self: *Source = @ptrCast(@alignCast(ctx));
        self.stop();
    }

    fn tickImpl(_: *anyopaque, _: std.Io) void {}

    fn statsImpl(ctx: *anyopaque) live_mod.SourceStats {
        const self: *Source = @ptrCast(@alignCast(ctx));
        return .{
            .events = self.events.load(.acquire),
            .lost = self.lost.load(.acquire),
            .failed = self.failed.load(.acquire),
        };
    }

    fn sleep(io: std.Io) void {
        std.Io.sleep(io, .fromMilliseconds(poll_ms), .awake) catch {};
    }

    fn openSegment(io: std.Io, path: []const u8) !std.Io.File {
        if (path.len != 0 and path[0] == '/') return std.Io.Dir.openFileAbsolute(io, path, .{});
        return std.Io.Dir.cwd().openFile(io, path, .{});
    }

    fn emitMarker(self: *Source, io: std.Io, feed: *live_feed.Store, detail_text: []const u8) void {
        var buffer: [512]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        event_mod.writeJson(&writer, .{
            .kind = .marker,
            .ts_ns = @intCast(@max(0, std.Io.Clock.now(.awake, io).nanoseconds)),
            .cpu = -1,
            .detail = detail_text,
        }) catch return;
        writer.writeByte('\n') catch return;
        feed.append(writer.buffered());
        _ = self.lost.fetchAdd(1, .monotonic);
    }

    fn emitEvent(self: *Source, io: std.Io, feed: *live_feed.Store, entry: event_mod.RawEvent, scratch: *[4096]u8) void {
        var writer = std.Io.Writer.fixed(scratch);
        event_mod.writeJson(&writer, entry) catch {
            self.emitMarker(io, feed, "sample_loss live_follow dropped=1 oversized_event");
            return;
        };
        writer.writeByte('\n') catch return;
        feed.append(writer.buffered());
        _ = self.events.fetchAdd(1, .monotonic);
    }

    fn feedBytes(
        self: *Source,
        allocator: std.mem.Allocator,
        io: std.Io,
        feed: *live_feed.Store,
        pending: *std.ArrayList(u8),
        bytes: []const u8,
    ) void {
        pending.appendSlice(allocator, bytes) catch {
            self.failed.store(true, .release);
            return;
        };
        if (pending.items.len > max_partial) {
            self.emitMarker(io, feed, "sample_loss live_follow dropped=1 partial_buffer");
            pending.clearRetainingCapacity();
        }
        while (std.mem.indexOfScalar(u8, pending.items, '\n')) |newline| {
            const line = pending.items[0 .. newline + 1];
            if (line.len > max_line) {
                self.emitMarker(io, feed, "sample_loss live_follow dropped=1 oversized_line");
            } else if (std.mem.indexOf(u8, line, "\"schema\":\"xsprof/event/v1\"") != null) {
                feed.append(line);
                _ = self.events.fetchAdd(1, .monotonic);
            }
            const remaining = pending.items.len - line.len;
            std.mem.copyForwards(u8, pending.items[0..remaining], pending.items[line.len..]);
            pending.shrinkRetainingCapacity(remaining);
        }
    }

    fn tailCompact(
        self: *Source,
        reader: *segment_reader.Reader,
        io: std.Io,
        feed: *live_feed.Store,
        scratch: *[4096]u8,
    ) void {
        reader.refresh() catch return;
        var emitted: usize = 0;
        while (emitted < max_events_per_poll) : (emitted += 1) {
            const entry = reader.next() catch {
                self.emitMarker(io, feed, "sample_loss live_follow dropped=1 corrupt_segment");
                return;
            };
            if (entry == null) break;
            self.emitEvent(io, feed, entry.?, scratch);
        }
        if (reader.status == .corrupt) {
            self.emitMarker(io, feed, "sample_loss live_follow dropped=1 corrupt_segment");
        }
    }

    fn run(self: *Source) void {
        const allocator = self.allocator;
        const io = self.io;
        const feed = self.feed orelse return;
        const manifest_path = std.fmt.allocPrint(allocator, "{s}/manifest.json", .{self.dir}) catch {
            self.failed.store(true, .release);
            return;
        };
        defer allocator.free(manifest_path);
        var offsets = std.StringHashMap(u64).init(allocator);
        defer {
            var cleanup = offsets.iterator();
            while (cleanup.next()) |entry| allocator.free(entry.key_ptr.*);
            offsets.deinit();
        }
        var readers = std.StringHashMap(*segment_reader.Reader).init(allocator);
        defer {
            var cleanup = readers.iterator();
            while (cleanup.next()) |entry| {
                entry.value_ptr.*.close();
                allocator.destroy(entry.value_ptr.*);
                allocator.free(entry.key_ptr.*);
            }
            readers.deinit();
        }
        var pending: std.ArrayList(u8) = .empty;
        defer pending.deinit(allocator);
        var scratch: [4096]u8 = undefined;

        while (!self.stop_flag.load(.acquire)) {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const maybe_manifest = manifest_mod.read(io, arena.allocator(), manifest_path) catch null;
            const manifest = maybe_manifest orelse {
                sleep(io);
                continue;
            };
            if (manifest.segments.len == 0) {
                sleep(io);
                continue;
            }
            var present = std.StringHashMap(void).init(arena.allocator());
            const limit = @min(manifest.segments.len, max_segments);
            for (manifest.segments[0..limit]) |segment| {
                present.put(segment.path, {}) catch continue;
                const full = std.fmt.allocPrint(arena.allocator(), "{s}/{s}", .{ self.dir, segment.path }) catch continue;
                switch (segment_reader.codecForPath(segment.path)) {
                    .compact_v1 => {
                        const entry = readers.getOrPut(segment.path) catch continue;
                        if (!entry.found_existing) {
                            const path_copy = allocator.dupe(u8, segment.path) catch {
                                _ = readers.remove(segment.path);
                                continue;
                            };
                            const reader = allocator.create(segment_reader.Reader) catch {
                                allocator.free(path_copy);
                                _ = readers.remove(segment.path);
                                continue;
                            };
                            reader.* = segment_reader.Reader.open(io, full) catch |err| {
                                allocator.destroy(reader);
                                allocator.free(path_copy);
                                _ = readers.remove(segment.path);
                                // A just-created/rotated segment can be shorter than a
                                // header for one poll; that is not data loss.
                                if (err == error.FileNotFound) {
                                    self.emitMarker(io, feed, "sample_loss live_follow dropped=1 missing_segment");
                                }
                                continue;
                            };
                            entry.key_ptr.* = path_copy;
                            entry.value_ptr.* = reader;
                        }
                        self.tailCompact(entry.value_ptr.*, io, feed, &scratch);
                    },
                    .ndjson => {
                        const entry = offsets.getOrPut(segment.path) catch continue;
                        if (!entry.found_existing) {
                            entry.key_ptr.* = allocator.dupe(u8, segment.path) catch {
                                _ = offsets.remove(segment.path);
                                continue;
                            };
                            entry.value_ptr.* = 0;
                        }
                        const file = openSegment(io, full) catch {
                            self.emitMarker(io, feed, "sample_loss live_follow dropped=1 missing_segment");
                            entry.value_ptr.* = 0;
                            continue;
                        };
                        defer file.close(io);
                        var chunk: [read_chunk]u8 = undefined;
                        while (true) {
                            const read = file.readPositionalAll(io, &chunk, entry.value_ptr.*) catch break;
                            if (read == 0) break;
                            self.feedBytes(allocator, io, feed, &pending, chunk[0..read]);
                            entry.value_ptr.* += read;
                            if (read < chunk.len) break;
                        }
                    },
                    .unknown => self.emitMarker(io, feed, "sample_loss live_follow dropped=1 unknown_codec"),
                }
            }
            // Drop tails for segments removed by retention; that is a real gap.
            var stale: std.ArrayList([]const u8) = .empty;
            var offset_iterator = offsets.iterator();
            while (offset_iterator.next()) |entry| {
                if (present.contains(entry.key_ptr.*)) continue;
                if (entry.value_ptr.* != 0) {
                    self.emitMarker(io, feed, "sample_loss live_follow dropped=1 retention_gap");
                }
                stale.append(arena.allocator(), entry.key_ptr.*) catch {};
            }
            for (stale.items) |key| {
                if (offsets.fetchRemove(key)) |removed| allocator.free(removed.key);
            }
            var reader_stale: std.ArrayList([]const u8) = .empty;
            var reader_iterator = readers.iterator();
            while (reader_iterator.next()) |entry| {
                if (present.contains(entry.key_ptr.*)) continue;
                self.emitMarker(io, feed, "sample_loss live_follow dropped=1 retention_gap");
                reader_stale.append(arena.allocator(), entry.key_ptr.*) catch {};
            }
            for (reader_stale.items) |key| {
                if (readers.fetchRemove(key)) |removed| {
                    removed.value.close();
                    allocator.destroy(removed.value);
                    allocator.free(removed.key);
                }
            }
            sleep(io);
        }
    }
};

const vtable: live_mod.VTable = .{
    .start = &Source.startImpl,
    .stop = &Source.stopImpl,
    .tick = &Source.tickImpl,
    .stats = &Source.statsImpl,
};
