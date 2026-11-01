//! A small ANSI live view for SSH use. It reads recorder segments, rebuilds a
//! bounded window through the same index as the UI, and prints once per tick.

const std = @import("std");
const event = @import("../core/event.zig");
const manifest_mod = @import("../recorder/manifest.zig");
const extract = @import("../recorder/extract.zig");
const metrics_mod = @import("../analyze/metrics.zig");

const Writer = std.Io.Writer;
const max_segment_bytes = 32 * 1024 * 1024;

pub const Options = struct {
    dir: []const u8,
    window_ms: u64 = 30_000,
    duration_ms: ?u64 = null,
    once: bool = false,
};

pub fn run(io: std.Io, allocator: std.mem.Allocator, opts: Options, out: *Writer) !void {
    const manifest_path = try std.fmt.allocPrint(allocator, "{s}/manifest.json", .{opts.dir});
    defer allocator.free(manifest_path);
    const manifest = (try manifest_mod.read(io, allocator, manifest_path)) orelse
        return error.NoRecorder;

    const started = std.Io.Clock.now(.awake, io).nanoseconds;
    while (true) {
        var frame_arena = std.heap.ArenaAllocator.init(allocator);
        defer frame_arena.deinit();
        const frame_allocator = frame_arena.allocator();
        const now_wall = @as(u64, @intCast(@max(0, std.Io.Clock.now(.real, io).nanoseconds)));
        const window_ns = std.math.mul(u64, opts.window_ms, std.time.ns_per_ms) catch std.math.maxInt(u64);
        const cutoff = now_wall -| window_ns;

        // Stream segments line by line. The index owns a copy of every task
        // name, so a 16 MiB segment does not stay resident after it is read.
        var index = metrics_mod.Index.init(frame_allocator);
        defer index.deinit();
        for (manifest.segments) |segment| {
            const end = if (segment.end_wall_ns == 0) now_wall else segment.end_wall_ns;
            if (end < cutoff) continue;
            const full = try std.fmt.allocPrint(frame_allocator, "{s}/{s}", .{ opts.dir, segment.path });
            const file = std.Io.Dir.openFileAbsolute(io, full, .{}) catch continue;
            defer file.close(io);
            var buffer: [64 * 1024]u8 = undefined;
            var reader = file.readerStreaming(io, &buffer);
            var file_arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer file_arena.deinit();
            const data = reader.interface.allocRemaining(
                file_arena.allocator(),
                .limited(max_segment_bytes),
            ) catch continue;
            var line_arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer line_arena.deinit();
            var lines = std.mem.splitScalar(u8, data, '\n');
            while (lines.next()) |raw_line| {
                const line = std.mem.trim(u8, raw_line, " \t\r");
                if (line.len == 0) continue;
                _ = line_arena.reset(.retain_capacity);
                const parsed = event.parseJson(line_arena.allocator(), line) catch
                    return error.InvalidJournal;
                var one = [_]event.RawEvent{parsed};
                try index.append(&one);
            }
        }
        const metrics = try index.snapshot(frame_allocator);
        try render(out, manifest, metrics, opts.window_ms);
        try out.flush();

        if (opts.once) return;
        const elapsed = std.Io.Clock.now(.awake, io).nanoseconds - started;
        if (opts.duration_ms) |duration| {
            if (elapsed >= @as(i96, @intCast(duration)) * std.time.ns_per_ms) return;
        }
        std.Io.sleep(io, .fromMilliseconds(1000), .awake) catch return;
    }
}

fn render(out: *Writer, manifest: manifest_mod.Manifest, metrics: metrics_mod.Metrics, window_ms: u64) !void {
    try out.writeAll("\x1b[2J\x1b[H");
    try out.print("xsprof watch  state={s}  window={d}ms  session={s}\n", .{
        @tagName(manifest.state),
        window_ms,
        manifest.session_id,
    });
    try out.print("switches={d} wakeups={d} migrations={d} faults={d}/{d} lost={d}\n", .{
        metrics.switches,
        metrics.wakeups,
        metrics.migrations,
        metrics.faults_minor,
        metrics.faults_major,
        metrics.lost,
    });
    try out.writeAll("CPU  busy_ms  idle_ms  switches\n");
    for (metrics.cpus) |cpu| {
        try out.print("{d:>3} {d:>8} {d:>8} {d:>8}\n", .{
            cpu.cpu,
            cpu.busy_us / 1000,
            cpu.idle_us / 1000,
            cpu.switches,
        });
    }
    try out.writeAll("\nTASK                 p95_wait  p99_wait  offcpu95  switches\n");
    var shown: usize = 0;
    for (metrics.tasks) |task| {
        if (task.is_self) continue;
        if (shown == 12) break;
        shown += 1;
        try out.print("{s:<20} {d:>8} {d:>9} {d:>9} {d:>8}\n", .{
            truncate(task.comm, 20),
            task.wait_p95_us / 1000,
            task.wait_p99_us / 1000,
            task.offcpu_p95_us / 1000,
            task.switches,
        });
    }
}

fn truncate(text: []const u8, width: usize) []const u8 {
    if (text.len <= width) return text;
    return text[0..width];
}
