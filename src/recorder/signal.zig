//! Async-signal-safe stop flag for the long-lived recorder. The handler only
//! stores one atomic; the capture loop performs all flushing and manifest
//! writes after it observes the flag.

const std = @import("std");
const builtin = @import("builtin");

var requested_flag = std.atomic.Value(bool).init(false);
var previous_term: std.posix.Sigaction = undefined;
var previous_int: std.posix.Sigaction = undefined;
var installed = false;

fn handleSignal(_: std.posix.SIG) callconv(.c) void {
    requested_flag.store(true, .release);
}

pub const Guard = struct {
    active: bool = false,

    pub fn deinit(self: *Guard) void {
        if (!self.active or !installed) return;
        std.posix.sigaction(.TERM, &previous_term, null);
        std.posix.sigaction(.INT, &previous_int, null);
        installed = false;
        self.active = false;
    }
};

pub fn install() Guard {
    if (builtin.os.tag != .linux) return .{};
    requested_flag.store(false, .release);
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = handleSignal },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.RESTART,
    };
    std.posix.sigaction(.TERM, &action, &previous_term);
    std.posix.sigaction(.INT, &action, &previous_int);
    installed = true;
    return .{ .active = true };
}

pub fn requested() bool {
    return requested_flag.load(.acquire);
}

test "stop flag starts clear" {
    if (builtin.os.tag == .linux) try std.testing.expect(!requested());
}
