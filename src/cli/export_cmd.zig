//! `export`: convert a sampled-stack capture to a foreign analysis format.
//!
//! Supported formats:
//!   folded       `<comm>;<fn>;<fn> <count>` for flamegraph tooling.
//!   perf-script  the documented strict subset written by `src/viz/perf_script.zig`.
//!
//! Symbolization is analysis-time and optional: `--binary` (ELF function
//! symbols), `--kallsyms` (`/proc/kallsyms` text), and the capture's local
//! `*.maps.ndjson` sidecar (ELF load bias) are the only inputs. Without them
//! frames stay explicit `0x...` addresses. The command never invents a symbol,
//! never uses the network, and fails closed on unreadable input or when the
//! capture has no sampled stacks.

const std = @import("std");
const event = @import("../core/event.zig");
const loss = @import("../core/loss.zig");
const json = @import("../core/json.zig");
const journal = @import("../stream/journal.zig");
const maps = @import("../os/linux/maps.zig");
const symbols = @import("../analyze/symbols.zig");
const folded = @import("../viz/folded.zig");
const perf_script = @import("../viz/perf_script.zig");

const Writer = std.Io.Writer;
const Exit = @import("exit.zig").Exit;

const Format = enum { folded, perf_script };

const Options = struct {
    format: Format,
    input: []const u8,
    binary: ?[]const u8 = null,
    kallsyms: ?[]const u8 = null,
};

fn parseFormat(text: []const u8) ?Format {
    if (std.mem.eql(u8, text, "folded")) return .folded;
    if (std.mem.eql(u8, text, "perf-script")) return .perf_script;
    return null;
}

fn parseArgs(args: []const []const u8, err: *Writer) !?Options {
    var format: ?Format = null;
    var format_text: []const u8 = "";
    var input: ?[]const u8 = null;
    var binary: ?[]const u8 = null;
    var kallsyms: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--format")) {
            if (i + 1 >= args.len) {
                try err.writeAll("export: --format requires a value (folded|perf-script)\n");
                return null;
            }
            i += 1;
            format_text = args[i];
            format = parseFormat(format_text) orelse {
                try err.print("export: unsupported --format {s} (folded|perf-script)\n", .{format_text});
                return null;
            };
        } else if (std.mem.eql(u8, arg, "--input")) {
            if (i + 1 >= args.len) {
                try err.writeAll("export: --input requires a path\n");
                return null;
            }
            i += 1;
            input = args[i];
        } else if (std.mem.eql(u8, arg, "--binary")) {
            if (i + 1 >= args.len) {
                try err.writeAll("export: --binary requires a path\n");
                return null;
            }
            i += 1;
            binary = args[i];
        } else if (std.mem.eql(u8, arg, "--kallsyms")) {
            if (i + 1 >= args.len) {
                try err.writeAll("export: --kallsyms requires a path\n");
                return null;
            }
            i += 1;
            kallsyms = args[i];
        } else if (std.mem.eql(u8, arg, "--json")) {
            // Output format is selected by --format; accept for automation
            // symmetry with the other analysis verbs.
        } else {
            try err.print("export: unknown option {s}\n", .{arg});
            return null;
        }
    }
    const selected = format orelse {
        try err.writeAll("export: --format folded|perf-script is required\n");
        return null;
    };
    return .{
        .format = selected,
        .input = input orelse {
            try err.writeAll("export: --input requires a capture file\n");
            return null;
        },
        .binary = binary,
        .kallsyms = kallsyms,
    };
}

fn pathExists(io: std.Io, path: []const u8) bool {
    const file = if (path.len != 0 and path[0] == '/')
        std.Io.Dir.openFileAbsolute(io, path, .{}) catch return false
    else
        std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

const Loaded = struct {
    symbolizer: symbols.Symbolizer,
    samples: usize,
    dropped: u64,
    loss_markers: u64,

    fn deinit(self: *Loaded) void {
        self.symbolizer.deinit();
    }
};

fn loadCapture(
    io: std.Io,
    allocator: std.mem.Allocator,
    options: Options,
    events: *[]event.RawEvent,
    err: *Writer,
) !?Loaded {
    events.* = journal.read(io, allocator, options.input) catch |read_error| {
        try err.print("export: cannot read {s}: {s}\n", .{ options.input, @errorName(read_error) });
        return null;
    };
    var samples: usize = 0;
    var loss_counter: loss.Counter = .{};
    for (events.*) |entry| {
        switch (entry.kind) {
            .stack_sample => samples += 1,
            .marker => _ = loss_counter.add(entry.detail),
            else => {},
        }
    }
    if (samples == 0) {
        try err.print(
            "export: no stack_sample events in {s} (tracepoint and IP-only captures carry no stacks)\n",
            .{options.input},
        );
        return null;
    }
    const sidecar = try maps.sidecarPath(allocator, options.input);
    const maps_path: ?[]const u8 = if (pathExists(io, sidecar)) sidecar else null;
    const symbolizer = symbols.Symbolizer.load(io, allocator, .{
        .binary_path = options.binary,
        .maps_path = maps_path,
        .kallsyms_path = options.kallsyms,
    }) catch |symbol_error| {
        try err.print("export: symbolizer: {s}\n", .{@errorName(symbol_error)});
        return null;
    };
    return .{
        .symbolizer = symbolizer,
        .samples = samples,
        .dropped = loss_counter.total(),
        .loss_markers = loss_counter.markers,
    };
}

const FoldedSummary = struct {
    dropped: u64,
    frames: u64,
    input: []const u8,
    no_frame_samples: u64,
    samples: u64,
    stacks: usize,
    unresolved_frames: u64,
};

fn writeFoldedSummary(w: *Writer, summary: FoldedSummary) !void {
    try json.write(w, .{ .object = &.{
        .{ .key = "dropped", .value = .{ .unsigned = summary.dropped } },
        .{ .key = "format", .value = .{ .string = "folded" } },
        .{ .key = "frames", .value = .{ .unsigned = summary.frames } },
        .{ .key = "host_mutation", .value = .{ .boolean = false } },
        .{ .key = "input", .value = .{ .string = summary.input } },
        .{ .key = "no_frame_samples", .value = .{ .unsigned = summary.no_frame_samples } },
        .{ .key = "samples", .value = .{ .unsigned = summary.samples } },
        .{ .key = "stacks", .value = .{ .unsigned = @intCast(summary.stacks) } },
        .{ .key = "unresolved_frames", .value = .{ .unsigned = summary.unresolved_frames } },
    } });
    try w.writeByte('\n');
}

fn exportFolded(
    out: *Writer,
    err: *Writer,
    options: Options,
    events: []const event.RawEvent,
    loaded: *Loaded,
) !Exit {
    var table = folded.Table.init(std.heap.smp_allocator);
    defer table.deinit();
    var no_frame_samples: u64 = 0;
    var unresolved_frames: u64 = 0;
    var tokens: [event.max_stack_frames][]const u8 = undefined;
    var token_buffers: [event.max_stack_frames][folded.max_token_bytes]u8 = undefined;
    var key_buffer: [folded.max_key_bytes]u8 = undefined;
    for (events) |entry| {
        if (entry.kind != .stack_sample) continue;
        const frame_count: usize = entry.stack.len;
        var used: usize = 0;
        if (frame_count == 0) {
            tokens[0] = "[unknown]";
            used = 1;
            no_frame_samples +|= 1;
        } else {
            // Event stacks are leaf-first; folded lines are root-first.
            var index: usize = 0;
            while (index < frame_count and index < event.max_stack_frames) : (index += 1) {
                const address = entry.stack[frame_count - 1 - index];
                const frame = loaded.symbolizer.resolve(address);
                var token_writer = Writer.fixed(&token_buffers[index]);
                if (frame.kernel) try token_writer.writeAll("[k]");
                if (frame.resolved) {
                    try token_writer.writeAll(frame.name);
                } else {
                    unresolved_frames +|= 1;
                    try token_writer.print("0x{x}", .{address});
                }
                tokens[index] = token_writer.buffered();
            }
            used = @min(frame_count, event.max_stack_frames);
        }
        var key_writer = Writer.fixed(&key_buffer);
        try folded.writeKey(&key_writer, entry.comm, tokens[0..used]);
        table.add(key_writer.buffered(), 1, used) catch |table_error| {
            try err.print("export: folded table: {s}\n", .{@errorName(table_error)});
            return .refuse;
        };
    }
    const stats = table.write(out) catch |write_error| {
        try err.print("export: folded writer: {s}\n", .{@errorName(write_error)});
        return .refuse;
    };
    try writeFoldedSummary(err, .{
        .dropped = loaded.dropped,
        .frames = stats.frames,
        .input = options.input,
        .no_frame_samples = no_frame_samples,
        .samples = stats.samples,
        .stacks = stats.stacks,
        .unresolved_frames = unresolved_frames,
    });
    return .ok;
}

fn exportPerfScript(
    out: *Writer,
    err: *Writer,
    options: Options,
    events: []const event.RawEvent,
    loaded: *Loaded,
) !Exit {
    var written: u64 = 0;
    var frame_storage: [event.max_stack_frames]perf_script.Frame = undefined;
    for (events) |entry| {
        if (entry.kind != .stack_sample) continue;
        var frames: []const perf_script.Frame = &.{};
        const frame_count = @min(entry.stack.len, event.max_stack_frames);
        for (0..frame_count) |index| {
            const address = entry.stack[index];
            const frame = loaded.symbolizer.resolve(address);
            const dso: []const u8 = if (frame.kernel)
                "[kernel.kallsyms]"
            else if (frame.resolved and loaded.symbolizer.binary_path.len != 0)
                loaded.symbolizer.binary_path
            else
                "[unknown]";
            if (frame.resolved) {
                frame_storage[index] = .{
                    .addr = address,
                    .symbol = frame.name,
                    .offset = frame.offset,
                    .dso = dso,
                };
            } else {
                frame_storage[index] = .{ .addr = address, .dso = dso };
            }
        }
        frames = frame_storage[0..frame_count];
        perf_script.writeSample(out, .{
            .comm = entry.comm,
            .pid = entry.pid,
            .tid = entry.tid,
            .cpu = entry.cpu,
            .ts_ns = entry.ts_ns,
            .frames = frames,
        }) catch |write_error| {
            try err.print("export: perf-script writer: {s}\n", .{@errorName(write_error)});
            return .refuse;
        };
        written +|= 1;
    }
    try json.write(err, .{ .object = &.{
        .{ .key = "format", .value = .{ .string = "perf-script" } },
        .{ .key = "host_mutation", .value = .{ .boolean = false } },
        .{ .key = "input", .value = .{ .string = options.input } },
        .{ .key = "samples", .value = .{ .unsigned = written } },
    } });
    try err.writeByte('\n');
    return .ok;
}

pub fn cmdExport(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    out: *Writer,
    err: *Writer,
) !Exit {
    const options = (try parseArgs(args, err)) orelse return .usage;
    var events: []event.RawEvent = &.{};
    var loaded = (try loadCapture(io, allocator, options, &events, err)) orelse return .refuse;
    defer loaded.deinit();
    return switch (options.format) {
        .folded => exportFolded(out, err, options, events, &loaded),
        .perf_script => exportPerfScript(out, err, options, events, &loaded),
    };
}

fn testTempPath(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    std.Io.Dir.cwd().createDirPath(std.testing.io, ".zig-cache/tmp") catch {};
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{name});
}

fn writeTestCapture(
    allocator: std.mem.Allocator,
    name: []const u8,
    entries: []const event.RawEvent,
) ![]u8 {
    const path = try testTempPath(allocator, name);
    var file = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{ .truncate = true });
    defer file.close(std.testing.io);
    var buffer: [16 * 1024]u8 = undefined;
    var writer = file.writer(std.testing.io, &buffer);
    for (entries) |entry| {
        try event.writeJson(&writer.interface, entry);
        try writer.interface.writeByte('\n');
    }
    try writer.interface.flush();
    return path;
}

const sample_line_event = event.RawEvent{
    .kind = .stack_sample,
    .ts_ns = 123_000,
    .cpu = 2,
    .pid = 42,
    .tid = 42,
    .a = 0x401000,
    .comm = "probe",
};

test "export usage errors fail closed with exit 2" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var out_buffer: [256]u8 = undefined;
    var err_buffer: [512]u8 = undefined;
    var out = Writer.fixed(&out_buffer);
    var err = Writer.fixed(&err_buffer);
    try std.testing.expectEqual(
        Exit.usage,
        try cmdExport(std.testing.io, arena.allocator(), &.{}, &out, &err),
    );
    try std.testing.expectEqual(
        Exit.usage,
        try cmdExport(std.testing.io, arena.allocator(), &.{ "--format", "json" }, &out, &err),
    );
    try std.testing.expectEqual(
        Exit.usage,
        try cmdExport(std.testing.io, arena.allocator(), &.{ "--format", "folded" }, &out, &err),
    );
    try std.testing.expectEqual(
        Exit.usage,
        try cmdExport(
            std.testing.io,
            arena.allocator(),
            &.{ "--format", "folded", "--input", "x.ndjson", "--nope" },
            &out,
            &err,
        ),
    );
    try std.testing.expect(std.mem.indexOf(u8, err.buffered(), "export:") != null);
}

test "export refuses missing input and captures without stacks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var out_buffer: [4096]u8 = undefined;
    var err_buffer: [512]u8 = undefined;
    var out = Writer.fixed(&out_buffer);
    var err = Writer.fixed(&err_buffer);
    try std.testing.expectEqual(
        Exit.refuse,
        try cmdExport(
            std.testing.io,
            arena.allocator(),
            &.{ "--format", "folded", "--input", ".zig-cache/tmp/does-not-exist.ndjson" },
            &out,
            &err,
        ),
    );
    const tracepoint = [_]event.RawEvent{.{
        .kind = .sched_switch,
        .ts_ns = 1,
        .cpu = 0,
        .pid = 1,
        .tid = 1,
        .comm = "worker",
    }};
    const path = try writeTestCapture(arena.allocator(), "xsprof-export-tracepoint.ndjson", &tracepoint);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    try std.testing.expectEqual(
        Exit.refuse,
        try cmdExport(
            std.testing.io,
            arena.allocator(),
            &.{ "--format", "folded", "--input", path },
            &out,
            &err,
        ),
    );
    try std.testing.expect(std.mem.indexOf(u8, err.buffered(), "no stack_sample events") != null);
}

test "folded export writes deterministic bytes for unresolved stacks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const stack = [_]u64{ 0x401000, 0x402000 };
    var with_stack = sample_line_event;
    with_stack.stack = &stack;
    const entries = [_]event.RawEvent{ with_stack, sample_line_event, .{
        .kind = .marker,
        .ts_ns = 1,
        .cpu = -1,
        .detail = "sample_loss stacks_perf_ring lost=3",
    } };
    const path = try writeTestCapture(allocator, "xsprof-export-folded.ndjson", &entries);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var out_buffer: [4096]u8 = undefined;
    var err_buffer: [2048]u8 = undefined;
    var out = Writer.fixed(&out_buffer);
    var err = Writer.fixed(&err_buffer);
    try std.testing.expectEqual(
        Exit.ok,
        try cmdExport(
            std.testing.io,
            allocator,
            &.{ "--format", "folded", "--input", path },
            &out,
            &err,
        ),
    );
    try std.testing.expectEqualStrings(
        "probe;0x402000;0x401000 1\nprobe;[unknown] 1\n",
        out.buffered(),
    );
    const summary = err.buffered();
    try std.testing.expect(std.mem.indexOf(u8, summary, "\"dropped\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "\"samples\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "\"no_frame_samples\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "\"host_mutation\":false") != null);
}

test "perf-script export emits the documented subset" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const entries = [_]event.RawEvent{sample_line_event};
    const path = try writeTestCapture(allocator, "xsprof-export-script.ndjson", &entries);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var out_buffer: [2048]u8 = undefined;
    var err_buffer: [1024]u8 = undefined;
    var out = Writer.fixed(&out_buffer);
    var err = Writer.fixed(&err_buffer);
    try std.testing.expectEqual(
        Exit.ok,
        try cmdExport(
            std.testing.io,
            allocator,
            &.{ "--format", "perf-script", "--input", path },
            &out,
            &err,
        ),
    );
    try std.testing.expectEqualStrings(
        "probe 42/42 [002] 0.000123: 1 cpu-clock:\n",
        out.buffered(),
    );
    try std.testing.expect(std.mem.indexOf(u8, err.buffered(), "\"format\":\"perf-script\"") != null);
}

test "export refuses unreadable symbol inputs explicitly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const entries = [_]event.RawEvent{sample_line_event};
    const path = try writeTestCapture(allocator, "xsprof-export-symbols.ndjson", &entries);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var out_buffer: [1024]u8 = undefined;
    var err_buffer: [1024]u8 = undefined;
    var out = Writer.fixed(&out_buffer);
    var err = Writer.fixed(&err_buffer);
    try std.testing.expectEqual(
        Exit.refuse,
        try cmdExport(
            std.testing.io,
            allocator,
            &.{ "--format", "folded", "--input", path, "--binary", ".zig-cache/tmp/no-such-elf" },
            &out,
            &err,
        ),
    );
    try std.testing.expect(std.mem.indexOf(u8, err.buffered(), "symbolizer") != null);
    try std.testing.expectEqual(
        Exit.refuse,
        try cmdExport(
            std.testing.io,
            allocator,
            &.{ "--format", "folded", "--input", path, "--kallsyms", ".zig-cache/tmp/no-such-kallsyms" },
            &out,
            &err,
        ),
    );
}
