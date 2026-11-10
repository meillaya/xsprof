//! Static shell completions generated from the command table in `registry.zig`.
//! No generated files, no runtime dependencies, and no hand-maintained list:
//! plain completion offers visible operator commands, `--all` offers every
//! command (dispatchable and refused).

const std = @import("std");
const exit = @import("exit.zig");
const registry = @import("registry.zig");

const Writer = std.Io.Writer;
const Exit = exit.Exit;

fn commandList(buffer: []u8, include_all: bool) []const u8 {
    var writer = Writer.fixed(buffer);
    var first = true;
    for (registry.all_commands) |command| {
        if (!include_all and !command.visible) continue;
        if (!first) writer.writeByte(' ') catch unreachable;
        writer.writeAll(command.name) catch unreachable;
        first = false;
    }
    return writer.buffered();
}

pub fn cmdCompletions(args: []const []const u8, out: *Writer, err: *Writer) !Exit {
    const shell = if (args.len == 0) "bash" else args[0];
    var include_all = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--all")) include_all = true;
    }
    var command_buffer: [2048]u8 = undefined;
    const commands = commandList(&command_buffer, include_all);
    if (std.mem.eql(u8, shell, "bash")) {
        try out.print(
            \\_xsprof() {{
            \\  local cur="${{COMP_WORDS[COMP_CWORD]}}"
            \\  if [ "$COMP_CWORD" -eq 1 ]; then
            \\    COMPREPLY=( $(compgen -W "{s}" -- "$cur") )
            \\  fi
            \\}}
            \\complete -F _xsprof xsprof
            \\
        , .{commands});
        return .ok;
    }
    if (std.mem.eql(u8, shell, "zsh")) {
        try out.print(
            \\#compdef xsprof
            \\_xsprof() {{
            \\  local -a commands
            \\  commands=({s})
            \\  _describe 'command' commands
            \\}}
            \\_xsprof "$@"
            \\
        , .{commands});
        return .ok;
    }
    if (std.mem.eql(u8, shell, "fish")) {
        var it = std.mem.tokenizeScalar(u8, commands, ' ');
        while (it.next()) |command| {
            try out.print("complete -c xsprof -f -n '__fish_use_subcommand' -a {s}\n", .{command});
        }
        return .ok;
    }
    try err.writeAll("completions: supported shells are bash, zsh, fish\n");
    return .usage;
}

// The completion sets are derived from the registry, so the assertions compare
// against registry data rather than a second command list.
test "completions follow the registry visibility split" {
    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);
    var err_buffer: [128]u8 = undefined;
    var err = Writer.fixed(&err_buffer);
    try std.testing.expectEqual(Exit.ok, try cmdCompletions(&.{"bash"}, &writer, &err));
    const primary = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, primary, "ui") != null);
    try std.testing.expect(std.mem.indexOf(u8, primary, "top") != null);
    try std.testing.expect(std.mem.indexOf(u8, primary, "demo") != null);
    try std.testing.expect(std.mem.indexOf(u8, primary, "advise") == null);

    var all_buffer: [4096]u8 = undefined;
    var all_writer = Writer.fixed(&all_buffer);
    try std.testing.expectEqual(
        Exit.ok,
        try cmdCompletions(&.{ "bash", "--all" }, &all_writer, &err),
    );
    const all = all_writer.buffered();
    for (registry.all_commands) |command| {
        try std.testing.expect(std.mem.indexOf(u8, all, command.name) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, all, "advise") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "verify") != null);

    var bad_err_buffer: [128]u8 = undefined;
    var bad_err = Writer.fixed(&bad_err_buffer);
    try std.testing.expectEqual(Exit.usage, try cmdCompletions(&.{"elvish"}, &all_writer, &bad_err));
}
