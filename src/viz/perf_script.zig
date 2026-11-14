//! Strict, bounded writer/parser for a documented subset of `perf script`
//! text so sampled captures can interoperate with perf tooling.
//!
//! Documented subset (one sample block):
//!
//! ```text
//! <comm> <pid>/<tid> [<cpu>] <sec>.<usec>: <period> <event>:
//!         <hex addr> <symbol>+0x<offset> (<dso>)
//!         <hex addr> [unknown] (<dso>)
//! ```
//!
//! Header tokens are separated by one or more spaces; callchain lines start
//! with whitespace followed by 1..16 lowercase hex digits. Symbols are
//! `[unknown]`, `0x...`, or a plain `[A-Za-z0-9_.$@]` token. A dso is any
//! bounded text inside the final parentheses. Anything outside this subset —
//! including `perf sched script` scheduler lines — is rejected fail-closed with
//! `error.InvalidScript`; the writer only emits the subset above.

const std = @import("std");

const Writer = std.Io.Writer;

pub const max_line_bytes = 1024;
pub const max_frames = 64;
pub const max_samples = 1_000_000;
pub const max_input_bytes = 64 * 1024 * 1024;
pub const max_token_bytes = 256;
pub const max_dso_bytes = 512;
pub const max_cpu = 4095;

pub const ParseError = error{
    InvalidScript,
    LineTooLong,
    TooManySamples,
    TooManyFrames,
    InputTooLarge,
    OutOfMemory,
};

pub const Frame = struct {
    addr: u64,
    symbol: []const u8 = "[unknown]",
    /// Present only for resolved symbols (`symbol+0xoffset`).
    offset: ?u64 = null,
    dso: []const u8 = "[unknown]",
};

pub const Sample = struct {
    comm: []const u8,
    pid: i32,
    tid: i32,
    cpu: i32,
    ts_ns: u64,
    period: u64 = 1,
    event: []const u8 = "cpu-clock",
    frames: []const Frame = &.{},
};

fn writeSanitized(w: *Writer, text: []const u8, buffer: []u8, forbidden: []const u8) Writer.Error!void {
    const bounded = text[0..@min(text.len, @min(buffer.len, max_token_bytes))];
    for (bounded, 0..) |byte, index| {
        var value = byte;
        if (byte < 0x20 or byte == 0x7f) value = '_';
        if (std.mem.indexOfScalar(u8, forbidden, byte) != null) value = '_';
        buffer[index] = value;
    }
    const cleaned = if (bounded.len == 0) "_" else buffer[0..bounded.len];
    try w.writeAll(cleaned);
}

fn writePaddedHex(w: *Writer, value: u64) Writer.Error!void {
    try w.print("{x:0>16}", .{value});
}

/// Write one `perf script` sample block. Frames are written leaf-first, the
/// order perf itself prints a callchain in.
pub fn writeSample(w: *Writer, sample: Sample) Writer.Error!void {
    var comm_buffer: [max_token_bytes]u8 = undefined;
    var symbol_buffer: [max_token_bytes]u8 = undefined;
    var dso_buffer: [max_dso_bytes]u8 = undefined;
    try writeSanitized(w, sample.comm, &comm_buffer, " []()\t/");
    try w.print(" {d}/{d} [{d:0>3}] {d}.{d:0>6}: {d} ", .{
        sample.pid,
        sample.tid,
        @max(sample.cpu, 0),
        sample.ts_ns / std.time.ns_per_s,
        (sample.ts_ns % std.time.ns_per_s) / std.time.ns_per_us,
        sample.period,
    });
    var event_buffer: [max_token_bytes]u8 = undefined;
    try writeSanitized(w, sample.event, &event_buffer, " :()\t");
    try w.writeAll(":\n");
    for (sample.frames) |frame| {
        try w.writeAll("\t\t");
        try writePaddedHex(w, frame.addr);
        try w.writeByte(' ');
        try writeSanitized(w, frame.symbol, &symbol_buffer, " ()+\t");
        if (frame.offset) |offset| try w.print("+0x{x}", .{offset});
        try w.writeAll(" (");
        try writeSanitized(w, frame.dso, &dso_buffer, "()\t");
        try w.writeAll(")\n");
    }
}

pub const ParsedFrame = struct {
    addr: u64,
    symbol: []const u8,
    offset: ?u64 = null,
    dso: []const u8,
};

pub const ParsedSample = struct {
    comm: []const u8,
    pid: i32,
    tid: i32,
    cpu: i32,
    ts_ns: u64,
    period: u64,
    event: []const u8,
    frames: []ParsedFrame,
};

fn isSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}

fn skipSpaces(line: []const u8, start: usize) usize {
    var pos = start;
    while (pos < line.len and isSpace(line[pos])) : (pos += 1) {}
    return pos;
}

fn tokenEnd(line: []const u8, start: usize) usize {
    var pos = start;
    while (pos < line.len and !isSpace(line[pos])) : (pos += 1) {}
    return pos;
}

fn isHexText(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |byte| {
        if (!std.ascii.isHex(byte)) return false;
    }
    return true;
}

fn isSymbolText(text: []const u8) bool {
    if (text.len == 0 or text.len > max_token_bytes) return false;
    for (text) |byte| {
        if (std.ascii.isAlphanumeric(byte)) continue;
        switch (byte) {
            '_', '.', '$', '@', '[', ']' => continue,
            else => return false,
        }
    }
    return true;
}

const Header = struct {
    comm: []const u8,
    pid: i32,
    tid: i32,
    cpu: i32,
    ts_ns: u64,
    period: u64,
    event: []const u8,
};

fn parseCount(text: []const u8) ParseError!u64 {
    if (text.len == 0) return error.InvalidScript;
    return std.fmt.parseInt(u64, text, 10) catch error.InvalidScript;
}

fn parseHeader(line: []const u8) ParseError!Header {
    var tokens = std.mem.tokenizeAny(u8, line, " \t");
    const comm = tokens.next() orelse return error.InvalidScript;
    if (comm.len == 0 or comm.len > max_token_bytes) return error.InvalidScript;
    const pid_token = tokens.next() orelse return error.InvalidScript;
    const slash = std.mem.indexOfScalar(u8, pid_token, '/') orelse return error.InvalidScript;
    const pid_text = pid_token[0..slash];
    const tid_text = pid_token[slash + 1 ..];
    if (pid_text.len == 0 or tid_text.len == 0) return error.InvalidScript;
    const pid = std.fmt.parseInt(i32, pid_text, 10) catch return error.InvalidScript;
    const tid = std.fmt.parseInt(i32, tid_text, 10) catch return error.InvalidScript;
    const cpu_token = tokens.next() orelse return error.InvalidScript;
    if (cpu_token.len < 3 or cpu_token[0] != '[' or cpu_token[cpu_token.len - 1] != ']') {
        return error.InvalidScript;
    }
    const cpu = std.fmt.parseInt(i32, cpu_token[1 .. cpu_token.len - 1], 10) catch
        return error.InvalidScript;
    if (cpu < 0 or cpu > max_cpu) return error.InvalidScript;
    const time_token = tokens.next() orelse return error.InvalidScript;
    // perf prints the timestamp with a trailing colon: `12.345678:`.
    if (time_token.len < 3 or time_token[time_token.len - 1] != ':') {
        return error.InvalidScript;
    }
    const time_text = time_token[0 .. time_token.len - 1];
    const dot = std.mem.indexOfScalar(u8, time_text, '.') orelse return error.InvalidScript;
    const sec_text = time_text[0..dot];
    const frac_text = time_text[dot + 1 ..];
    if (frac_text.len == 0 or frac_text.len > 9) return error.InvalidScript;
    const seconds = parseCount(sec_text) catch return error.InvalidScript;
    if (!isHexText(frac_text)) return error.InvalidScript;
    const fraction = parseCount(frac_text) catch return error.InvalidScript;
    var fraction_ns = fraction;
    var scale: usize = frac_text.len;
    while (scale < 9) : (scale += 1) fraction_ns *= 10;
    const ts_ns = seconds * std.time.ns_per_s + fraction_ns;
    const period_token = tokens.next() orelse return error.InvalidScript;
    const period = parseCount(period_token) catch return error.InvalidScript;
    const event_token = tokens.next() orelse return error.InvalidScript;
    if (event_token.len < 2 or event_token[event_token.len - 1] != ':') return error.InvalidScript;
    const event = event_token[0 .. event_token.len - 1];
    for (event) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-' and byte != '.' and byte != ':') {
            return error.InvalidScript;
        }
    }
    if (tokens.next() != null) return error.InvalidScript;
    return .{
        .comm = comm,
        .pid = pid,
        .tid = tid,
        .cpu = cpu,
        .ts_ns = ts_ns,
        .period = period,
        .event = event,
    };
}

fn parseFrame(line: []const u8) ParseError!ParsedFrame {
    var pos = skipSpaces(line, 0);
    if (pos >= line.len) return error.InvalidScript;
    const address_end = tokenEnd(line, pos);
    const address_text = line[pos..address_end];
    if (address_text.len == 0 or address_text.len > 16 or !isHexText(address_text)) {
        return error.InvalidScript;
    }
    const addr = std.fmt.parseInt(u64, address_text, 16) catch return error.InvalidScript;
    pos = skipSpaces(line, address_end);
    if (pos >= line.len) return error.InvalidScript;
    const symbol_end = tokenEnd(line, pos);
    const symbol_token = line[pos..symbol_end];
    var symbol = symbol_token;
    var offset: ?u64 = null;
    if (std.mem.indexOfScalar(u8, symbol_token, '+')) |plus| {
        symbol = symbol_token[0..plus];
        const offset_token = symbol_token[plus + 1 ..];
        if (offset_token.len < 3 or offset_token[0] != '0' or offset_token[1] != 'x') {
            return error.InvalidScript;
        }
        const offset_text = offset_token[2..];
        if (!isHexText(offset_text) or offset_text.len > 16) return error.InvalidScript;
        offset = std.fmt.parseInt(u64, offset_text, 16) catch return error.InvalidScript;
    }
    if (!isSymbolText(symbol) and !std.mem.eql(u8, symbol, "[unknown]")) return error.InvalidScript;
    pos = symbol_end;
    pos = skipSpaces(line, pos);
    if (pos >= line.len or line[pos] != '(') return error.InvalidScript;
    const open = pos;
    const close = std.mem.lastIndexOfScalar(u8, line, ')') orelse return error.InvalidScript;
    if (close != line.len - 1 or close <= open + 1) return error.InvalidScript;
    const dso = line[open + 1 .. close];
    if (dso.len > max_dso_bytes) return error.InvalidScript;
    for (dso) |byte| {
        if (byte < 0x20 or byte == 0x7f) return error.InvalidScript;
    }
    return .{ .addr = addr, .symbol = symbol, .offset = offset, .dso = dso };
}

/// Parse the documented subset. Blank lines are ignored; any other line that
/// is not a header or a callchain frame fails closed with `error.InvalidScript`.
pub fn parse(allocator: std.mem.Allocator, data: []const u8) ParseError![]ParsedSample {
    if (data.len > max_input_bytes) return error.InputTooLarge;
    var samples: std.ArrayList(ParsedSample) = .empty;
    errdefer samples.deinit(allocator);
    var frames: std.ArrayList(ParsedFrame) = .empty;
    var frames_open = false;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (line.len > max_line_bytes) return error.LineTooLong;
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;
        if (isSpace(line[0])) {
            if (!frames_open) return error.InvalidScript;
            if (frames.items.len >= max_frames) return error.TooManyFrames;
            try frames.append(allocator, try parseFrame(line));
            continue;
        }
        const header = try parseHeader(line);
        if (samples.items.len >= max_samples) return error.TooManySamples;
        if (frames_open) {
            samples.items[samples.items.len - 1].frames = try frames.toOwnedSlice(allocator);
            frames = .empty;
        }
        try samples.append(allocator, .{
            .comm = header.comm,
            .pid = header.pid,
            .tid = header.tid,
            .cpu = header.cpu,
            .ts_ns = header.ts_ns,
            .period = header.period,
            .event = header.event,
            .frames = &.{},
        });
        frames_open = true;
    }
    if (frames_open and samples.items.len != 0) {
        samples.items[samples.items.len - 1].frames = try frames.toOwnedSlice(allocator);
    } else {
        frames.deinit(allocator);
    }
    return samples.toOwnedSlice(allocator);
}

test "perf script writer round-trips through the strict parser" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const frames = [_]Frame{
        .{ .addr = 0x401000, .symbol = "spin_loop", .offset = 0x10, .dso = "/tmp/probe" },
        .{ .addr = 0xffffffff81000000, .symbol = "do_syscall_64", .dso = "[kernel.kallsyms]" },
        .{ .addr = 0x401800, .symbol = "[unknown]", .dso = "[unknown]" },
    };
    var out: std.Io.Writer.Allocating = .init(allocator);
    try writeSample(&out.writer, .{
        .comm = "probe",
        .pid = 42,
        .tid = 42,
        .cpu = 3,
        .ts_ns = 12_345_678_000, // perf-script text carries microsecond precision
        .frames = &frames,
    });
    const parsed = try parse(allocator, out.written());
    try std.testing.expectEqual(@as(usize, 1), parsed.len);
    const sample = parsed[0];
    try std.testing.expectEqualStrings("probe", sample.comm);
    try std.testing.expectEqual(@as(i32, 42), sample.pid);
    try std.testing.expectEqual(@as(i32, 42), sample.tid);
    try std.testing.expectEqual(@as(i32, 3), sample.cpu);
    try std.testing.expectEqual(@as(u64, 12_345_678_000), sample.ts_ns);
    try std.testing.expectEqual(@as(u64, 1), sample.period);
    try std.testing.expectEqualStrings("cpu-clock", sample.event);
    try std.testing.expectEqual(@as(usize, 3), sample.frames.len);
    try std.testing.expectEqual(@as(u64, 0x401000), sample.frames[0].addr);
    try std.testing.expectEqualStrings("spin_loop", sample.frames[0].symbol);
    try std.testing.expectEqual(@as(u64, 0x10), sample.frames[0].offset.?);
    try std.testing.expectEqualStrings("/tmp/probe", sample.frames[0].dso);
    try std.testing.expectEqualStrings("[kernel.kallsyms]", sample.frames[1].dso);
    try std.testing.expect(sample.frames[2].offset == null);
}

test "perf script parser rejects unsupported lines fail-closed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const header = "probe 42/42 [003] 12.345678: 1 cpu-clock:\n";
    // A callchain line before any sample block.
    try std.testing.expectError(
        error.InvalidScript,
        parse(allocator, "\t\t0000000000401000 spin_loop+0x10 (/tmp/probe)\n"),
    );
    // `perf sched script` scheduler lines are outside the subset.
    try std.testing.expectError(
        error.InvalidScript,
        parse(allocator, "probe 42 [003] 12.345678: sched:sched_switch: prev_comm=a prev_pid=1 ==> next_comm=b next_pid=2\n"),
    );
    // Missing pid/tid separator.
    try std.testing.expectError(error.InvalidScript, parse(allocator, "probe 42 [003] 12.345678: 1 cpu-clock:\n"));
    // Trailing garbage after the event token.
    try std.testing.expectError(
        error.InvalidScript,
        parse(allocator, "probe 42/42 [003] 12.345678: 1 cpu-clock: extra\n"),
    );
    // Malformed frame address and missing dso.
    try std.testing.expectError(
        error.InvalidScript,
        parse(allocator, header ++ "\t\tzzzz spin_loop (/tmp/probe)\n"),
    );
    try std.testing.expectError(
        error.InvalidScript,
        parse(allocator, header ++ "\t\t0000000000401000 spin_loop+0x10\n"),
    );
    // Too many frames in one block.
    var out: std.Io.Writer.Allocating = .init(allocator);
    try out.writer.writeAll(header);
    var index: usize = 0;
    while (index <= max_frames) : (index += 1) {
        const line = try std.fmt.allocPrint(allocator, "\t\t{x:0>16} f (/x)\n", .{0x401000 + index});
        try out.writer.writeAll(line);
    }
    try std.testing.expectError(error.TooManyFrames, parse(allocator, out.written()));
    // Over-long lines are rejected before parsing.
    var long_line = std.ArrayList(u8).empty;
    defer long_line.deinit(allocator);
    try long_line.appendSlice(allocator, header);
    try long_line.appendNTimes(allocator, 'a', max_line_bytes + 16);
    try std.testing.expectError(error.LineTooLong, parse(allocator, long_line.items));
}

test "perf script parser tolerates blank lines between blocks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const text =
        "probe 7/8 [000] 1.500000: 2 cpu-clock:\n" ++
        "\t\t0000000000401000 a+0x1 (/bin/probe)\n" ++
        "\n" ++
        "probe 7/8 [001] 2.500000: 2 cpu-clock:\n";
    const parsed = try parse(allocator, text);
    try std.testing.expectEqual(@as(usize, 2), parsed.len);
    try std.testing.expectEqual(@as(usize, 1), parsed[0].frames.len);
    try std.testing.expectEqual(@as(usize, 0), parsed[1].frames.len);
}
