//! Bounded UI action audit ring and canonical NDJSON writer. Records only
//! console actions and outcomes: never runtime samples, argv, environment, or
//! file contents. Schema: xsprof/ui-audit/v1.

const std = @import("std");

pub const schema = "xsprof/ui-audit/v1";
pub const max_entries = 64;
pub const max_action = 48;
pub const max_code = 48;
pub const max_source = 16;

pub const Outcome = enum {
    ok,
    refused,
    failed,
    skipped,

    pub fn label(self: Outcome) []const u8 {
        return switch (self) {
            .ok => "ok",
            .refused => "refused",
            .failed => "failed",
            .skipped => "skipped",
        };
    }
};

pub const Entry = struct {
    seq: u32 = 0,
    wall_ms: u64 = 0,
    action: [max_action]u8 = @splat(0),
    action_len: usize = 0,
    outcome: Outcome = .ok,
    code: [max_code]u8 = @splat(0),
    code_len: usize = 0,
    source: [max_source]u8 = @splat(0),
    source_len: usize = 0,

    pub fn actionSlice(self: *const Entry) []const u8 {
        return self.action[0..self.action_len];
    }

    pub fn codeSlice(self: *const Entry) []const u8 {
        return self.code[0..self.code_len];
    }

    pub fn sourceSlice(self: *const Entry) []const u8 {
        return self.source[0..self.source_len];
    }
};

pub const Ring = struct {
    entries: [max_entries]Entry = @splat(Entry{}),
    head: usize = 0,
    len: usize = 0,
    next_seq: u32 = 1,

    pub fn append(self: *Ring, wall_ms: u64, action: []const u8, outcome: Outcome, code: []const u8, source: []const u8) void {
        var entry = Entry{ .seq = self.next_seq, .wall_ms = wall_ms, .outcome = outcome };
        entry.action_len = @min(action.len, entry.action.len);
        @memcpy(entry.action[0..entry.action_len], action[0..entry.action_len]);
        entry.code_len = @min(code.len, entry.code.len);
        @memcpy(entry.code[0..entry.code_len], code[0..entry.code_len]);
        entry.source_len = @min(source.len, entry.source.len);
        @memcpy(entry.source[0..entry.source_len], source[0..entry.source_len]);
        self.entries[self.head] = entry;
        self.head = (self.head + 1) % max_entries;
        if (self.len < max_entries) self.len += 1;
        self.next_seq +%= 1;
    }

    /// Oldest-first logical access.
    pub fn at(self: *const Ring, index: usize) ?*const Entry {
        if (index >= self.len) return null;
        const start = if (self.len == max_entries) self.head else 0;
        return &self.entries[(start + index) % max_entries];
    }

    pub fn newest(self: *const Ring) ?*const Entry {
        if (self.len == 0) return null;
        return self.at(self.len - 1);
    }

    pub fn clear(self: *Ring) void {
        self.len = 0;
        self.head = 0;
    }
};

fn writeString(w: *std.Io.Writer, text: []const u8) !void {
    try w.writeByte('"');
    for (text) |byte| {
        switch (byte) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            else => {
                if (byte < 0x20) {
                    try w.print("\\u00{x:0>2}", .{byte});
                } else {
                    try w.writeByte(byte);
                }
            },
        }
    }
    try w.writeByte('"');
}

pub fn writeJsonLine(w: *std.Io.Writer, entry: *const Entry) !void {
    try w.writeAll("{\"action\":");
    try writeString(w, entry.actionSlice());
    try w.writeAll(",\"code\":");
    try writeString(w, entry.codeSlice());
    try w.writeAll(",\"host_mutation\":false,\"outcome\":");
    try writeString(w, entry.outcome.label());
    try w.writeAll(",\"schema\":");
    try writeString(w, schema);
    try w.writeAll(",\"seq\":");
    try w.print("{d}", .{entry.seq});
    try w.writeAll(",\"source\":");
    try writeString(w, entry.sourceSlice());
    try w.writeAll(",\"wall_ms\":");
    try w.print("{d}", .{entry.wall_ms});
    try w.writeByte('}');
    try w.writeByte('\n');
}

test "audit ring stays bounded and ordered" {
    var ring = Ring{};
    var i: usize = 0;
    while (i < 70) : (i += 1) {
        var buf: [32]u8 = undefined;
        const action = std.fmt.bufPrint(&buf, "action-{d}", .{i}) catch "x";
        ring.append(@intCast(i), action, .ok, "", "replay");
    }
    try std.testing.expectEqual(max_entries, ring.len);
    try std.testing.expectEqual(@as(u32, 7), ring.at(0).?.seq);
    try std.testing.expectEqual(@as(u32, 70), ring.newest().?.seq);
    try std.testing.expectEqualStrings("action-69", ring.newest().?.actionSlice());
    try std.testing.expectEqualStrings("xsprof/ui-audit/v1", schema);
}

test "audit entries serialize canonically" {
    var ring = Ring{};
    ring.append(42, "theme.set", .ok, "theme.paper", "replay");
    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeJsonLine(&writer, ring.newest().?);
    const line = writer.buffered();
    try std.testing.expect(std.mem.startsWith(u8, line, "{\"action\":\"theme.set\",\"code\":\"theme.paper\",\"host_mutation\":false,\"outcome\":\"ok\","));
    try std.testing.expect(std.mem.endsWith(u8, line, "}\n"));
    try std.testing.expect(std.mem.indexOf(u8, line, "\"schema\":\"xsprof/ui-audit/v1\"") != null);
}
