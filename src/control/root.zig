pub const protocol = @import("protocol.zig");
pub const state = @import("state.zig");
pub const commands = @import("commands.zig");
pub const daemon = @import("daemon.zig");
pub const daemon_dispatch = @import("daemon_dispatch.zig");
pub const daemon_support = @import("daemon_support.zig");
pub const lab_runner = @import("lab_runner.zig");
pub const journal = @import("journal.zig");
pub const stream = @import("stream.zig");
pub const rollback = @import("rollback.zig");

test "control protocol tests are linked" {
    @import("std").testing.refAllDecls(@import("protocol_tests.zig"));
}

test "control command tests are linked" {
    @import("std").testing.refAllDecls(@import("commands_tests.zig"));
}
