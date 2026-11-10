//! One registry for the explicit loss markers produced by the capture,
//! recorder, and viewer layers.
//!
//! Every marker that stands for dropped, truncated, missing, or aged-out data
//! is named here. Producers emit the names from `marker`; consumers classify
//! marker detail with `classify`/`Counter` and report a per-kind breakdown.
//! Classification is a single token match on the detail prefix, never a
//! substring scan: a new loss kind must be added here to be counted anywhere.
//!
//! The enum order is alphabetical so `writeJson` emits canonical ascending
//! keys without a per-kind sort. A unit test pins that invariant.

const std = @import("std");

/// Marker kinds that represent lost or unavailable data. The wire name (the
/// marker detail prefix and the `loss_by_kind` key) is the enum tag name.
pub const Kind = enum {
    /// A compact block or record failed CRC/shape validation; the segment tail
    /// after the failure is lost.
    capture_corrupt_segment,
    /// A manifest segment path was not a safe relative path.
    capture_invalid_segment_path,
    /// A manifest-listed segment file is gone.
    capture_missing_segment,
    /// A segment could not be opened at all (permissions, I/O).
    capture_segment_unreadable,
    /// Extraction stopped at `max_events`/`max_bytes`.
    capture_truncated,
    /// A compact segment is missing its clean-close footer (torn write).
    capture_truncated_tail,
    /// A segment's filename did not map to a known codec.
    capture_unknown_segment_codec,
    /// A segment declares an unsupported raw-segment version.
    capture_unsupported_segment,
    /// Raw segments were aged/byte-budgeted out; the requested window gap is
    /// explicit but the number of lost events is unknown.
    retention_loss,
    /// Events were dropped by a collector or a bounded feed (perf ring loss,
    /// live view coalescing, replay tail gaps).
    sample_loss,
};

pub const kind_count = @typeInfo(Kind).@"enum".field_names.len;

/// Lost-event totals per kind. Named fields (not a positional array) so the
/// `loss_by_kind` JSON object round-trips through `std.json` for sidecars.
/// Bounded, fixed size, no allocation. Field order is the canonical wire order.
pub const ByKind = struct {
    capture_corrupt_segment: u64 = 0,
    capture_invalid_segment_path: u64 = 0,
    capture_missing_segment: u64 = 0,
    capture_segment_unreadable: u64 = 0,
    capture_truncated: u64 = 0,
    capture_truncated_tail: u64 = 0,
    capture_unknown_segment_codec: u64 = 0,
    capture_unsupported_segment: u64 = 0,
    retention_loss: u64 = 0,
    sample_loss: u64 = 0,

    pub fn get(self: ByKind, kind: Kind) u64 {
        inline for (@typeInfo(ByKind).@"struct".field_names, @typeInfo(Kind).@"enum".field_names) |field_name, kind_name| {
            if (kind == @field(Kind, kind_name)) return @field(self, field_name);
        }
        unreachable;
    }

    pub fn add(self: *ByKind, kind: Kind, amount: u64) void {
        inline for (@typeInfo(ByKind).@"struct".field_names, @typeInfo(Kind).@"enum".field_names) |field_name, kind_name| {
            if (kind == @field(Kind, kind_name)) {
                @field(self.*, field_name) +|= amount;
                return;
            }
        }
        unreachable;
    }

    pub fn total(self: ByKind) u64 {
        var sum_value: u64 = 0;
        inline for (@typeInfo(ByKind).@"struct".field_names) |field_name| {
            sum_value +|= @field(self, field_name);
        }
        return sum_value;
    }
};

/// Producer-facing marker names. Use these instead of string literals so a
/// renamed kind is a compile error at every producer.
pub const marker = struct {
    pub const capture_corrupt_segment: []const u8 = @tagName(Kind.capture_corrupt_segment);
    pub const capture_invalid_segment_path: []const u8 = @tagName(Kind.capture_invalid_segment_path);
    pub const capture_missing_segment: []const u8 = @tagName(Kind.capture_missing_segment);
    pub const capture_segment_unreadable: []const u8 = @tagName(Kind.capture_segment_unreadable);
    pub const capture_truncated: []const u8 = @tagName(Kind.capture_truncated);
    pub const capture_truncated_tail: []const u8 = @tagName(Kind.capture_truncated_tail);
    pub const capture_unknown_segment_codec: []const u8 = @tagName(Kind.capture_unknown_segment_codec);
    pub const capture_unsupported_segment: []const u8 = @tagName(Kind.capture_unsupported_segment);
    pub const retention_loss: []const u8 = @tagName(Kind.retention_loss);
    pub const sample_loss: []const u8 = @tagName(Kind.sample_loss);
};

pub fn name(kind: Kind) []const u8 {
    return @tagName(kind);
}

pub fn kindFromName(text: []const u8) ?Kind {
    inline for (@typeInfo(Kind).@"enum".field_names) |field_name| {
        if (std.mem.eql(u8, text, field_name)) return @field(Kind, field_name);
    }
    return null;
}

/// Classify a marker detail by its first whitespace-delimited token. Returns
/// null for non-loss markers (`capture_owner`, `capture_start`,
/// `capture_interrupted`, capabilities, …): interruption alone is not loss and
/// the following tail marker, when present, carries the loss.
pub fn classify(detail: []const u8) ?Kind {
    if (detail.len == 0) return null;
    var end: usize = 0;
    while (end < detail.len and detail[end] != ' ' and detail[end] != '\t') : (end += 1) {}
    if (end == 0) return null;
    return kindFromName(detail[0..end]);
}

/// Magnitude of one loss marker. `lost=`/`dropped=` tokens carry an event
/// count; a marker without one describes one loss gap and counts as one.
/// `dropped_segments=` deliberately does not match: retention gaps do not
/// invent an event count.
pub fn magnitude(detail: []const u8) u64 {
    const prefixes = [_][]const u8{ "lost=", "dropped=" };
    var tokens = std.mem.tokenizeAny(u8, detail, " \t,");
    while (tokens.next()) |token| {
        for (prefixes) |prefix| {
            if (!std.mem.startsWith(u8, token, prefix)) continue;
            return std.fmt.parseInt(u64, token[prefix.len..], 10) catch 1;
        }
    }
    return 1;
}

/// Saturating accumulator used by analysis paths that see marker rows.
pub const Counter = struct {
    totals: ByKind = .{},
    markers: u64 = 0,

    /// Count one event detail. Returns false when it is not a loss marker.
    pub fn add(self: *Counter, detail: []const u8) bool {
        const kind = classify(detail) orelse return false;
        self.markers +|= 1;
        self.totals.add(kind, magnitude(detail));
        return true;
    }

    pub fn total(self: *const Counter) u64 {
        return sum(self.totals);
    }

    pub fn byKind(self: *const Counter, kind: Kind) u64 {
        return self.totals.get(kind);
    }
};

pub fn sum(totals: ByKind) u64 {
    return totals.total();
}

/// Emit the canonical `loss_by_kind` object. Only nonzero kinds are written,
/// in field (alphabetical) order, so the object is compact and ascending. An
/// all-zero breakdown writes `{}`.
pub fn writeJson(w: *std.Io.Writer, totals: ByKind) !void {
    try w.writeByte('{');
    var first = true;
    inline for (@typeInfo(ByKind).@"struct".field_names) |field_name| {
        const value = @field(totals, field_name);
        if (value != 0) {
            if (!first) try w.writeByte(',');
            first = false;
            try w.print("\"{s}\":{d}", .{ field_name, value });
        }
    }
    try w.writeByte('}');
}

test "kind names are alphabetical for canonical ascending keys" {
    var previous: []const u8 = "";
    inline for (@typeInfo(Kind).@"enum".field_names) |field_name| {
        try std.testing.expect(previous.len == 0 or
            std.mem.order(u8, previous, field_name) == .lt);
        previous = field_name;
    }
    try std.testing.expectEqual(@as(usize, 10), kind_count);
    // The wire object fields follow the same canonical order.
    var previous_field: []const u8 = "";
    inline for (@typeInfo(ByKind).@"struct".field_names) |field_name| {
        try std.testing.expect(previous_field.len == 0 or
            std.mem.order(u8, previous_field, field_name) == .lt);
        previous_field = field_name;
    }
}

test "classification is a prefix token, not a substring scan" {
    try std.testing.expectEqual(Kind.sample_loss, classify("sample_loss perf_ring lost=7").?);
    try std.testing.expectEqual(Kind.retention_loss, classify("retention_loss dropped_segments=3").?);
    try std.testing.expectEqual(Kind.capture_truncated_tail, classify("capture_truncated_tail missing_footer=1 dropped=1").?);
    try std.testing.expectEqual(Kind.capture_truncated, classify("capture_truncated reason=max_events limit=10 dropped=1").?);
    try std.testing.expectEqual(Kind.capture_corrupt_segment, classify("capture_corrupt_segment offset=42 dropped=1").?);
    // Non-loss markers and unrelated text stay uncounted.
    try std.testing.expect(classify("capture_owner") == null);
    try std.testing.expect(classify("capture_start") == null);
    try std.testing.expect(classify("capture_interrupted previous_session=abc") == null);
    try std.testing.expect(classify("ring_sched_switch:READY:8 of 8 cpus") == null);
    try std.testing.expect(classify("") == null);
    try std.testing.expect(classify("dropped=3 sample_loss") == null);
}

test "magnitude reads lost/dropped and keeps gap markers at one" {
    try std.testing.expectEqual(@as(u64, 7), magnitude("sample_loss perf_ring lost=7"));
    try std.testing.expectEqual(@as(u64, 3), magnitude("sample_loss live_ui dropped=3 reason=trim"));
    try std.testing.expectEqual(@as(u64, 1), magnitude("capture_missing_segment"));
    try std.testing.expectEqual(@as(u64, 1), magnitude("retention_loss dropped_segments=128"));
    try std.testing.expectEqual(@as(u64, 1), magnitude("capture_truncated reason=max_bytes limit=1 dropped=1"));
    try std.testing.expectEqual(@as(u64, 0), magnitude("sample_loss lost=0"));
}

test "counter counts every kind and reports per-kind totals" {
    var counter: Counter = .{};
    try std.testing.expect(counter.add("sample_loss perf_ring lost=3"));
    try std.testing.expect(counter.add("retention_loss requested_from_wall_ns=1 oldest_wall_ns=2"));
    try std.testing.expect(counter.add("capture_corrupt_segment offset=0 dropped=1"));
    try std.testing.expect(counter.add("capture_truncated_tail missing_footer=1 dropped=1"));
    try std.testing.expect(!counter.add("capture_owner"));
    try std.testing.expectEqual(@as(u64, 4), counter.markers);
    try std.testing.expectEqual(@as(u64, 6), counter.total());
    try std.testing.expectEqual(@as(u64, 3), counter.byKind(.sample_loss));
    try std.testing.expectEqual(@as(u64, 1), counter.byKind(.retention_loss));
    try std.testing.expectEqual(@as(u64, 1), counter.byKind(.capture_corrupt_segment));
    try std.testing.expectEqual(@as(u64, 1), counter.byKind(.capture_truncated_tail));
    try std.testing.expectEqual(@as(u64, 0), counter.byKind(.capture_missing_segment));
    try std.testing.expectEqual(@as(u64, 6), sum(counter.totals));
}

test "loss json is canonical, compact, and ascending" {
    var totals: ByKind = .{};
    totals.add(.sample_loss, 3);
    totals.add(.retention_loss, 2);
    totals.add(.capture_unknown_segment_codec, 1);

    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeJson(&writer, totals);
    try std.testing.expectEqualStrings(
        "{\"capture_unknown_segment_codec\":1,\"retention_loss\":2,\"sample_loss\":3}",
        writer.buffered(),
    );

    var empty_buffer: [8]u8 = undefined;
    var empty_writer = std.Io.Writer.fixed(&empty_buffer);
    try writeJson(&empty_writer, .{});
    try std.testing.expectEqualStrings("{}", empty_writer.buffered());
}
