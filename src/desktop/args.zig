const std = @import("std");
const linux_webview = @import("linux_webview.zig");
const live_controller = @import("live_controller.zig");

pub const safety_markers = "mode=vm-lab-only host_mutation=false production_ready=false";

pub const Options = struct {
    smoke: bool = false,
    headless_test: bool = false,
    dump_html: bool = false,
    bridge_test: ?[]const u8 = null,
    state_dir: []const u8 = "/tmp/zig-scheduler-live-vm-desktop/state",
    daemon_bin: []const u8 = "zig-out/bin/zig-scheduler-daemon",
    fake_daemon: bool = false,
    fake_daemon_path: ?[]const u8 = null,
    force_qemu_missing: bool = false,
};

pub fn parse(args: []const []const u8) !Options {
    var options = Options{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--smoke")) {
            options.smoke = true;
        } else if (std.mem.eql(u8, arg, "--headless-test")) {
            options.headless_test = true;
        } else if (std.mem.eql(u8, arg, "--dump-html")) {
            options.dump_html = true;
        } else if (std.mem.eql(u8, arg, "--bridge-test")) {
            options.bridge_test = try nextArg(args, &index);
        } else if (std.mem.eql(u8, arg, "--state-dir")) {
            options.state_dir = try nextArg(args, &index);
        } else if (std.mem.eql(u8, arg, "--daemon-bin")) {
            options.daemon_bin = try nextArg(args, &index);
        } else if (std.mem.eql(u8, arg, "--fake-daemon")) {
            options.fake_daemon = true;
            if (index + 1 < args.len and !std.mem.startsWith(u8, args[index + 1], "--")) {
                index += 1;
                const path = try validateFlagValue(args[index]);
                if (!live_controller.isValidDaemonPath(path)) return error.InvalidDaemonPath;
                options.fake_daemon_path = path;
            }
        } else if (std.mem.eql(u8, arg, "--force-qemu-missing")) {
            options.force_qemu_missing = true;
        } else if (std.mem.eql(u8, arg, "--help")) {
            return error.HelpRequested;
        } else {
            return error.UnknownFlag;
        }
    }
    if (options.fake_daemon_path != null) options.fake_daemon = true;
    try linux_webview.validateStateDir(options.state_dir);
    return options;
}
fn nextArg(args: []const []const u8, index: *usize) ![]const u8 {
    index.* += 1;
    if (index.* >= args.len) return error.MissingFlagValue;
    if (std.mem.startsWith(u8, args[index.*], "--")) return error.MissingFlagValue;
    return validateFlagValue(args[index.*]);
}

fn validateFlagValue(value: []const u8) ![]const u8 {
    if (value.len == 0) return error.MalformedFlagValue;
    for (value) |byte| {
        if (byte <= 0x20 or byte == 0x7f or byte == '=' or byte == '"' or byte == '\'' or byte == '`') {
            return error.MalformedFlagValue;
        }
    }
    return value;
}

pub fn writeUsageAndRefusal(err: anyerror) !void {
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(std.Io.Threaded.global_single_threaded.io(), &stderr_buffer);
    const out = &stderr_writer.interface;
    if (err != error.HelpRequested) {
        try out.print("refused fail-closed live-vm-desktop arguments: {s}; {s}\n", .{ @errorName(err), safety_markers });
    }
    try out.print(
        "usage: zig-scheduler-live-vm-desktop [--smoke] [--headless-test] [--dump-html] [--bridge-test <method>] [--state-dir <dir>] [--daemon-bin <path>] [--fake-daemon [path]]\n\n" ++
            "VM-lab-only desktop shell for the live microVM lab. It does not mutate host scheduler, cgroups, /sys, /proc/sys, BPF, affinities, or priorities.\n" ++
            "--dump-html writes the bundled offline WebView HTML to stdout without launching GUI.\n" ++
            "--bridge-test <method> validates the strict JS-to-Zig bridge contract without launching GUI.\n" ++
            "--smoke is non-GUI and prints: {s}\n",
        .{safety_markers},
    );
    try stderr_writer.interface.flush();
}
test "desktop args accept required task 3 flags" {
    const options = try parse(&.{
        "--smoke",
        "--state-dir",
        "/tmp/zig-scheduler-live-vm-desktop/task-03-state",
        "--daemon-bin",
        "zig-out/bin/zig-scheduler-daemon",
        "--fake-daemon",
        "tools/tui_pty_authoritative_daemon.py",
        "--headless-test",
        "--dump-html",
    });
    try std.testing.expect(options.smoke);
    try std.testing.expect(options.headless_test);
    try std.testing.expect(options.dump_html);
    try std.testing.expectEqualStrings("/tmp/zig-scheduler-live-vm-desktop/task-03-state", options.state_dir);
    try std.testing.expectEqualStrings("zig-out/bin/zig-scheduler-daemon", options.daemon_bin);
    try std.testing.expect(options.fake_daemon);
    try std.testing.expectEqualStrings("tools/tui_pty_authoritative_daemon.py", options.fake_daemon_path.?);
}

test "desktop args fail closed on unknown and missing values" {
    try std.testing.expectError(error.UnknownFlag, parse(&.{"--launch-production"}));
    try std.testing.expectError(error.MissingFlagValue, parse(&.{"--state-dir"}));
    try std.testing.expectError(error.MissingFlagValue, parse(&.{ "--daemon-bin", "--smoke" }));
    try std.testing.expectError(error.InvalidStateDir, parse(&.{ "--state-dir", "/sys/fs/cgroup/zigsched-hostile" }));
    try std.testing.expectError(error.InvalidStateDir, parse(&.{ "--state-dir", "/proc/sys/zigsched-hostile" }));
    try std.testing.expectError(error.InvalidStateDir, parse(&.{ "--state-dir", "../zigsched-hostile" }));
    try std.testing.expectError(error.InvalidStateDir, parse(&.{ "--state-dir", "safe/cgroup/zigsched-hostile" }));
}

test "desktop args reject control characters in user flag values" {
    try std.testing.expectError(error.MalformedFlagValue, parse(&.{ "--state-dir", "ok\nhost_mutation=true production_ready=true" }));
    try std.testing.expectError(error.MalformedFlagValue, parse(&.{ "--daemon-bin", "zig-out/bin/daemon\twith-tab" }));
    try std.testing.expectError(error.MalformedFlagValue, parse(&.{ "--fake-daemon", "tools/tui_pty_authoritative_daemon.py\rproduction_ready=true" }));
    try std.testing.expectError(error.MalformedFlagValue, parse(&.{ "--fake-daemon", "tools/tui_pty_authoritative_daemon.py\x7f" }));
}

test "desktop args reject same-line injection characters in user flag values" {
    try std.testing.expectError(error.MalformedFlagValue, parse(&.{ "--state-dir", "" }));
    try std.testing.expectError(error.MalformedFlagValue, parse(&.{ "--state-dir", "ok host_mutation=true production_ready=true" }));
    try std.testing.expectError(error.MalformedFlagValue, parse(&.{ "--state-dir", "ok=host_mutation=false" }));
    try std.testing.expectError(error.MalformedFlagValue, parse(&.{ "--daemon-bin", "zig-out/bin/daemon=host_mutation=false" }));
    try std.testing.expectError(error.MalformedFlagValue, parse(&.{ "--fake-daemon", "fake-daemon.py=production_ready=false" }));
    try std.testing.expectError(error.MalformedFlagValue, parse(&.{ "--fake-daemon", "fake\"daemon.py" }));
    try std.testing.expectError(error.MalformedFlagValue, parse(&.{ "--fake-daemon", "fake'daemon.py" }));
    try std.testing.expectError(error.InvalidDaemonPath, parse(&.{ "--fake-daemon", "tools/unreviewed.py" }));
}

test "desktop args accept printable user flag values" {
    const options = try parse(&.{
        "--state-dir",
        "/tmp/zig-scheduler-live-vm-desktop/state",
        "--daemon-bin",
        "zig-out/bin/zig-scheduler-daemon",
        "--fake-daemon",
        "tools/tui_pty_authoritative_daemon.py",
    });
    try std.testing.expectEqualStrings("/tmp/zig-scheduler-live-vm-desktop/state", options.state_dir);
    try std.testing.expectEqualStrings("zig-out/bin/zig-scheduler-daemon", options.daemon_bin);
    try std.testing.expect(options.fake_daemon);
    try std.testing.expectEqualStrings("tools/tui_pty_authoritative_daemon.py", options.fake_daemon_path.?);
}
