const std = @import("std");
const sim_app = @import("sim_cli_app.zig");
const tui = @import("tui_root");

const Dispatch = enum {
    tui,
    sim,
};

const top_usage =
    "usage: zig-scheduler [sim <legacy-sim-args> | <tui-args>]\n" ++
    "\n" ++
    "default behavior launches the TUI, making it the main interface.\n" ++
    "use `zig-scheduler sim ...` for the legacy simulator CLI.\n";

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const args = argv[1..];

    switch (dispatch(args)) {
        .tui => try runTui(allocator, args),
        .sim => {
            const sim_args = args[1..];
            sim_app.runWithArgs(allocator, sim_args) catch |err| {
                switch (err) {
                    error.InvalidArguments, error.InvalidPolicy => {
                        var stderr_buffer: [1024]u8 = undefined;
                        var stderr_writer = std.Io.File.stderr().writer(std.Io.Threaded.global_single_threaded.io(), &stderr_buffer);
                        try sim_app.writeUsage(&stderr_writer.interface, "zig-scheduler sim");
                        try stderr_writer.interface.flush();
                        return;
                    },
                    else => return err,
                }
            };
        },
    }
}

fn runTui(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const options = tui.parseArgs(args) catch {
        try writeTuiUsage();
        return;
    };

    tui.run(allocator, options) catch |err| {
        switch (err) {
            error.NotATerminal => {
                try std.Io.File.stderr().writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), "zig-scheduler interactive mode requires a TTY; use --snapshot for redirected output\n");
                return;
            },
            error.NonTtyDashboardRequiresSnapshot => {
                try std.Io.File.stderr().writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), "zig-scheduler without a TTY needs an explicit source plus --snapshot, e.g. --stdin --snapshot or --input <report.json> --snapshot\n");
                return;
            },
            error.InvalidArguments => {
                try writeTuiUsage();
                return;
            },
            else => return err,
        }
    };
}

fn writeTuiUsage() !void {
    try std.Io.File.stderr().writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), "\n");
    try std.Io.File.stderr().writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), top_usage);
    try std.Io.File.stderr().writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), "\n");
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(std.Io.Threaded.global_single_threaded.io(), &stderr_buffer);
    try tui.writeUsage(&stderr_writer.interface, "zig-scheduler");
    try stderr_writer.interface.flush();
}

fn dispatch(args: []const []const u8) Dispatch {
    if (args.len == 0) return .tui;
    if (std.mem.eql(u8, args[0], "sim")) return .sim;
    return .tui;
}

test "dispatch routes main interface to tui by default" {
    try std.testing.expectEqual(Dispatch.tui, dispatch(&.{}));
    try std.testing.expectEqual(Dispatch.tui, dispatch(&.{ "--scenario-file", "scenarios/basic/multicore-contention.zon", "--policy", "fcfs" }));
    try std.testing.expectEqual(Dispatch.tui, dispatch(&.{ "--input", "docs/examples/exports/multicore-contention-fcfs.report.json", "--snapshot" }));
}

test "dispatch preserves legacy simulator subcommand only" {
    try std.testing.expectEqual(Dispatch.sim, dispatch(&.{"sim"}));
    try std.testing.expectEqual(Dispatch.tui, dispatch(&.{"list"}));
    try std.testing.expectEqual(Dispatch.tui, dispatch(&.{ "show", "short-vs-long" }));
}
