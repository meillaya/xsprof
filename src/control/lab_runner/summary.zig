const std = @import("std");
const errors = @import("errors.zig");
const events = @import("events.zig");

pub const RawStage = struct {
    stage: []const u8,
    status: []const u8,
    reason: []const u8,
    artifact: []const u8,
};

const RawSummary = struct {
    stages: []RawStage,
};

pub fn appendSummaryStages(
    allocator: std.mem.Allocator,
    io: std.Io,
    output: *std.ArrayList(u8),
    seq: *usize,
    summary_path: []const u8,
) errors.RunError!void {
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, summary_path, allocator, .limited(1024 * 1024));
    defer allocator.free(raw);
    var parsed = std.json.parseFromSlice(RawSummary, allocator, raw, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return error.InvalidSummary;
    defer parsed.deinit();
    for (parsed.value.stages) |stage| {
        if (!validStageStatus(stage.status)) return error.InvalidSummary;
        try events.appendEvent(allocator, output, seq, "stage_finished", stage.stage, stage.status, "read_only", stage.reason, stage.artifact);
    }
}

pub fn validStageStatus(status: []const u8) bool {
    return std.mem.eql(u8, status, "PASS") or std.mem.eql(u8, status, "SKIP") or std.mem.eql(u8, status, "REFUSE");
}

test "lab runner validates accepted stage statuses" {
    try std.testing.expect(validStageStatus("PASS"));
    try std.testing.expect(validStageStatus("SKIP"));
    try std.testing.expect(validStageStatus("REFUSE"));
    try std.testing.expect(!validStageStatus("completed"));
}
