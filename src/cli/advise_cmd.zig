//! `advise` entry point: host facts by default, an explicit journal with
//! `--input`. Both paths use the same fail-closed aggregate and report writers.

const std = @import("std");
const proc = @import("../os/linux/proc.zig");
const aggregates = @import("../analyze/aggregates.zig");
const report = @import("../analyze/report.zig");
const session_mod = @import("../stream/session.zig");

const Writer = std.Io.Writer;

pub fn cmdAdvise(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    out: *Writer,
    err: *Writer,
) !u8 {
    var input: ?[]const u8 = null;
    var markdown = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--input")) {
            if (i + 1 >= args.len) {
                try err.writeAll("advise: --input requires a path\n");
                return 2;
            }
            i += 1;
            input = args[i];
        } else if (std.mem.eql(u8, arg, "--md")) {
            markdown = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            continue;
        } else {
            try err.print("advise: unknown option {s}\n", .{arg});
            return 2;
        }
    }

    const agg: aggregates.Aggregates = if (input) |path| blk: {
        const session = session_mod.Session.load(io, allocator, path) catch |load_error| {
            try err.print("advise: cannot read {s}: {s}\n", .{ path, @errorName(load_error) });
            return 1;
        };
        break :blk session.aggregate();
    } else blk: {
        const facts = try proc.collectFacts(io, allocator);
        break :blk aggregates.fromFacts(facts);
    };

    if (markdown) {
        try report.writeReportMarkdown(out, allocator, agg, .{});
    } else {
        try report.writeReportJson(out, allocator, agg, .{});
    }
    return 0;
}

fn runForTest(
    args: []const []const u8,
    out_buffer: []u8,
    err_buffer: []u8,
    out: *Writer,
    err: *Writer,
) !u8 {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    out.* = Writer.fixed(out_buffer);
    err.* = Writer.fixed(err_buffer);
    return cmdAdvise(std.testing.io, arena.allocator(), args, out, err);
}

test "advise input reports a real finding and explicit skips" {
    var out_buffer: [64 * 1024]u8 = undefined;
    var err_buffer: [512]u8 = undefined;
    var out: Writer = undefined;
    var err: Writer = undefined;
    const args = [_][]const u8{ "--input", "fixtures/real/vm-fragmented.ndjson" };
    try std.testing.expectEqual(
        @as(u8, 0),
        try runForTest(&args, &out_buffer, &err_buffer, &out, &err),
    );
    const text = out.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "\"id\":\"allocator-fragmentation\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"status\":\"finding\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"id\":\"priority-inversion\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"host_mutation\":false") != null);
}

test "advise input on an empty journal skips every rule" {
    var out_buffer: [16 * 1024]u8 = undefined;
    var err_buffer: [256]u8 = undefined;
    var out: Writer = undefined;
    var err: Writer = undefined;
    const args = [_][]const u8{ "--input", "fixtures/ui/empty.ndjson" };
    try std.testing.expectEqual(
        @as(u8, 0),
        try runForTest(&args, &out_buffer, &err_buffer, &out, &err),
    );
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"status\":\"clear\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"status\":\"skip\"") != null);
}

test "advise rejects a missing input file" {
    var out_buffer: [1024]u8 = undefined;
    var err_buffer: [512]u8 = undefined;
    var out: Writer = undefined;
    var err: Writer = undefined;
    const args = [_][]const u8{ "--input", "fixtures/does-not-exist.ndjson" };
    try std.testing.expectEqual(
        @as(u8, 1),
        try runForTest(&args, &out_buffer, &err_buffer, &out, &err),
    );
    try std.testing.expect(std.mem.indexOf(u8, err.buffered(), "cannot read") != null);
}

test "advise requires a value after --input" {
    var out_buffer: [256]u8 = undefined;
    var err_buffer: [256]u8 = undefined;
    var out: Writer = undefined;
    var err: Writer = undefined;
    const args = [_][]const u8{"--input"};
    try std.testing.expectEqual(
        @as(u8, 2),
        try runForTest(&args, &out_buffer, &err_buffer, &out, &err),
    );
}

test "advise input matches the canonical golden" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var out_buffer: [64 * 1024]u8 = undefined;
    var err_buffer: [512]u8 = undefined;
    var out: Writer = undefined;
    var err: Writer = undefined;
    const args = [_][]const u8{ "--input", "fixtures/real/vm-fragmented.ndjson" };
    try std.testing.expectEqual(
        @as(u8, 0),
        try runForTest(&args, &out_buffer, &err_buffer, &out, &err),
    );
    const golden = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "tests/golden/root/advise_vm_fragmented.json",
        arena.allocator(),
        .limited(64 * 1024),
    );
    try std.testing.expectEqualStrings(golden, out.buffered());
}
