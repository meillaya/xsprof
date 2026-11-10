//! Static shell completions. No generated files or runtime dependencies. The
//! default set is the UI-first primary surface; --all adds automation verbs.

const std = @import("std");

const Writer = std.Io.Writer;

const primary_commands =
    "ui demo record top why incident doctor help version";

const all_commands =
    "preflight capabilities advise incident report history timeline record " ++
    "snapshot ui bpf-gate daemon capture doctor demo watch top why metrics compare " ++
    "pressure cgroup verify validate completions version help";

fn commandList(args: []const []const u8) []const u8 {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--all")) return all_commands;
    }
    return primary_commands;
}

pub fn cmdCompletions(args: []const []const u8, out: *Writer, err: *Writer) !u8 {
    const shell = if (args.len == 0) "bash" else args[0];
    const commands = commandList(args);
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
        return 0;
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
        return 0;
    }
    if (std.mem.eql(u8, shell, "fish")) {
        var it = std.mem.tokenizeScalar(u8, commands, ' ');
        while (it.next()) |command| {
            try out.print("complete -c xsprof -f -n '__fish_use_subcommand' -a {s}\n", .{command});
        }
        return 0;
    }
    try err.writeAll("completions: supported shells are bash, zsh, fish\n");
    return 2;
}

// Checks the primary set leads with ui and that --all exposes automation verbs.
test "completions primary set is UI-first and --all is complete" {
    var buffer: [2048]u8 = undefined;
    var writer = Writer.fixed(&buffer);
    var err_buffer: [128]u8 = undefined;
    var err = Writer.fixed(&err_buffer);
    try std.testing.expectEqual(@as(u8, 0), try cmdCompletions(&.{"bash"}, &writer, &err));
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "ui") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "top") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "demo") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "advise") == null);

    var all_buffer: [2048]u8 = undefined;
    var all_writer = Writer.fixed(&all_buffer);
    try std.testing.expectEqual(
        @as(u8, 0),
        try cmdCompletions(&.{ "bash", "--all" }, &all_writer, &err),
    );
    try std.testing.expect(std.mem.indexOf(u8, all_writer.buffered(), "advise") != null);
    try std.testing.expect(std.mem.indexOf(u8, all_writer.buffered(), "verify") != null);
}
