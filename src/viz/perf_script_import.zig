//! Strict, bounded importer for a documented subset of `perf script` text.
//!
//! Purpose: turn an existing `perf script` (or `perf sched script`) capture of
//! the Linux scheduler tracepoints into canonical `xsprof/event/v1` rows
//! without re-recording. The supported producer is the *default* output of
//! `perf script`/`perf sched script` over `sched:sched_switch` and
//! `sched:sched_wakeup` (`perf script --ns` is also accepted). Everything else
//! fails closed: the caller gets every accepted row, the first bounded set of
//! diagnostics with 1-based line numbers, and a rejected-line count.
//!
//! ## Supported line grammar (exactly this subset)
//!
//! ```text
//! <comm><spaces><pid><spaces>[<cpu>]<spaces><sec>.<usec|nsec>: <event>:<spaces><payload>
//! ```
//!
//! - `<comm>`: 1..15 printable ASCII bytes (0x20..0x7e). It may contain spaces.
//!   The `%16s` perf field is right-aligned; surrounding padding is trimmed.
//! - `<pid>`: unsigned decimal, <= `i32` max. The default perf tracepoint
//!   layout prints `%7d` (only `PERF_SAMPLE_TID`, not pid/tid pairs).
//! - `<cpu>`: `[` + 1..6 decimal digits + `]`, value <= 4096. Default perf
//!   prints `[%03d]`.
//! - `<sec>.<frac>`: default perf prints microseconds (`...%06lu`), `--ns`
//!   prints nanoseconds (`...%09lu`). Only exactly 6 or 9 fraction digits are
//!   accepted. Converted to `ts_ns`.
//! - `<event>`: exactly `sched:sched_switch` or `sched:sched_wakeup`. The event
//!   name may be right-padded before its colon by perf's event-width column.
//! - Blank lines and lines whose first non-space byte is `#` are skipped
//!   (`perf script --header` comments).
//!
//! `sched_switch` payload (field order fixed; values are space separated):
//!
//! ```text
//! prev_comm=<comm> prev_pid=<pid> prev_prio=<int> prev_state=<state> ==> next_comm=<comm> next_pid=<pid> next_prio=<int>
//! ```
//!
//! `<state>` is one of `R`, `R+`, `S`, `D`, `T`, `t`, `X`, `Z`, `P`, `I`
//! (the kernel's `TASK_REPORT` symbols in `include/trace/events/sched.h`).
//! `R+` is the tracepoint's preemption marker; it is normalized to the
//! canonical running value (`c = 0`) because that is the value the causal
//! latency analysis uses to detect involuntary preemption. Symbols map to the
//! kernel ABI bits documented in `src/core/sched_state.zig`:
//! `R`=0, `S`=1, `D`=2, `T`=4, `t`=8, `X`=16, `Z`=32, `P`=64, `I`=128;
//! the preempted flag is not representable and is dropped with `R+` -> 0.
//! Other flag combinations and unknown spellings are rejected.
//!
//! `sched_wakeup` payload:
//!
//! ```text
//! comm=<comm> pid=<pid> prio=<int> [success=<0|1>] target_cpu=<cpu>
//! ```
//!
//! `success=` is the legacy pre-4.20 kernel field and is accepted (validated
//! 0/1) but not represented in the canonical event. `next_pid`/`target_cpu`
//! zero padding is accepted as digits.
//!
//! ## Canonical mapping (same semantics as `src/capture/live.zig`)
//!
//! - switch: `pid`/`tid` = switched-out task; `a` = next pid; `b` = prev pid;
//!   `c` = `prev_state`; `comm` = next comm.
//! - wakeup: `pid`/`tid` = waker (perf sample task); `a` = woken pid;
//!   `b` = target CPU; `c` = 0; `comm` = woken comm.
//! - `host_mutation` is not a field of `RawEvent`; the canonical writer always
//!   serializes `false`.
//!
//! ## Rejected input
//!
//! Unsupported event names, custom `perf script -F` layouts, non-default
//! headers, other tracepoints, lost-record lines, and any payload deviation are
//! rejected with a line number. Repeated rejections are counted but only the
//! first `options.max_diagnostics` are retained (`errors_truncated` says so).
//! Input beyond `options.max_input_bytes` or `options.max_events` is rejected
//! with an error instead of a partial import. A rejected line keeps the
//! previously accepted rows so a caller can print precise diagnostics; callers
//! must treat `Import.ok()` false as "refuse the whole file".
//!
//! Returned string fields (`comm`) point into `text`; the caller must keep the
//! input alive as long as the events (same contract as
//! `src/stream/journal.zig`). The parser does not allocate per line beyond the
//! two output arrays.

const std = @import("std");
const event = @import("../core/event.zig");

pub const max_input_bytes: usize = 256 * 1024 * 1024;
pub const max_line_bytes: usize = 4096;
pub const max_events: usize = 4 * 1024 * 1024;
pub const max_diagnostics: usize = 32;
pub const max_comm_len: usize = 15;
pub const max_cpu: u64 = 4096;

/// Why one input line was rejected. Bounded so a CLI can print a stable table.
pub const Reason = enum {
    /// Line longer than `max_line_bytes`; skipped without parsing.
    line_too_long,
    /// Header is not the documented default `perf script` layout.
    bad_header,
    /// Header parsed but the event is not `sched_switch`/`sched_wakeup`.
    unsupported_event,
    /// Tracepoint payload does not match the documented field layout.
    bad_payload,
    /// `prev_state` token is not one of the supported kernel symbols.
    unsupported_state,
    /// Switch header pid does not equal the payload's `prev_pid`.
    header_mismatch,
};

pub fn reasonName(reason: Reason) []const u8 {
    return @tagName(reason);
}

pub const Diagnostic = struct {
    /// 1-based input line number.
    line: u64,
    reason: Reason,
};

pub const Options = struct {
    max_input_bytes: usize = max_input_bytes,
    max_events: usize = max_events,
    max_diagnostics: usize = max_diagnostics,
};

pub const Import = struct {
    /// Canonical events for every accepted line, in input order.
    events: []event.RawEvent,
    /// First rejected lines, bounded by `options.max_diagnostics`.
    diagnostics: []Diagnostic,
    /// Total lines seen (blank and comment lines included).
    lines: u64,
    /// Lines accepted as canonical events.
    accepted: u64,
    /// Lines rejected for any reason (including over-long lines).
    rejected: u64,
    /// True when more rejections occurred than the retained diagnostics show.
    errors_truncated: bool,

    /// True only when every non-blank, non-comment line converted cleanly.
    pub fn ok(self: Import) bool {
        return self.rejected == 0;
    }

    pub fn deinit(self: Import, allocator: std.mem.Allocator) void {
        allocator.free(self.events);
        allocator.free(self.diagnostics);
    }
};

pub const Error = error{
    InputTooLarge,
    TooManyEvents,
    OutOfMemory,
};

const LineError = error{
    BadHeader,
    UnsupportedEvent,
    BadPayload,
    UnsupportedState,
    HeaderMismatch,
};

const Header = struct {
    kind: event.Kind,
    comm: []const u8,
    pid: i32,
    cpu: i32,
    ts_ns: u64,
    payload: []const u8,
};

/// Import one `perf script` text. See the module docs for the exact grammar and
/// the failure contract. Allocates only the returned event and diagnostic
/// slices, both owned by the caller (`deinit`); `comm` slices point into
/// `text`.
pub fn import(allocator: std.mem.Allocator, text: []const u8, options: Options) Error!Import {
    if (text.len > options.max_input_bytes) return error.InputTooLarge;

    var events: std.ArrayList(event.RawEvent) = .empty;
    errdefer events.deinit(allocator);
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    errdefer diagnostics.deinit(allocator);

    var result: Import = .{
        .events = &.{},
        .diagnostics = &.{},
        .lines = 0,
        .accepted = 0,
        .rejected = 0,
        .errors_truncated = false,
    };

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        result.lines += 1;
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (isBlank(line) or isComment(line)) continue;
        if (line.len > max_line_bytes) {
            try reject(allocator, &result, &diagnostics, options, .line_too_long);
            continue;
        }
        const parsed = parseLine(line) catch |err| {
            try reject(allocator, &result, &diagnostics, options, reasonOf(err));
            continue;
        };
        if (events.items.len >= options.max_events) return error.TooManyEvents;
        try events.append(allocator, parsed);
        result.accepted += 1;
    }

    result.events = try events.toOwnedSlice(allocator);
    result.diagnostics = try diagnostics.toOwnedSlice(allocator);
    return result;
}

fn reasonOf(err: LineError) Reason {
    return switch (err) {
        error.BadHeader => .bad_header,
        error.UnsupportedEvent => .unsupported_event,
        error.BadPayload => .bad_payload,
        error.UnsupportedState => .unsupported_state,
        error.HeaderMismatch => .header_mismatch,
    };
}

fn reject(
    allocator: std.mem.Allocator,
    result: *Import,
    diagnostics: *std.ArrayList(Diagnostic),
    options: Options,
    reason: Reason,
) Error!void {
    result.rejected += 1;
    if (diagnostics.items.len < options.max_diagnostics) {
        try diagnostics.append(allocator, .{ .line = result.lines, .reason = reason });
    } else {
        result.errors_truncated = true;
    }
}

fn isBlank(line: []const u8) bool {
    return std.mem.trim(u8, line, " \t").len == 0;
}

fn isComment(line: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    return trimmed.len != 0 and trimmed[0] == '#';
}

fn parseLine(line: []const u8) LineError!event.RawEvent {
    const header = try parseHeader(line);
    return switch (header.kind) {
        .sched_switch => parseSwitch(header),
        .sched_wakeup => parseWakeup(header),
        else => error.UnsupportedEvent,
    };
}

/// Parse the default perf script header:
/// `<comm...> <pid> [<cpu>] <sec>.<frac>: <event>: <payload>`.
///
/// The first bracket with a bracketed decimal is treated as the CPU column; a
/// comm that itself contains `[<digits>]` is therefore rejected (documented
/// strictness). The event-name column is matched exactly (both supported names
/// contain a `:`), so perf's optional right-alignment padding is accepted but
/// custom `perf script -F` layouts are not.
fn parseHeader(line: []const u8) LineError!Header {
    var search: usize = 0;
    while (std.mem.indexOfScalarPos(u8, line, search, '[')) |bracket| : (search = bracket + 1) {
        const cpu = parseCpuBracket(line, bracket) orelse continue;
        return parseHeaderFrom(line, bracket, cpu);
    }
    return error.BadHeader;
}

const CpuBracket = struct {
    cpu: u32,
    after: usize,
};

/// Validate `[<digits>]` starting at `start`.
fn parseCpuBracket(line: []const u8, start: usize) ?CpuBracket {
    var i = start + 1;
    const digits_start = i;
    while (i < line.len and std.ascii.isDigit(line[i])) : (i += 1) {}
    const digit_count = i - digits_start;
    if (digit_count == 0 or digit_count > 6) return null;
    if (i >= line.len or line[i] != ']') return null;
    const cpu = std.fmt.parseInt(u32, line[digits_start..i], 10) catch return null;
    if (cpu > max_cpu) return null;
    return .{ .cpu = cpu, .after = i + 1 };
}

fn parseHeaderFrom(line: []const u8, bracket: usize, cpu: CpuBracket) LineError!Header {
    const prefix = std.mem.trimEnd(u8, line[0..bracket], " \t");
    const last_space = std.mem.lastIndexOfAny(u8, prefix, " \t") orelse return error.BadHeader;
    const comm = std.mem.trim(u8, prefix[0..last_space], " \t");
    const pid_text = std.mem.trim(u8, prefix[last_space + 1 ..], " \t");
    try validateComm(comm);
    if (pid_text.len == 0) return error.BadHeader;
    for (pid_text) |byte| {
        if (!std.ascii.isDigit(byte)) return error.BadHeader;
    }
    const pid = std.fmt.parseInt(i64, pid_text, 10) catch return error.BadHeader;
    if (pid > std.math.maxInt(i32)) return error.BadHeader;

    // Exact perf spacing: "] " then the right-aligned timestamp "%12s: ".
    if (cpu.after >= line.len or line[cpu.after] != ' ') return error.BadHeader;
    var i = cpu.after;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    const ts_start = i;
    while (i < line.len and std.ascii.isDigit(line[i])) : (i += 1) {}
    if (i == ts_start or i >= line.len or line[i] != '.') return error.BadHeader;
    const secs = std.fmt.parseInt(u64, line[ts_start..i], 10) catch return error.BadHeader;
    i += 1;
    const frac_start = i;
    while (i < line.len and std.ascii.isDigit(line[i])) : (i += 1) {}
    const frac_len = i - frac_start;
    if (frac_len != 6 and frac_len != 9) return error.BadHeader;
    const frac = std.fmt.parseInt(u64, line[frac_start..i], 10) catch return error.BadHeader;
    if (i >= line.len or line[i] != ':') return error.BadHeader;
    const ts_ns = blk: {
        const sec_ns = std.math.mul(u64, secs, std.time.ns_per_s) catch return error.BadHeader;
        const frac_ns = if (frac_len == 6)
            std.math.mul(u64, frac, std.time.ns_per_us) catch return error.BadHeader
        else
            frac;
        break :blk std.math.add(u64, sec_ns, frac_ns) catch return error.BadHeader;
    };
    i += 1;
    if (i >= line.len or line[i] != ' ') return error.BadHeader;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    var kind: event.Kind = undefined;
    if (std.mem.startsWith(u8, line[i..], "sched:sched_switch:")) {
        kind = .sched_switch;
        i += "sched:sched_switch:".len;
    } else if (std.mem.startsWith(u8, line[i..], "sched:sched_wakeup:")) {
        kind = .sched_wakeup;
        i += "sched:sched_wakeup:".len;
    } else {
        return error.UnsupportedEvent;
    }
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    const payload = line[i..];
    if (payload.len == 0) return error.BadPayload;
    return .{
        .kind = kind,
        .comm = comm,
        .pid = @intCast(pid),
        .cpu = @intCast(cpu.cpu),
        .ts_ns = ts_ns,
        .payload = payload,
    };
}

fn validateComm(comm: []const u8) LineError!void {
    if (comm.len == 0 or comm.len > max_comm_len) return error.BadHeader;
    for (comm) |byte| {
        if (byte < 0x20 or byte > 0x7e) return error.BadHeader;
    }
}

fn parseSwitch(header: Header) LineError!event.RawEvent {
    var rest = stripPrefix(header.payload, "prev_comm=") orelse return error.BadPayload;
    const prev_sep = std.mem.indexOf(u8, rest, " prev_pid=") orelse return error.BadPayload;
    const prev_comm = rest[0..prev_sep];
    try validateComm(prev_comm);
    rest = rest[prev_sep + " prev_pid=".len ..];
    const prev_pid = try takeUnsigned(&rest);
    rest = stripPrefix(rest, " prev_prio=") orelse return error.BadPayload;
    _ = try takeSigned(&rest);
    rest = stripPrefix(rest, " prev_state=") orelse return error.BadPayload;
    const arrow = std.mem.indexOf(u8, rest, " ==> ") orelse return error.BadPayload;
    const state = parseSwitchState(rest[0..arrow]) orelse return error.UnsupportedState;
    rest = rest[arrow + " ==> ".len ..];
    rest = stripPrefix(rest, "next_comm=") orelse return error.BadPayload;
    const next_sep = std.mem.indexOf(u8, rest, " next_pid=") orelse return error.BadPayload;
    const next_comm = rest[0..next_sep];
    try validateComm(next_comm);
    rest = rest[next_sep + " next_pid=".len ..];
    const next_pid = try takeUnsigned(&rest);
    rest = stripPrefix(rest, " next_prio=") orelse return error.BadPayload;
    _ = try takeSigned(&rest);
    if (std.mem.trim(u8, rest, " \t").len != 0) return error.BadPayload;
    if (prev_pid > std.math.maxInt(i32) or next_pid > std.math.maxInt(i32)) return error.BadPayload;
    if (prev_pid != @as(u32, @intCast(header.pid))) return error.HeaderMismatch;
    return .{
        .kind = .sched_switch,
        .ts_ns = header.ts_ns,
        .cpu = header.cpu,
        .pid = @intCast(prev_pid),
        .tid = @intCast(prev_pid),
        .a = next_pid,
        .b = prev_pid,
        .c = state,
        .comm = next_comm,
    };
}

fn parseWakeup(header: Header) LineError!event.RawEvent {
    var rest = stripPrefix(header.payload, "comm=") orelse return error.BadPayload;
    const comm_sep = std.mem.indexOf(u8, rest, " pid=") orelse return error.BadPayload;
    const comm = rest[0..comm_sep];
    try validateComm(comm);
    rest = rest[comm_sep + " pid=".len ..];
    const woken = try takeUnsigned(&rest);
    rest = stripPrefix(rest, " prio=") orelse return error.BadPayload;
    _ = try takeSigned(&rest);
    if (stripPrefix(rest, " success=")) |after_success| {
        rest = after_success;
        const success = try takeUnsigned(&rest);
        if (success > 1) return error.BadPayload;
    }
    rest = stripPrefix(rest, " target_cpu=") orelse return error.BadPayload;
    const target_cpu = try takeUnsigned(&rest);
    if (std.mem.trim(u8, rest, " \t").len != 0) return error.BadPayload;
    if (woken > std.math.maxInt(i32) or target_cpu > max_cpu) return error.BadPayload;
    return .{
        .kind = .sched_wakeup,
        .ts_ns = header.ts_ns,
        .cpu = header.cpu,
        .pid = header.pid,
        .tid = header.pid,
        .a = woken,
        .b = target_cpu,
        .c = 0,
        .comm = comm,
    };
}

/// Kernel `TASK_REPORT` symbols as printed by the sched_switch tracepoint.
/// `R+` means the task was involuntarily preempted; the canonical model has no
/// separate preemption bit, so it normalizes to running (0) and the analyzer
/// recovers preemption from "switch-out without an intervening wakeup".
fn parseSwitchState(text: []const u8) ?u64 {
    if (std.mem.eql(u8, text, "R") or std.mem.eql(u8, text, "R+")) return 0;
    const table = [_]struct { text: []const u8, bits: u64 }{
        .{ .text = "S", .bits = 1 },
        .{ .text = "D", .bits = 2 },
        .{ .text = "T", .bits = 4 },
        .{ .text = "t", .bits = 8 },
        .{ .text = "X", .bits = 16 },
        .{ .text = "Z", .bits = 32 },
        .{ .text = "P", .bits = 64 },
        .{ .text = "I", .bits = 128 },
    };
    for (table) |entry| {
        if (std.mem.eql(u8, text, entry.text)) return entry.bits;
    }
    return null;
}

fn stripPrefix(text: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, text, prefix)) return null;
    return text[prefix.len..];
}

/// Consume a run of decimal digits. The caller checks the following separator.
fn takeUnsigned(rest: *[]const u8) LineError!u64 {
    const text = rest.*;
    var end: usize = 0;
    while (end < text.len and std.ascii.isDigit(text[end])) : (end += 1) {}
    if (end == 0) return error.BadPayload;
    const value = std.fmt.parseInt(u64, text[0..end], 10) catch return error.BadPayload;
    rest.* = text[end..];
    return value;
}

/// Consume an optionally negative decimal integer.
fn takeSigned(rest: *[]const u8) LineError!i64 {
    const text = rest.*;
    var end: usize = 0;
    if (end < text.len and (text[end] == '-' or text[end] == '+')) end += 1;
    const digits_start = end;
    while (end < text.len and std.ascii.isDigit(text[end])) : (end += 1) {}
    if (end == digits_start) return error.BadPayload;
    const value = std.fmt.parseInt(i64, text[0..end], 10) catch return error.BadPayload;
    rest.* = text[end..];
    return value;
}

// --- Tests ---

const switch_line =
    "     swapper/1     0 [001] 1000.000001: sched:sched_switch: " ++
    "prev_comm=swapper/1 prev_pid=0 prev_prio=120 prev_state=R ==> " ++
    "next_comm=worker next_pid=4242 next_prio=120";
const wakeup_line =
    "          worker  4242 [002] 1000.000002: sched:sched_wakeup: " ++
    "comm=worker pid=4242 prio=120 target_cpu=002";

test "accepts sched_switch with canonical field mapping" {
    var result = try import(std.testing.allocator, switch_line, .{});
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.ok());
    try std.testing.expectEqual(@as(u64, 1), result.accepted);
    try std.testing.expectEqual(@as(usize, 1), result.events.len);
    const entry = result.events[0];
    try std.testing.expectEqual(event.Kind.sched_switch, entry.kind);
    try std.testing.expectEqual(@as(u64, 1_000_000_001_000), entry.ts_ns);
    try std.testing.expectEqual(@as(i32, 1), entry.cpu);
    try std.testing.expectEqual(@as(i32, 0), entry.pid);
    try std.testing.expectEqual(@as(i32, 0), entry.tid);
    try std.testing.expectEqual(@as(u64, 4242), entry.a);
    try std.testing.expectEqual(@as(u64, 0), entry.b);
    try std.testing.expectEqual(@as(u64, 0), entry.c);
    try std.testing.expectEqualStrings("worker", entry.comm);
}

test "accepts sched_wakeup with canonical field mapping" {
    var result = try import(std.testing.allocator, wakeup_line, .{});
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.ok());
    const entry = result.events[0];
    try std.testing.expectEqual(event.Kind.sched_wakeup, entry.kind);
    try std.testing.expectEqual(@as(u64, 1_000_000_002_000), entry.ts_ns);
    try std.testing.expectEqual(@as(i32, 2), entry.cpu);
    try std.testing.expectEqual(@as(i32, 4242), entry.pid);
    try std.testing.expectEqual(@as(i32, 4242), entry.tid);
    try std.testing.expectEqual(@as(u64, 4242), entry.a);
    try std.testing.expectEqual(@as(u64, 2), entry.b);
    try std.testing.expectEqual(@as(u64, 0), entry.c);
    try std.testing.expectEqualStrings("worker", entry.comm);
}

test "accepts --ns timestamps, legacy wakeup success field, and comm with spaces" {
    const ns_line =
        "     swapper/1     0 [001] 1000.000001123: sched:sched_switch: " ++
        "prev_comm=swapper/1 prev_pid=0 prev_prio=120 prev_state=S ==> " ++
        "next_comm=Web Content next_pid=4242 next_prio=120";
    var result = try import(std.testing.allocator, ns_line, .{});
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.ok());
    try std.testing.expectEqual(@as(u64, 1_000_000_001_123), result.events[0].ts_ns);
    try std.testing.expectEqualStrings("Web Content", result.events[0].comm);
    try std.testing.expectEqual(@as(u64, 1), result.events[0].c);

    const legacy =
        "          worker  4242 [002] 1000.000002: sched:sched_wakeup: " ++
        "comm=worker pid=4242 prio=120 success=1 target_cpu=002";
    var legacy_result = try import(std.testing.allocator, legacy, .{});
    defer legacy_result.deinit(std.testing.allocator);
    try std.testing.expect(legacy_result.ok());
    try std.testing.expectEqual(@as(u64, 2), legacy_result.events[0].b);
}

test "state symbols map to kernel ABI bits and R+ normalizes to running" {
    const states = [_]struct { text: []const u8, bits: u64 }{
        .{ .text = "R", .bits = 0 },
        .{ .text = "R+", .bits = 0 },
        .{ .text = "S", .bits = 1 },
        .{ .text = "D", .bits = 2 },
        .{ .text = "T", .bits = 4 },
        .{ .text = "t", .bits = 8 },
        .{ .text = "X", .bits = 16 },
        .{ .text = "Z", .bits = 32 },
        .{ .text = "P", .bits = 64 },
        .{ .text = "I", .bits = 128 },
    };
    for (states) |case| {
        var buffer: [512]u8 = undefined;
        const line = try std.fmt.bufPrint(
            &buffer,
            "     swapper/1     0 [001] 1000.000001: sched:sched_switch: " ++
                "prev_comm=swapper/1 prev_pid=0 prev_prio=120 prev_state={s} ==> " ++
                "next_comm=worker next_pid=4242 next_prio=120",
            .{case.text},
        );
        var result = try import(std.testing.allocator, line, .{});
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(result.ok());
        try std.testing.expectEqual(case.bits, result.events[0].c);
    }
}

test "header tolerates perf column padding and long comm names" {
    // `perf script` right-aligns the event name to the widest recorded event
    // and right-aligns the timestamp in a 12-column field, so a real file has
    // extra spaces before both columns (or none for long timestamps).
    const line = "          worker  4242 [002]        1234567.000002: " ++
        "   sched:sched_wakeup: comm=worker pid=4242 prio=120 target_cpu=002";
    var result = try import(std.testing.allocator, line, .{});
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.ok());
    try std.testing.expectEqual(@as(u64, 1_234_567_000_002_000), result.events[0].ts_ns);

    const padded_comm = "   Web Content  77 [010] 1.000001: " ++
        "sched:sched_switch: prev_comm=Web Content prev_pid=77 prev_prio=120 " ++
        "prev_state=D ==> next_comm=worker next_pid=78 next_prio=120";
    var second = try import(std.testing.allocator, padded_comm, .{});
    defer second.deinit(std.testing.allocator);
    try std.testing.expect(second.ok());
    try std.testing.expectEqual(@as(i32, 10), second.events[0].cpu);
    try std.testing.expectEqual(@as(u64, 2), second.events[0].c);
    try std.testing.expectEqual(@as(i32, 77), second.events[0].pid);
}

test "blank lines and perf header comments are skipped" {
    const text = "\n# ========\n# captured on: host\n" ++ switch_line ++ "\n\n";
    var result = try import(std.testing.allocator, text, .{});
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.ok());
    try std.testing.expectEqual(@as(usize, 1), result.events.len);
    try std.testing.expectEqual(@as(u64, 0), result.rejected);
}

test "CRLF input is accepted" {
    const text = switch_line ++ "\r\n" ++ wakeup_line ++ "\r\n";
    var result = try import(std.testing.allocator, text, .{});
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.ok());
    try std.testing.expectEqual(@as(usize, 2), result.events.len);
}

test "unsupported tracepoints are rejected with line numbers" {
    const text = switch_line ++ "\n" ++
        "          worker  4242 [002] 1000.000002: sched:sched_migrate_task: " ++
        "comm=worker pid=4242 prio=120 orig_cpu=2 dest_cpu=3\n";
    var result = try import(std.testing.allocator, text, .{});
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.ok());
    try std.testing.expectEqual(@as(u64, 1), result.accepted);
    try std.testing.expectEqual(@as(u64, 1), result.rejected);
    try std.testing.expectEqual(@as(usize, 1), result.diagnostics.len);
    try std.testing.expectEqual(@as(u64, 2), result.diagnostics[0].line);
    try std.testing.expectEqual(Reason.unsupported_event, result.diagnostics[0].reason);
}

test "malformed header and payload are rejected, not guessed" {
    const cases = [_]struct { line: []const u8, reason: Reason }{
        .{ .line = "not a perf script line", .reason = .bad_header },
        .{ .line = "          worker  4242 1000.000002: sched:sched_wakeup: comm=w pid=1 prio=1 target_cpu=0", .reason = .bad_header },
        .{
            .line = "          worker  4242 [002] 1000.000002: sched:sched_switch: prev_comm=worker prev_pid=4242",
            .reason = .bad_payload,
        },
        .{ .line = wakeup_line ++ " trailing", .reason = .bad_payload },
        .{ .line = wakeup_line ++ " success=2", .reason = .bad_payload },
        .{
            .line = "          worker  4242 [002] 1000.000002: sched:sched_wakeup: comm=w pid=1 prio=1 target_cpu=99999",
            .reason = .bad_payload,
        },
    };
    for (cases) |case| {
        var result = try import(std.testing.allocator, case.line, .{});
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(!result.ok());
        try std.testing.expectEqual(@as(usize, 0), result.events.len);
        try std.testing.expectEqual(@as(usize, 1), result.diagnostics.len);
        try std.testing.expectEqual(case.reason, result.diagnostics[0].reason);
    }
}

test "unsupported prev_state spellings are rejected" {
    const text = "     swapper/1     0 [001] 1000.000001: sched:sched_switch: " ++
        "prev_comm=swapper/1 prev_pid=0 prev_prio=120 prev_state=D|W ==> " ++
        "next_comm=worker next_pid=4242 next_prio=120";
    var result = try import(std.testing.allocator, text, .{});
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.ok());
    try std.testing.expectEqual(Reason.unsupported_state, result.diagnostics[0].reason);
}

test "switch header pid must match prev_pid" {
    const text = "          worker  77 [000] 1000.000001: sched:sched_switch: " ++
        "prev_comm=worker prev_pid=78 prev_prio=120 prev_state=S ==> " ++
        "next_comm=other next_pid=1 next_prio=120";
    var result = try import(std.testing.allocator, text, .{});
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.ok());
    try std.testing.expectEqual(Reason.header_mismatch, result.diagnostics[0].reason);
}

test "over-long lines are rejected without parsing the tail" {
    const allocator = std.testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    try text.appendSlice(allocator, switch_line);
    try text.append(allocator, '\n');
    try text.appendNTimes(allocator, 'x', max_line_bytes + 1);
    var result = try import(allocator, text.items, .{});
    defer result.deinit(allocator);
    try std.testing.expect(!result.ok());
    try std.testing.expectEqual(@as(u64, 1), result.accepted);
    try std.testing.expectEqual(@as(u64, 1), result.rejected);
    try std.testing.expectEqual(Reason.line_too_long, result.diagnostics[0].reason);
}

test "diagnostics stay bounded while the total rejection count is exact" {
    const allocator = std.testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        try text.appendSlice(allocator, "garbage line\n");
    }
    var result = try import(allocator, text.items, .{ .max_diagnostics = 5 });
    defer result.deinit(allocator);
    try std.testing.expect(!result.ok());
    try std.testing.expectEqual(@as(u64, 40), result.rejected);
    try std.testing.expectEqual(@as(usize, 5), result.diagnostics.len);
    try std.testing.expect(result.errors_truncated);
    try std.testing.expectEqual(@as(u64, 1), result.diagnostics[0].line);
    try std.testing.expectEqual(@as(u64, 5), result.diagnostics[4].line);
}

test "input and event bounds fail closed" {
    try std.testing.expectError(
        error.InputTooLarge,
        import(std.testing.allocator, switch_line, .{ .max_input_bytes = 8 }),
    );
    const text = switch_line ++ "\n" ++ wakeup_line;
    try std.testing.expectError(
        error.TooManyEvents,
        import(std.testing.allocator, text, .{ .max_events = 1 }),
    );
}

test "empty input is a clean empty import" {
    var result = try import(std.testing.allocator, "", .{});
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.ok());
    try std.testing.expectEqual(@as(usize, 0), result.events.len);
}

test "canonical writer emits host_mutation=false for imported rows" {
    var result = try import(std.testing.allocator, wakeup_line, .{});
    defer result.deinit(std.testing.allocator);
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try event.writeJson(&writer, result.events[0]);
    const wire = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, wire, "\"event\":\"sched_wakeup\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, wire, "\"host_mutation\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, wire, "\"schema\":\"xsprof/event/v1\"") != null);
}
