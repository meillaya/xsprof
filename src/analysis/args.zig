const std = @import("std");

pub const OutputFormat = enum {
    markdown,
    svg,
};

pub const Options = struct {
    input_path: []const u8,
    output_format: OutputFormat = .markdown,
};

pub fn parseArgs(args: []const []const u8) !Options {
    var options: Options = .{ .input_path = "" };
    var saw_input = false;

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--input")) {
            options.input_path = try nextArg(args, &index);
            saw_input = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--format")) {
            options.output_format = parseFormat(try nextArg(args, &index)) orelse return error.InvalidArguments;
            continue;
        }
        if (std.mem.eql(u8, arg, "--help")) return error.InvalidArguments;
        return error.InvalidArguments;
    }

    if (!saw_input) return error.InvalidArguments;
    return options;
}

fn nextArg(args: []const []const u8, index: *usize) ![]const u8 {
    index.* += 1;
    if (index.* >= args.len) return error.InvalidArguments;
    return args[index.*];
}

pub fn parseFormat(value: []const u8) ?OutputFormat {
    if (std.mem.eql(u8, value, "markdown")) return .markdown;
    if (std.mem.eql(u8, value, "md")) return .markdown;
    if (std.mem.eql(u8, value, "svg")) return .svg;
    return null;
}

test "analysis args require input" {
    try std.testing.expectError(error.InvalidArguments, parseArgs(&.{}));
    try std.testing.expectError(error.InvalidArguments, parseArgs(&.{ "--format", "markdown" }));
}

test "analysis args parse markdown and svg" {
    const markdown = try parseArgs(&.{ "--input", "fixture.json" });
    try std.testing.expectEqualStrings("fixture.json", markdown.input_path);
    try std.testing.expectEqual(OutputFormat.markdown, markdown.output_format);

    const svg = try parseArgs(&.{ "--input", "fixture.json", "--format", "svg" });
    try std.testing.expectEqualStrings("fixture.json", svg.input_path);
    try std.testing.expectEqual(OutputFormat.svg, svg.output_format);
}
