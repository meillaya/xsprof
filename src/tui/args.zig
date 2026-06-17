const std = @import("std");

pub const Screen = enum { preflight, sched_ext, vm_lab, controller, observer, help };

pub const Options = struct {
    snapshot: bool = false,
    interactive: bool = false,
    test_mode: bool = false,
    screen: Screen = .preflight,
    width: u16 = 100,
    height: u16 = 30,
    fixture_path: ?[]const u8 = null,
    daemon_state_dir: ?[]const u8 = null,
    daemon_bin: []const u8 = "zig-out/bin/zig-scheduler-daemon",
};

pub fn parse(args: []const []const u8) !Options {
    var options = Options{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--snapshot")) {
            options.snapshot = true;
        } else if (std.mem.eql(u8, arg, "--interactive")) {
            options.interactive = true;
        } else if (std.mem.eql(u8, arg, "--test-mode")) {
            options.test_mode = true;
        } else if (std.mem.eql(u8, arg, "--screen")) {
            options.screen = try parseScreen(try nextArg(args, &index));
        } else if (std.mem.eql(u8, arg, "--width")) {
            options.width = try parseDimension(try nextArg(args, &index));
        } else if (std.mem.eql(u8, arg, "--height")) {
            options.height = try parseDimension(try nextArg(args, &index));
        } else if (std.mem.eql(u8, arg, "--fixture")) {
            options.fixture_path = try nextArg(args, &index);
        } else if (std.mem.eql(u8, arg, "--daemon-state-dir")) {
            options.daemon_state_dir = try nextArg(args, &index);
        } else if (std.mem.eql(u8, arg, "--daemon-bin")) {
            options.daemon_bin = try nextArg(args, &index);
        } else if (std.mem.eql(u8, arg, "--help")) {
            return error.InvalidArguments;
        } else {
            return error.InvalidArguments;
        }
    }
    if (options.snapshot == options.interactive) return error.InvalidArguments;
    if (options.test_mode and !options.interactive) return error.InvalidArguments;
    if (options.daemon_state_dir != null and !options.interactive) return error.InvalidArguments;
    if (options.width < 80 or options.height < 8) return error.InvalidArguments;
    return options;
}

pub fn writeUsage(writer: anytype, exe_name: []const u8) !void {
    try writer.print(
        "usage: {s} (--snapshot|--interactive [--test-mode]) [--daemon-state-dir <dir>] [--daemon-bin <path>] [--fixture <preflight.json>] --screen preflight|sched-ext|vm-lab|controller|observer|help [--width <cols>] [--height <rows>]\n\n" ++
            "First-class live VM lab entrypoint:\n" ++
            "  zig build tui-live-vm\n" ++
            "  zig build tui-live-vm -- --help\n\n" ++
            "Default tui-live-vm command expands to this installed-binary command:\n" ++
            "  zig-out/bin/zig-scheduler-tui --interactive --screen vm-lab --daemon-state-dir .omo/evidence/tui-live-vm --daemon-bin zig-out/bin/zig-scheduler-daemon\n\n" ++
            "The TUI does not attach sched_ext on the host. A live lab requires QEMU/KVM, bpftool/libbpf, BTF, a sched_ext-capable kernel tuple, and a disposable VM bundle.\n" ++
            "Keys: m starts the VM lab action, b/b rolls back, s/s safe-stops then rolls back, q quits.\n",
        .{exe_name},
    );
}

pub fn screenTitle(screen: Screen) []const u8 {
    return switch (screen) {
        .preflight => "operator dashboard home",
        .sched_ext => "sched_ext Readiness",
        .vm_lab => "live microVM lab",
        .controller => "Controller Dry Run",
        .observer => "Observer",
        .help => "Help",
    };
}

fn parseScreen(raw: []const u8) !Screen {
    if (std.mem.eql(u8, raw, "preflight")) return .preflight;
    if (std.mem.eql(u8, raw, "sched-ext")) return .sched_ext;
    if (std.mem.eql(u8, raw, "vm-lab")) return .vm_lab;
    if (std.mem.eql(u8, raw, "controller")) return .controller;
    if (std.mem.eql(u8, raw, "observer")) return .observer;
    if (std.mem.eql(u8, raw, "help")) return .help;
    return error.InvalidArguments;
}

fn nextArg(args: []const []const u8, index: *usize) ![]const u8 {
    index.* += 1;
    if (index.* >= args.len) return error.InvalidArguments;
    return args[index.*];
}

fn parseDimension(raw: []const u8) !u16 {
    const value = std.fmt.parseUnsigned(u16, raw, 10) catch return error.InvalidArguments;
    if (value == 0) return error.InvalidArguments;
    return value;
}

test "tui args parse daemon options only in interactive mode" {
    const options = try parse(&.{ "--interactive", "--daemon-state-dir", ".omo/evidence/tui-daemon", "--daemon-bin", "zig-out/bin/zig-scheduler-daemon" });
    try std.testing.expect(options.interactive);
    try std.testing.expectEqualStrings(".omo/evidence/tui-daemon", options.daemon_state_dir.?);
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "--snapshot", "--daemon-state-dir", ".omo/evidence/tui-daemon" }));
}

test "tui usage documents live VM lab command without host attach claim" {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(std.testing.allocator, &buffer);
    try writeUsage(&writer.writer, "zig-scheduler-tui");
    buffer = writer.toArrayList();
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "zig build tui-live-vm -- --help") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "zig-out/bin/zig-scheduler-tui --interactive --screen vm-lab") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "does not attach sched_ext on the host") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "QEMU/KVM") != null);
}
