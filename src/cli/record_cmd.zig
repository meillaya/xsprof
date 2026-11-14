//! `record`: one bounded read-only capture streamed to a file (or stdout).
//! The command never materializes the whole capture in memory.

const std = @import("std");
const event = @import("../core/event.zig");
const json = @import("../core/json.zig");
const live = @import("../capture/live.zig");
const maps = @import("../os/linux/maps.zig");
const recording = @import("../capture/recording.zig");
const sample = @import("../capture/sample.zig");
const capture_meta = @import("../capture/session_meta.zig");
const extract = @import("../recorder/extract.zig");
const capability = @import("capability.zig");

const Writer = std.Io.Writer;
const Exit = @import("exit.zig").Exit;

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
    stack_samples: u64 = 0,
    stack_frames: u64 = 0,

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
            .stack_sample => {
                self.stack_samples += 1;
                self.stack_frames += entry.stack.len;
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
) !Exit {
    var duration_ms: u32 = 1000;
    var output: ?[]const u8 = null;
    var force = false;
    var bpf = false;
    var preset_seen = false;
    var live_options: live.Options = .{};
    // Experimental sampling lane flags; validated together after the loop so a
    // partially specified sampling invocation is a clear usage error.
    var sample_clock: ?[]const u8 = null;
    var stacks_mode: ?[]const u8 = null;
    var target_pid: ?i32 = null;
    var freq_hz: ?u32 = null;
    var max_stack_frames: ?u16 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--duration")) {
            if (i + 1 >= args.len) {
                try err.writeAll("record: --duration requires a value\n");
                return .usage;
            }
            i += 1;
            duration_ms = parseDuration(args[i]) catch {
                try err.writeAll("record: invalid --duration\n");
                return .usage;
            };
        } else if (std.mem.eql(u8, arg, "--output")) {
            if (i + 1 >= args.len) {
                try err.writeAll("record: --output requires a path\n");
                return .usage;
            }
            i += 1;
            output = args[i];
        } else if (std.mem.eql(u8, arg, "--preset")) {
            if (i + 1 >= args.len) {
                try err.writeAll("record: --preset requires a value\n");
                return .usage;
            }
            i += 1;
            const preset = live.parsePreset(args[i]) orelse {
                try err.writeAll("record: unknown preset\n");
                return .usage;
            };
            preset_seen = true;
            live_options = live.presetOptions(preset);
        } else if (std.mem.eql(u8, arg, "--sample")) {
            if (i + 1 >= args.len) {
                try err.writeAll("record: --sample requires a clock (cpu)\n");
                return .usage;
            }
            i += 1;
            sample_clock = args[i];
        } else if (std.mem.eql(u8, arg, "--stacks")) {
            if (i + 1 >= args.len) {
                try err.writeAll("record: --stacks requires a mode (fp)\n");
                return .usage;
            }
            i += 1;
            stacks_mode = args[i];
        } else if (std.mem.eql(u8, arg, "--pid")) {
            if (i + 1 >= args.len) {
                try err.writeAll("record: --pid requires a process id\n");
                return .usage;
            }
            i += 1;
            const parsed = std.fmt.parseInt(i32, args[i], 10) catch {
                try err.writeAll("record: invalid --pid\n");
                return .usage;
            };
            if (parsed <= 0) {
                try err.writeAll("record: --pid must be a positive process id\n");
                return .usage;
            }
            target_pid = parsed;
        } else if (std.mem.eql(u8, arg, "--freq")) {
            if (i + 1 >= args.len) {
                try err.writeAll("record: --freq requires a value in Hz\n");
                return .usage;
            }
            i += 1;
            freq_hz = std.fmt.parseInt(u32, args[i], 10) catch {
                try err.writeAll("record: invalid --freq\n");
                return .usage;
            };
        } else if (std.mem.eql(u8, arg, "--max-stack-frames")) {
            if (i + 1 >= args.len) {
                try err.writeAll("record: --max-stack-frames requires a value\n");
                return .usage;
            }
            i += 1;
            max_stack_frames = std.fmt.parseInt(u16, args[i], 10) catch {
                try err.writeAll("record: invalid --max-stack-frames\n");
                return .usage;
            };
        } else if (std.mem.eql(u8, arg, "--force")) {
            force = true;
        } else if (std.mem.eql(u8, arg, "--bpf")) {
            bpf = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            continue;
        } else {
            try err.print("record: unknown option {s}\n", .{arg});
            return .usage;
        }
    }
    const sampling_requested = sample_clock != null or stacks_mode != null or
        target_pid != null or freq_hz != null or max_stack_frames != null;
    if (sampling_requested) {
        const clock = sample_clock orelse {
            try err.writeAll(
                "record: --stacks/--pid/--freq/--max-stack-frames require --sample cpu\n",
            );
            return .usage;
        };
        if (!std.mem.eql(u8, clock, "cpu")) {
            try err.print("record: unsupported --sample mode {s} (only cpu)\n", .{clock});
            return .usage;
        }
        if (stacks_mode) |mode| {
            if (!std.mem.eql(u8, mode, "fp")) {
                try err.print("record: unsupported --stacks mode {s} (only fp)\n", .{mode});
                return .usage;
            }
        }
        if (preset_seen) {
            try err.writeAll("record: --sample is mutually exclusive with --preset\n");
            return .usage;
        }
        if (bpf) {
            try err.writeAll("record: --sample is incompatible with --bpf\n");
            return .usage;
        }
        if (output) |path| {
            if (std.mem.eql(u8, path, "-")) {
                try err.writeAll(
                    "record: sampling mode requires a file --output (the maps sidecar lives next to it)\n",
                );
                return .usage;
            }
        }
        const sampling_options = sample.Options{
            .pid = target_pid orelse {
                try err.writeAll("record: --sample cpu requires --pid PID\n");
                return .usage;
            },
            .freq_hz = freq_hz orelse sample.default_freq_hz,
            .stacks = stacks_mode != null,
            .max_stack_frames = max_stack_frames orelse sample.default_max_stack_frames,
        };
        sampling_options.validate() catch |err_kind| {
            const message = switch (err_kind) {
                error.InvalidPid => "record: --pid must be a positive process id\n",
                error.InvalidFrequency => "record: --freq must be 1..10000 Hz\n",
                error.InvalidStackFrames => "record: --max-stack-frames must be 1..64\n",
            };
            try err.writeAll(message);
            return .usage;
        };
        return cmdRecordSample(io, allocator, duration_ms, sampling_options, output, force, out, err);
    }
    if (bpf) {
        try capability.writeCapabilityEvent(
            out,
            "bpf_capture",
            "SKIP",
            "BPF lane is VM-marker-gated; no host BPF capture is available",
        );
        return .refuse;
    }

    const probe = live.probeWithOptions(io, allocator, live_options) catch |probe_error| {
        try capability.writeCapabilityEvent(out, "live_capture", "SKIP", @errorName(probe_error));
        return .refuse;
    };
    // DEGRADED proceeds: the capture is useful and the summary carries the
    // exact per-collector coverage. Only SKIP/REFUSE fail closed.
    if (probe.state != .READY and probe.state != .DEGRADED) {
        try capability.writeCapabilityEvent(
            out,
            "live_capture",
            capability.stateName(probe.state),
            probe.reason,
        );
        return .refuse;
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
            return .refuse;
        };
    }
    defer if (file) |opened| opened.close(io);

    var sink: Sink = .{ .io = io, .out = if (path == null) out else null };
    if (file) |opened| sink.file_writer = opened.writer(io, &sink.buffer);
    const result = recording.recordStream(io, allocator, duration_ms, live_options, &sink) catch |record_error| {
        sink.flush() catch {};
        try capability.writeCapabilityEvent(out, "live_capture", "SKIP", @errorName(record_error));
        return .refuse;
    };
    sink.flush() catch |flush_error| {
        try err.print("record: cannot flush output: {s}\n", .{@errorName(flush_error)});
        return .refuse;
    };
    if (result.state != .READY and result.state != .DEGRADED) {
        try capability.writeCapabilityEvent(
            out,
            "live_capture",
            capability.stateName(result.state),
            result.reason,
        );
        return .refuse;
    }

    try writeSummary(err, .{
        .capability = @tagName(result.state),
        .coverage = result.coverage,
        .duration_ms = duration_ms,
        .events = sink.events,
        .faults_major = sink.faults_major,
        .faults_minor = sink.faults_minor,
        .lost = result.lost,
        .output = if (path) |p| p else "-",
        .migrations = sink.migrations,
        .reason = if (result.state == .DEGRADED) result.reason else "",
        .switches = sink.switches,
        .wakeups = sink.wakeups,
    });
    try err.writeByte('\n');
    return .ok;
}

/// Experimental per-PID sampling capture. Writes canonical NDJSON only (the
/// compact recorder path refuses stacked data), plus the local maps sidecar
/// used for analysis-time module identification. Perf/tracepoint presets are
/// rejected before this point.
fn cmdRecordSample(
    io: std.Io,
    allocator: std.mem.Allocator,
    duration_ms: u32,
    options: sample.Options,
    output: ?[]const u8,
    force: bool,
    out: *Writer,
    err: *Writer,
) !Exit {
    const probe = sample.probe(io, allocator, options) catch |probe_error| {
        try capability.writeCapabilityEvent(out, "stack_sampling", "SKIP", @errorName(probe_error));
        return .refuse;
    };
    if (probe.state != .READY and probe.state != .DEGRADED) {
        try capability.writeCapabilityEvent(out, "stack_sampling", @tagName(probe.state), probe.reason);
        return .refuse;
    }

    var owned_path: ?[]const u8 = null;
    const path = output orelse blk: {
        const generated = try defaultOutputName(io, allocator);
        owned_path = generated;
        break :blk generated;
    };
    defer if (owned_path) |generated| allocator.free(generated);

    var file = openOutput(io, path, force) catch |open_error| {
        try err.print("record: cannot open {s}: {s}\n", .{ path, @errorName(open_error) });
        return .refuse;
    };
    defer file.close(io);

    var sink: Sink = .{ .io = io };
    sink.file_writer = file.writer(io, &sink.buffer);

    const sidecar_path: ?[]const u8 = maps.sidecarPath(allocator, path) catch null;
    defer if (sidecar_path) |sidecar| allocator.free(sidecar);
    var maps_state: []const u8 = "READY";
    var maps_reason: []const u8 = "";

    const meta = capture_meta.collect(io, allocator) catch &.{};
    for (meta) |entry| try sink.emit(entry);

    var capture = sample.Capture.open(io, allocator, options) catch |open_error| {
        sink.flush() catch {};
        try capability.writeCapabilityEvent(out, "stack_sampling", "REFUSE", @errorName(open_error));
        return .refuse;
    };
    defer capture.deinit();

    var now_ns = @as(u64, @intCast(@max(0, std.Io.Clock.now(.awake, io).nanoseconds)));
    const coverage_detail = capture.coverage.detail(allocator) catch "stack_sampling";
    try sink.emit(.{ .kind = .capability, .ts_ns = now_ns, .cpu = -1, .detail = coverage_detail });

    // Maps sidecar capture start: local analysis aid, never product wire.
    if (sidecar_path) |sidecar| {
        if (maps.readProcMaps(io, allocator, options.pid)) |start_mappings| {
            maps.append(io, allocator, sidecar, .start, options.pid, start_mappings, now_ns) catch |write_error| {
                maps_state = "DEGRADED";
                maps_reason = @errorName(write_error);
            };
        } else |maps_error| {
            maps_state = "DEGRADED";
            maps_reason = @errorName(maps_error);
        }
    } else {
        maps_state = "DEGRADED";
        maps_reason = "sidecarPath";
    }
    var maps_reported = false;
    if (!std.mem.eql(u8, maps_state, "READY")) {
        const maps_detail = std.fmt.allocPrint(
            allocator,
            "session_maps:{s}:{s}",
            .{ maps_state, maps_reason },
        ) catch "session_maps:DEGRADED";
        try sink.emit(.{ .kind = .capability, .ts_ns = now_ns, .cpu = -1, .detail = maps_detail });
        maps_reported = true;
    }

    const deadline = std.Io.Clock.now(.awake, io).nanoseconds +
        @as(i96, duration_ms) * std.time.ns_per_ms;
    while (std.Io.Clock.now(.awake, io).nanoseconds < deadline) {
        if (capture.targetExited()) break;
        const remaining_ns = deadline - std.Io.Clock.now(.awake, io).nanoseconds;
        const timeout_ms: u32 = @intCast(@min(
            @divTrunc(remaining_ns, std.time.ns_per_ms),
            std.math.maxInt(u32),
        ));
        _ = try capture.poll(@min(timeout_ms, options.poll_timeout_ms));
        var batch = try capture.take();
        defer batch.deinit();
        for (batch.events) |entry| try sink.emit(entry);
    }

    if (sidecar_path) |sidecar| {
        now_ns = @as(u64, @intCast(@max(0, std.Io.Clock.now(.awake, io).nanoseconds)));
        if (maps.readProcMaps(io, allocator, options.pid)) |stop_mappings| {
            maps.append(io, allocator, sidecar, .stop, options.pid, stop_mappings, now_ns) catch |write_error| {
                if (std.mem.eql(u8, maps_state, "READY")) {
                    maps_state = "DEGRADED";
                    maps_reason = @errorName(write_error);
                }
            };
        } else |maps_error| {
            if (std.mem.eql(u8, maps_state, "READY")) {
                maps_state = "DEGRADED";
                maps_reason = @errorName(maps_error);
            }
        }
    }
    if (!maps_reported and !std.mem.eql(u8, maps_state, "READY")) {
        now_ns = @as(u64, @intCast(@max(0, std.Io.Clock.now(.awake, io).nanoseconds)));
        const maps_detail = std.fmt.allocPrint(
            allocator,
            "session_maps:{s}:{s}",
            .{ maps_state, maps_reason },
        ) catch "session_maps:DEGRADED";
        try sink.emit(.{ .kind = .capability, .ts_ns = now_ns, .cpu = -1, .detail = maps_detail });
    }

    sink.flush() catch |flush_error| {
        try err.print("record: cannot flush output: {s}\n", .{@errorName(flush_error)});
        return .refuse;
    };

    const coverage_state = capture.coverageState();
    var capability_state: []const u8 = @tagName(coverage_state);
    var reason: []const u8 = if (coverage_state == .DEGRADED) capture.coverage.reason() else "";
    if (capture.targetExited() and coverage_state == .READY) {
        capability_state = "DEGRADED";
        reason = "target exited before duration";
    } else if (!std.mem.eql(u8, maps_state, "READY") and reason.len == 0) {
        capability_state = "DEGRADED";
        reason = "maps sidecar degraded";
    }

    try writeSummary(err, .{
        .capability = capability_state,
        .duration_ms = duration_ms,
        .events = sink.events,
        .lost = capture.lost,
        .output = path,
        .reason = reason,
        .source = "perf_sampling",
        .stacks = .{
            .mode = "cpu",
            .freq_hz = options.freq_hz,
            .max_frames = options.max_stack_frames,
            .samples = sink.stack_samples,
            .dropped = capture.lost,
        },
    });
    try err.writeByte('\n');
    return .ok;
}

/// Additive `stacks` object for the experimental sampling lane. Absent on the
/// tracepoint path, so its summary bytes stay unchanged.
const StacksSummary = struct {
    mode: []const u8,
    freq_hz: u32,
    max_frames: u16,
    samples: u64,
    dropped: u64,
};

const Summary = struct {
    capability: []const u8 = "READY",
    coverage: live.Coverage = .{},
    duration_ms: u32 = 0,
    events: u64 = 0,
    faults_major: u64 = 0,
    faults_minor: u64 = 0,
    lost: u64 = 0,
    output: []const u8 = "-",
    migrations: u64 = 0,
    reason: []const u8 = "",
    source: []const u8 = "perf_tracepoint",
    stacks: ?StacksSummary = null,
    switches: u64 = 0,
    wakeups: u64 = 0,
};

/// Compose the canonical `xsprof/capture-summary/v1` stderr line. Keys are
/// strictly ascending; `page_faults` is the combined total of the split major
/// and minor fault counters (the archived `SW_PAGE_FAULTS` count). `reason` and
/// `rings` are additive: present when the capture degraded.
fn writeSummary(w: *Writer, summary: Summary) !void {
    var ring_outer: [live.collector_count]json.Entry = undefined;
    var ring_inner: [live.collector_count][3]json.Entry = undefined;
    const ring_count = summary.coverage.fillJson(&ring_outer, &ring_inner);

    var stack_entries: [5]json.Entry = undefined;
    var entries: [18]json.Entry = undefined;
    var n: usize = 0;
    entries[n] = .{ .key = "capability", .value = .{ .string = summary.capability } };
    n += 1;
    entries[n] = .{ .key = "duration_ms", .value = .{ .unsigned = summary.duration_ms } };
    n += 1;
    entries[n] = .{ .key = "events_captured", .value = .{ .unsigned = summary.events } };
    n += 1;
    entries[n] = .{ .key = "faults_major", .value = .{ .unsigned = summary.faults_major } };
    n += 1;
    entries[n] = .{ .key = "faults_minor", .value = .{ .unsigned = summary.faults_minor } };
    n += 1;
    entries[n] = .{ .key = "host_mutation", .value = .{ .boolean = false } };
    n += 1;
    entries[n] = .{ .key = "lost", .value = .{ .unsigned = summary.lost } };
    n += 1;
    entries[n] = .{ .key = "output", .value = .{ .string = summary.output } };
    n += 1;
    entries[n] = .{ .key = "page_faults", .value = .{ .unsigned = summary.faults_major +| summary.faults_minor } };
    n += 1;
    if (summary.reason.len != 0) {
        entries[n] = .{ .key = "reason", .value = .{ .string = summary.reason } };
        n += 1;
    }
    if (ring_count != 0) {
        entries[n] = .{ .key = "rings", .value = .{ .object = ring_outer[0..ring_count] } };
        n += 1;
    }
    entries[n] = .{ .key = "sched_migrations", .value = .{ .unsigned = summary.migrations } };
    n += 1;
    entries[n] = .{ .key = "sched_switches", .value = .{ .unsigned = summary.switches } };
    n += 1;
    entries[n] = .{ .key = "sched_wakeups", .value = .{ .unsigned = summary.wakeups } };
    n += 1;
    entries[n] = .{ .key = "schema", .value = .{ .string = "xsprof/capture-summary/v1" } };
    n += 1;
    entries[n] = .{ .key = "source", .value = .{ .string = summary.source } };
    n += 1;
    if (summary.stacks) |stacks| {
        // Inner keys ascending: dropped, freq_hz, max_frames, mode, samples.
        stack_entries[0] = .{ .key = "dropped", .value = .{ .unsigned = stacks.dropped } };
        stack_entries[1] = .{ .key = "freq_hz", .value = .{ .unsigned = stacks.freq_hz } };
        stack_entries[2] = .{ .key = "max_frames", .value = .{ .unsigned = stacks.max_frames } };
        stack_entries[3] = .{ .key = "mode", .value = .{ .string = stacks.mode } };
        stack_entries[4] = .{ .key = "samples", .value = .{ .unsigned = stacks.samples } };
        entries[n] = .{ .key = "stacks", .value = .{ .object = stack_entries[0..] } };
        n += 1;
    }
    try json.write(w, .{ .object = entries[0..n] });
}

test "capture summary is canonical, ascending, and includes page_faults" {
    var full: live.Coverage = .{};
    full.sched_switch = .{ .cpus = 4, .expected = 4 };
    full.sched_wakeup = .{ .cpus = 4, .expected = 4 };
    full.sched_migrate = .{ .cpus = 4, .expected = 4 };
    full.page_faults = .{ .cpus = 4, .expected = 4 };
    var buffer: [2048]u8 = undefined;
    var writer = Writer.fixed(&buffer);
    try writeSummary(&writer, .{
        .coverage = full,
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
            "\"output\":\"-\",\"page_faults\":4971,\"rings\":{" ++
            "\"page_faults\":{\"cpus\":4,\"expected\":4}," ++
            "\"sched_migrate\":{\"cpus\":4,\"expected\":4}," ++
            "\"sched_switch\":{\"cpus\":4,\"expected\":4}," ++
            "\"sched_wakeup\":{\"cpus\":4,\"expected\":4}}," ++
            "\"sched_migrations\":3,\"sched_switches\":68631,\"sched_wakeups\":41," ++
            "\"schema\":\"xsprof/capture-summary/v1\",\"source\":\"perf_tracepoint\"}",
        writer.buffered(),
    );
}

// Checks a partially covered capture reports DEGRADED with the exact shortfall
// and keeps the summary canonical and schema-valid.
test "capture summary reports DEGRADED coverage and reason" {
    var degraded: live.Coverage = .{};
    degraded.sched_switch = .{ .cpus = 4, .expected = 4 };
    degraded.sched_wakeup = .{ .expected = 4 };
    degraded.sched_wakeup.setReason("tracepoint unavailable");
    degraded.sched_migrate = .{ .cpus = 4, .expected = 4 };
    var buffer: [2048]u8 = undefined;
    var writer = Writer.fixed(&buffer);
    try writeSummary(&writer, .{
        .capability = "DEGRADED",
        .coverage = degraded,
        .duration_ms = 300,
        .events = 100,
        .faults_major = 0,
        .faults_minor = 0,
        .lost = 1,
        .output = "session.ndjson",
        .migrations = 0,
        .reason = "partial capture: sched_wakeup tracepoint unavailable",
        .switches = 99,
        .wakeups = 0,
    });
    const text = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "\"capability\":\"DEGRADED\"") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text,
        "\"reason\":\"partial capture: sched_wakeup tracepoint unavailable\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text,
        "\"sched_wakeup\":{\"cpus\":0,\"expected\":4,\"reason\":\"tracepoint unavailable\"}",
    ) != null);
    // Undeclared page_faults is omitted, and canonical key order holds.
    try std.testing.expect(std.mem.indexOf(u8, text, "\"page_faults\":{\"cpus\"") == null);
    const reason_at = std.mem.indexOf(u8, text, "\"reason\"").?;
    const rings_at = std.mem.indexOf(u8, text, "\"rings\"").?;
    const sched_at = std.mem.indexOf(u8, text, "\"sched_migrations\"").?;
    try std.testing.expect(reason_at < rings_at and rings_at < sched_at);
}

// Sampling summaries are additive: same required fields, source
// `perf_sampling`, and the bounded `stacks` object with ascending keys.
test "capture summary reports the sampling lane and stack counts" {
    var buffer: [2048]u8 = undefined;
    var writer = Writer.fixed(&buffer);
    try writeSummary(&writer, .{
        .capability = "DEGRADED",
        .duration_ms = 2000,
        .events = 501,
        .faults_major = 0,
        .faults_minor = 0,
        .lost = 7,
        .migrations = 0,
        .output = "session.ndjson",
        .reason = "3 of 8 cpus (perf_event_open failed)",
        .source = "perf_sampling",
        .stacks = .{
            .mode = "cpu",
            .freq_hz = 199,
            .max_frames = 32,
            .samples = 500,
            .dropped = 7,
        },
        .switches = 0,
        .wakeups = 0,
    });
    try std.testing.expectEqualStrings(
        "{\"capability\":\"DEGRADED\",\"duration_ms\":2000,\"events_captured\":501," ++
            "\"faults_major\":0,\"faults_minor\":0,\"host_mutation\":false,\"lost\":7," ++
            "\"output\":\"session.ndjson\",\"page_faults\":0," ++
            "\"reason\":\"3 of 8 cpus (perf_event_open failed)\"," ++
            "\"sched_migrations\":0,\"sched_switches\":0,\"sched_wakeups\":0," ++
            "\"schema\":\"xsprof/capture-summary/v1\",\"source\":\"perf_sampling\"," ++
            "\"stacks\":{\"dropped\":7,\"freq_hz\":199,\"max_frames\":32," ++
            "\"mode\":\"cpu\",\"samples\":500}}",
        writer.buffered(),
    );
}
