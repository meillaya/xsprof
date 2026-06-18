const std = @import("std");
const fixture_model = @import("fixture_model.zig");
const types = @import("fixture_types.zig");

pub const PreflightFixture = types.PreflightFixture;
pub const SnapshotModel = types.SnapshotModel;
pub const model = fixture_model.model;

pub fn load(allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed(PreflightFixture) {
    const source = try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .unlimited);
    defer allocator.free(source);
    return std.json.parseFromSlice(PreflightFixture, allocator, source, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
}
