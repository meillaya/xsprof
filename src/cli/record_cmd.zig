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

    try writeSummary(err, .{
        .duration_ms = duration_ms,
        .events = sink.events,
        .faults_major = sink.faults_major,
        .faults_minor = sink.faults_minor,
        .lost = result.lost,
        .output = if (path) |p| p else "-",
        .migrations = sink.migrations,
        .switches = sink.switches,
        .wakeups = sink.wakeups,
    });
    try err.writeByte('\n');
    return 0;
}

const Summary = struct {
    duration_ms: u32,
    events: u64,
    faults_major: u64,
    faults_minor: u64,
    lost: u64,
    output: []const u8,
    migrations: u64,
    switches: u64,
    wakeups: u64,
};

/// Compose the canonical `xsprof/capture-summary/v1` stderr line. Keys are
/// strictly ascending; `page_faults` is the combined total of the split major
/// and minor fault counters (the archived `SW_PAGE_FAULTS` count).
fn writeSummary(w: *Writer, summary: Summary) !void {
    try json.write(w, .{ .object = &.{
        .{ .key = "capability", .value = .{ .string = "READY" } },
        .{ .key = "duration_ms", .value = .{ .unsigned = summary.duration_ms } },
        .{ .key = "events_captured", .value = .{ .unsigned = summary.events } },
        .{ .key = "faults_major", .value = .{ .unsigned = summary.faults_major } },
        .{ .key = "faults_minor", .value = .{ .unsigned = summary.faults_minor } },
        .{ .key = "host_mutation", .value = .{ .boolean = false } },
        .{ .key = "lost", .value = .{ .unsigned = summary.lost } },
        .{ .key = "output", .value = .{ .string = summary.output } },
        .{ .key = "page_faults", .value = .{ .unsigned = summary.faults_major +| summary.faults_minor } },
        .{ .key = "sched_migrations", .value = .{ .unsigned = summary.migrations } },
        .{ .key = "sched_switches", .value = .{ .unsigned = summary.switches } },
        .{ .key = "sched_wakeups", .value = .{ .unsigned = summary.wakeups } },
        .{ .key = "schema", .value = .{ .string = "xsprof/capture-summary/v1" } },
        .{ .key = "source", .value = .{ .string = "perf_tracepoint" } },
    } });
}

test "capture summary is canonical, ascending, and includes page_faults" {
    var buffer: [1024]u8 = undefined;
    var writer = Writer.fixed(&buffer);
    try writeSummary(&writer, .{
        .duration_ms = 300,
        .events = 73648,
        .faults_major = 12,
        .faults_minor = 4959,
        .lost = 0,
        .output = "-",
        .migrations = 3,
        .switches = 68631,
        .wakeups = 41,
    });
    try std.testing.expectEqualStrings(
        "{\"capability\":\"READY\",\"duration_ms\":300,\"events_captured\":73648," ++
            "\"faults_major\":12,\"faults_minor\":4959,\"host_mutation\":false,\"lost\":0," ++
            "\"output\":\"-\",\"page_faults\":4971,\"sched_migrations\":3," ++
            "\"sched_switches\":68631,\"sched_wakeups\":41," ++
            "\"schema\":\"xsprof/capture-summary/v1\",\"source\":\"perf_tracepoint\"}",
        writer.buffered(),
    );
}
