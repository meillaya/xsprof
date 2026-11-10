//! Human help rendering over the command table in `registry.zig`.
//!
//! No command list lives here: plain help shows visible commands grouped by
//! area, `help --all` shows every command grouped by area, and
//! `help <command>` prints the registry usage text. Unsafe verbs are listed in
//! their own REFUSED section from the same table.

const std = @import("std");
const registry = @import("registry.zig");

const Writer = std.Io.Writer;

pub fn writeQuickstart(w: *Writer) Writer.Error!void {
    try w.writeAll(
        \\▚ xsprof — read-only scheduler & memory profiler
        \\
        \\Open the console:
        \\  xsprof                          native console (terminal + display)
        \\  xsprof demo                     bundled capture in the native console
        \\
        \\Headless workflows:
        \\  xsprof record                   save a short capture
        \\  xsprof top                      live ranked scheduler view
        \\  xsprof why --last 10m --dir D   explain the recorder window
        \\  xsprof incident --last 10m      offline incident bundle
        \\  xsprof doctor                   human-readable host readiness
        \\
        \\Every command, grouped by area: xsprof help --all
        \\Safety: read-only; every record has host_mutation=false.
        \\
    );
}

pub fn writeCommand(w: *Writer, requested: []const u8, command: *const registry.Command) Writer.Error!void {
    if (!std.mem.eql(u8, requested, command.name)) {
        try w.print("xsprof {s}: alias of `xsprof {s}`\n\n", .{ requested, command.name });
    }
    try w.writeAll(command.usage);
    if (command.unsafe) {
        try w.writeAll("\nREFUSED before dispatch: xsprof is read-only and never elevates.\n");
    }
}

/// Plain help: usage, visible commands grouped by area, and the refusal/safety
/// contract. Secret-free and deterministic.
pub fn writeHelp(w: *Writer) Writer.Error!void {
    try w.writeAll(
        \\xsprof, read-only Linux scheduler & memory profiler
        \\USAGE:
        \\  xsprof                 open the console when a terminal + display exist
        \\  xsprof <command> ...   run a specific workflow
        \\PRIMARY COMMANDS:
        \\
    );
    try writeVisibleGroups(w);
    try w.writeAll(
        \\MORE:
        \\  help --all              every command, grouped by area
        \\  help <command>          detailed usage for one command
        \\  help --json --all       canonical CLI manifest (xsprof/cli-manifest/v1)
        \\
    );
    try writeSafety(w);
}

/// Full help: every dispatchable command grouped by area, then refused verbs.
pub fn writeAllHelp(w: *Writer) Writer.Error!void {
    try w.writeAll(
        \\xsprof, read-only Linux scheduler & memory profiler
        \\USAGE:
        \\  xsprof [<command>|ui] [options]
        \\COMMANDS:
        \\
    );
    for (registry.groups) |group| {
        try w.print("  {s}:\n", .{group.label()});
        for (registry.commands) |command| {
            if (command.group != group) continue;
            try w.print("    {s:<24}{s}\n", .{ command.name, command.summary });
        }
    }
    try writeSafety(w);
}

fn writeVisibleGroups(w: *Writer) Writer.Error!void {
    for (registry.groups) |group| {
        var printed_header = false;
        for (registry.commands) |command| {
            if (command.group != group or !command.visible) continue;
            if (!printed_header) {
                try w.print("  {s}:\n", .{group.label()});
                printed_header = true;
            }
            try w.print("    {s:<24}{s}\n", .{ command.name, command.summary });
        }
    }
}

fn writeSafety(w: *Writer) Writer.Error!void {
    try w.writeAll("REFUSED (unsafe verbs; non-zero exit on host by design):\n  ");
    var line_len: usize = 2;
    var first = true;
    for (registry.all_commands) |command| {
        if (!command.unsafe) continue;
        if (!first) {
            if (line_len + command.name.len + 1 > 78) {
                try w.writeAll("\n  ");
                line_len = 2;
            } else {
                try w.writeByte(' ');
                line_len += 1;
            }
        }
        try w.writeAll(command.name);
        line_len += command.name.len;
        first = false;
    }
    try w.writeAll(
        \\
        \\SAFETY:
        \\  Observation is read-only. Every record carries host_mutation=false.
        \\  Runtime samples never expose argv, environment, secrets, or tokens.
        \\
    );
}

test "plain help shows visible commands and hides automation-only verbs" {
    var buffer: [8 * 1024]u8 = undefined;
    var writer = Writer.fixed(&buffer);
    try writeHelp(&writer);
    const text = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "PRIMARY COMMANDS") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "advise") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "serve") == null);
    for (registry.commands) |command| {
        if (!command.visible) continue;
        try std.testing.expect(std.mem.indexOf(u8, text, command.name) != null);
    }
}

test "all help lists every command grouped by area and refuses unsafe verbs" {
    var buffer: [16 * 1024]u8 = undefined;
    var writer = Writer.fixed(&buffer);
    try writeAllHelp(&writer);
    const text = writer.buffered();
    for (registry.groups) |group| {
        try std.testing.expect(std.mem.indexOf(u8, text, group.label()) != null);
    }
    for (registry.commands) |command| {
        try std.testing.expect(std.mem.indexOf(u8, text, command.name) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, text, "REFUSED") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "serve") == null);
}
