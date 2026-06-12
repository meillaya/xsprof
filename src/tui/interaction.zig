const std = @import("std");
const linux = @import("linux_scheduler");

const protocol = linux.control.protocol;

pub fn actionForKey(key: u8) ?protocol.OperatorAction {
    return switch (key) {
        'r' => .{ .kind = .run_lab_host_safe, .run_id = "tui-test-run" },
        'v' => .{ .kind = .verifier_only, .run_id = "tui-test-verifier" },
        'p' => .{ .kind = .partial_attach, .run_id = "tui-test-partial" },
        'o' => .{ .kind = .observe, .run_id = "tui-test-observe" },
        's' => .{ .kind = .stop, .run_id = "tui-test-stop" },
        'b' => .{ .kind = .rollback, .run_id = "tui-test-rollback" },
        else => null,
    };
}

pub fn statusForAction(action: ?protocol.OperatorAction) []const u8 {
    const selected = action orelse return "ACTION idle typed queue empty";
    return switch (selected.kind) {
        .preflight => "ACTION queued preflight",
        .run_lab_host_safe => "ACTION queued run_lab_host_safe",
        .run_lab_vm => "ACTION queued run_lab_vm",
        .verifier_only => "ACTION queued verifier_only",
        .partial_attach => "ACTION queued partial_attach",
        .observe => "ACTION queued observe",
        .stop => "ACTION queued stop",
        .rollback => "ACTION queued rollback",
    };
}

test "interactive TUI maps r to typed host-safe lab action" {
    const action = actionForKey('r') orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(protocol.ActionKind.run_lab_host_safe, action.kind);
    try std.testing.expectEqualStrings("ACTION queued run_lab_host_safe", statusForAction(action));
}

test "interactive TUI ignores unknown keys instead of executing commands" {
    try std.testing.expect(actionForKey('!') == null);
}
