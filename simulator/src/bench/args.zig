const std = @import("std");

pub const OutputFormat = enum {
    markdown,
    json,
};

pub const Options = struct {
    output_format: OutputFormat = .markdown,
};

pub fn parseArgs(args: []const []const u8) !Options {
    var options = Options{};

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--format")) {
            options.output_format = parseFormat(try nextArg(args, &index)) orelse return error.InvalidArguments;
            continue;
        }
        if (std.mem.eql(u8, arg, "--help")) return error.InvalidArguments;
        return error.InvalidArguments;
    }

    return options;
}

fn nextArg(args: []const []const u8, index: *usize) ![]const u8 {
    index.* += 1;
    if (index.* >= args.len) return error.InvalidArguments;
    return args[index.*];
}

fn parseFormat(value: []const u8) ?OutputFormat {
    if (std.mem.eql(u8, value, "markdown") or std.mem.eql(u8, value, "md")) return .markdown;
    if (std.mem.eql(u8, value, "json")) return .json;
    return null;
}

test "benchmark args parse supported formats" {
    try std.testing.expectEqual(OutputFormat.markdown, (try parseArgs(&.{})).output_format);
    try std.testing.expectEqual(OutputFormat.json, (try parseArgs(&.{ "--format", "json" })).output_format);
    try std.testing.expectEqual(OutputFormat.markdown, (try parseArgs(&.{ "--format", "md" })).output_format);
}

test "benchmark args reject invalid input" {
    try std.testing.expectError(error.InvalidArguments, parseArgs(&.{ "--format", "bogus" }));
    try std.testing.expectError(error.InvalidArguments, parseArgs(&.{"--help"}));
}
