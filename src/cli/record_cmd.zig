//! `record`: one bounded read-only capture streamed to a file (or stdout).
//! The command never materializes the whole capture in memory.

const std = @import("std");
const event = @import("../core/event.zig");
const json = @import("../core/json.zig");
const live = @import("../capture/live.zig");
const recording = @import("../capture/recording.zig");
const extract = @import("../recorder/extract.zig");
const capability = @import("capability.zig");

const Writer = std.Io.Writer;

const Sink = struct {
    io: std.Io,
    out: ?*Writer = null,
    file_writer: ?std.Io.File.Writer = null,
    buffer: [64 * 1024]u8 = undefined,
    events: u64 = 0,
    switches: u64 = 0,
    wakeups: u64 = 0,
    migrations: u64 = 0,
    faults_minor: u64 = 0,
    faults_major: u64 = 0,

    pub fn emit(self: *Sink, entry: event.RawEvent) !void {
        if (self.file_writer) |*file_writer| {
            try event.writeJson(&file_writer.interface, entry);
            try file_writer.interface.writeByte('\n');
        } else {
            try event.writeJson(self.out.?, entry);
            try self.out.?.writeByte('\n');
        }
        self.events += 1;
        switch (entry.kind) {
            .sched_switch => self.switches += 1,
            .sched_wakeup => self.wakeups += 1,
            .sched_migrate => self.migrations += 1,
            .page_fault => {
                if (entry.b == 1) self.faults_major += 1 else self.faults_minor += 1;
            },
            else => {},
        }
    }

    pub fn flush(self: *Sink) !void {
        if (self.file_writer) |*file_writer| try file_writer.interface.flush();
        if (self.out) |out| try out.flush();
    }
};

fn openOutput(
    io: std.Io,
    path: []const u8,
    force: bool,
) !std.Io.File {
    const options: std.Io.Dir.CreateFileOptions = .{
        .exclusive = !force,
        .truncate = force,
    };
    if (path.len != 0 and path[0] == '/') {
        return std.Io.Dir.createFileAbsolute(io, path, options);
    }
    return std.Io.Dir.cwd().createFile(io, path, options);
}

fn defaultOutputName(io: std.Io, allocator: std.mem.Allocator) ![]const u8 {
    const now = std.Io.Clock.now(.real, io).nanoseconds;
    return std.fmt.allocPrint(allocator, "session-{d}.ndjson", .{now});
}

fn parseDuration(text: []const u8) !u32 {
    const ms = try extract.parseDuration(text);
    if (ms == 0 or ms > std.math.maxInt(u32)) return error.InvalidDuration;
    return @intCast(ms);
}

pub fn cmdRecord(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    out: *Writer,
    err: *Writer,
) !u8 {
    var duration_ms: u32 = 1000;
    var output: ?[]const u8 = null;
    var force = false;
    var bpf = false;
    var live_options: live.Options = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--duration")) {
            if (i + 1 >= args.len) {
                try err.writeAll("record: --duration requires a value\n");
                return 2;
            }
            i += 1;
            duration_ms = parseDuration(args[i]) catch {
                try err.writeAll("record: invalid --duration\n");
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "--output")) {
            if (i + 1 >= args.len) {
                try err.writeAll("record: --output requires a path\n");
                return 2;
            }
            i += 1;
            output = args[i];
        } else if (std.mem.eql(u8, arg, "--preset")) {
            if (i + 1 >= args.len) {
                try err.writeAll("record: --preset requires a value\n");
                return 2;
            }
            i += 1;
            const preset = live.parsePreset(args[i]) orelse {
                try err.writeAll("record: unknown preset\n");
                return 2;
            };
            live_options = live.presetOptions(preset);
        } else if (std.mem.eql(u8, arg, "--force")) {
            force = true;
        } else if (std.mem.eql(u8, arg, "--bpf")) {
            bpf = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            continue;
        } else {
            try err.print("record: unknown option {s}\n", .{arg});
            return 2;
        }
    }
    if (bpf) {
        try capability.writeCapabilityEvent(
            out,
            "bpf_capture",
            "SKIP",
            "BPF lane is VM-marker-gated; no host BPF capture is available",
        );
        return 1;
    }

    const probe = live.probe(io, allocator) catch |probe_error| {
        try capability.writeCapabilityEvent(out, "live_capture", "SKIP", @errorName(probe_error));
        return 1;
    };
    if (probe.state != .READY) {
        try capability.writeCapabilityEvent(
            out,
            "live_capture",
            capability.stateName(probe.state),
            probe.reason,
        );
        return 1;
    }

    const stdout_mode = if (output) |path| std.mem.eql(u8, path, "-") else false;
    var owned_path: ?[]const u8 = null;
    const path = if (stdout_mode)
        null
    else if (output) |explicit|
        explicit
    else blk: {
        const generated = try defaultOutputName(io, allocator);
        owned_path = generated;
        break :blk generated;
    };
    defer if (owned_path) |generated| allocator.free(generated);

    var file: ?std.Io.File = null;
    if (path) |output_path| {
        file = openOutput(io, output_path, force) catch |open_error| {
            try err.print("record: cannot open {s}: {s}\n", .{ output_path, @errorName(open_error) });
            return 1;
        };
    }
    defer if (file) |opened| opened.close(io);

    var sink: Sink = .{ .io = io, .out = if (path == null) out else null };
    if (file) |opened| sink.file_writer = opened.writer(io, &sink.buffer);
    const result = recording.recordStream(io, allocator, duration_ms, live_options, &sink) catch |record_error| {
        sink.flush() catch {};
        try capability.writeCapabilityEvent(out, "live_capture", "SKIP", @errorName(record_error));
        return 1;
    };
    sink.flush() catch |flush_error| {
        try err.print("record: cannot flush output: {s}\n", .{@errorName(flush_error)});
        return 1;
    };
    if (result.state != .READY) {
        try capability.writeCapabilityEvent(
            out,
            "live_capture",
            capability.stateName(result.state),
            result.reason,
        );
        return 1;
    }

    try json.write(err, .{ .object = &.{
        .{ .key = "capability", .value = .{ .string = "READY" } },
        .{ .key = "duration_ms", .value = .{ .unsigned = duration_ms } },
        .{ .key = "events_captured", .value = .{ .unsigned = sink.events } },
        .{ .key = "faults_major", .value = .{ .unsigned = sink.faults_major } },
        .{ .key = "faults_minor", .value = .{ .unsigned = sink.faults_minor } },
        .{ .key = "host_mutation", .value = .{ .boolean = false } },
        .{ .key = "lost", .value = .{ .unsigned = result.lost } },
        .{ .key = "output", .value = .{ .string = if (path) |p| p else "-" } },
        .{ .key = "sched_migrations", .value = .{ .unsigned = sink.migrations } },
        .{ .key = "sched_switches", .value = .{ .unsigned = sink.switches } },
        .{ .key = "sched_wakeups", .value = .{ .unsigned = sink.wakeups } },
        .{ .key = "schema", .value = .{ .string = "xsprof/capture-summary/v1" } },
        .{ .key = "source", .value = .{ .string = "perf_tracepoint" } },
    } });
    try err.writeByte('\n');
    return 0;
}
