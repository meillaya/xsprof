const std = @import("std");
const protocol = @import("protocol.zig");

pub const DaemonError = error{ InvalidArgs, InvalidStateDir, JournalLimitExceeded, OutOfMemory } || std.Io.Writer.Error;

pub const max_events_per_run: usize = 128;
pub const max_journal_bytes: usize = 64 * 1024;

pub const Options = struct {
    foreground: bool,
    state_dir: []const u8,
};

pub fn parseArgs(args: []const []const u8) DaemonError!Options {
    var foreground = false;
    var state_dir: []const u8 = "";
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--foreground")) {
            foreground = true;
        } else if (std.mem.eql(u8, arg, "--state-dir")) {
            index += 1;
            if (index >= args.len) return error.InvalidArgs;
            state_dir = args[index];
        } else {
            return error.InvalidArgs;
        }
    }
    if (!foreground or state_dir.len == 0) return error.InvalidArgs;
    try validateStateDir(state_dir);
    return .{ .foreground = foreground, .state_dir = state_dir };
}

pub fn validateStateDir(path: []const u8) DaemonError!void {
    if (path.len == 0 or path.len > 240 or std.fs.path.isAbsolute(path)) return error.InvalidStateDir;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidStateDir;
    }
    for (path) |byte| {
        if (byte < 0x20 or byte == 0x7f) return error.InvalidStateDir;
        switch (byte) {
            '`', '$', '&', '|', ';', '<', '>', '(', ')', '\\' => return error.InvalidStateDir,
            else => {},
        }
    }
}

pub fn ensureCanWriteEvent(current_bytes: usize, next_event: []const u8) DaemonError!void {
    if (next_event.len > max_journal_bytes) return error.JournalLimitExceeded;
    if (current_bytes > max_journal_bytes - next_event.len) return error.JournalLimitExceeded;
}

pub fn writeReady(writer: anytype) !void {
    try writer.writeAll("{\"schema\":\"zig-scheduler/daemon-event/v1\",\"seq\":1,\"event\":\"state_changed\",\"state\":\"read_only\",\"status\":\"ready\",\"host_mutation\":false}\n");
}

pub fn writeActionResult(writer: anytype, allocator: std.mem.Allocator, line: []const u8, seq: usize) !void {
    var parsed = protocol.parseActionJson(allocator, std.mem.trim(u8, line, " \t\r\n")) catch {
        try writeRefusal(writer, seq, "malformed_action");
        return;
    };
    defer parsed.deinit();

    switch (parsed.value.kind) {
        .preflight => try writeEvent(writer, seq, "stage_finished", "preflight", "completed", "read_only"),
        .run_lab_host_safe => try writeEvent(writer, seq, "stage_started", "run_lab_host_safe", "queued", "read_only"),
        else => try writeRefusal(writer, seq, "host_mutation_refused"),
    }
}

fn writeEvent(writer: anytype, seq: usize, event: []const u8, action: []const u8, status: []const u8, state: []const u8) !void {
    try writer.print(
        "{{\"schema\":\"zig-scheduler/daemon-event/v1\",\"seq\":{d},\"event\":\"{s}\",\"action\":\"{s}\",\"state\":\"{s}\",\"status\":\"{s}\",\"host_mutation\":false}}\n",
        .{ seq, event, action, state, status },
    );
}

fn writeRefusal(writer: anytype, seq: usize, reason: []const u8) !void {
    try writer.print(
        "{{\"schema\":\"zig-scheduler/daemon-event/v1\",\"seq\":{d},\"event\":\"refusal\",\"state\":\"refused_host\",\"status\":\"refused\",\"reason\":\"{s}\",\"host_mutation\":false}}\n",
        .{ seq, reason },
    );
}

test "daemon args require foreground state dir and reject path traversal" {
    _ = try parseArgs(&.{ "--foreground", "--state-dir", ".omo/evidence/task-T08-state" });
    try std.testing.expectError(error.InvalidArgs, parseArgs(&.{ "--state-dir", ".omo/evidence/task-T08-state" }));
    try std.testing.expectError(error.InvalidStateDir, parseArgs(&.{ "--foreground", "--state-dir", "../bad" }));
}

test "daemon foreground action emits read only events and malformed refusals" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(std.testing.allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(std.testing.allocator, &list);
    try writeReady(&writer.writer);
    try writeActionResult(&writer.writer, std.testing.allocator, "{\"action\":\"preflight\"}", 2);
    try writeActionResult(&writer.writer, std.testing.allocator, "{not-json", 3);
    list = writer.toArrayList();
    try std.testing.expect(std.mem.indexOf(u8, list.items, "\"state\":\"read_only\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, list.items, "\"action\":\"preflight\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, list.items, "malformed_action") != null);
    try std.testing.expect(std.mem.indexOf(u8, list.items, "host_mutation\":false") != null);
}

test "daemon journal byte guard refuses overflow" {
    const event = "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"seq\":1}\n";
    try ensureCanWriteEvent(0, event);
    try std.testing.expectError(error.JournalLimitExceeded, ensureCanWriteEvent(max_journal_bytes - 1, event));
}
