//! Shared terminal dashboard for `xsprof top` and the recorder watch view.

const std = @import("std");
const metrics_mod = @import("../analyze/metrics.zig");

const Writer = std.Io.Writer;

pub const Options = struct {
    clear: bool = false,
    top_n: usize = 12,
    window_ms: u64 = 0,
};

fn truncate(text: []const u8, width: usize) []const u8 {
    if (text.len <= width) return text;
    return text[0..width];
}

pub fn render(
    out: *Writer,
    title: []const u8,
    metrics: metrics_mod.Metrics,
    opts: Options,
) !void {
    if (opts.clear) try out.writeAll("\x1b[2J\x1b[H");
    try out.print("{s}  window={d}ms  events={d}\n", .{ title, opts.window_ms, metrics.events });
    try out.print(
        "switches={d} wakeups={d} migrations={d} faults={d} minor/{d} major  lost={d} out_of_order={d}\n",
        .{
            metrics.switches,
            metrics.wakeups,
            metrics.migrations,
            metrics.faults_minor,
            metrics.faults_major,
            metrics.lost,
            metrics.out_of_order,
        },
    );
    try out.writeAll("\nCPU  busy_ms  idle_ms   switches  faults\n");
    for (metrics.cpus) |cpu| {
        try out.print("{d:>3} {d:>8} {d:>8} {d:>9} {d:>7}\n", .{
            cpu.cpu,
            cpu.busy_us / 1000,
            cpu.idle_us / 1000,
            cpu.switches,
            cpu.faults,
        });
    }
    try out.writeAll("\nTASK                 p50_ms  p95_ms  p99_ms  offcpu95  switches\n");
    var shown: usize = 0;
    for (metrics.tasks) |task| {
        if (task.is_self) continue;
        if (shown == opts.top_n) break;
        shown += 1;
        try out.print("{s:<20} {d:>7} {d:>7} {d:>7} {d:>8} {d:>9}\n", .{
            truncate(task.comm, 20),
            task.wait_p50_us / 1000,
            task.wait_p95_us / 1000,
            task.wait_p99_us / 1000,
            task.offcpu_p95_us / 1000,
            task.switches,
        });
    }
    if (metrics.wakeup_pairs.len != 0) {
        try out.writeAll("\nWAKEUP PAIRS         count  p95_wait_ms\n");
        var pairs_shown: usize = 0;
        for (metrics.wakeup_pairs) |pair| {
            if (pairs_shown == opts.top_n) break;
            pairs_shown += 1;
            var name_buf: [80]u8 = undefined;
            const name = std.fmt.bufPrint(
                &name_buf,
                "{s}:{d} -> {s}:{d}",
                .{ truncate(pair.waker_comm, 20), pair.waker_pid, truncate(pair.woken_comm, 20), pair.woken_pid },
            ) catch "wakeup pair";
            try out.print("{s:<34} {d:>6} {d:>11}\n", .{
                truncate(name, 34),
                pair.count,
                pair.p95_wait_us / 1000,
            });
        }
        if (metrics.pairs_truncated) try out.writeAll("(pair table truncated)\n");
    }
    try out.flush();
}

test "dashboard renders counts and task rows" {
    const tasks = [_]metrics_mod.TaskMetric{
        .{ .pid = 1, .comm = "worker", .switches = 3, .wait_p95_us = 2000 },
    };
    const metrics: metrics_mod.Metrics = .{ .switches = 3, .tasks = &tasks };
    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);
    try render(&writer, "xsprof top", metrics, .{ .top_n = 4 });
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "worker") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "switches=3") != null);
}
