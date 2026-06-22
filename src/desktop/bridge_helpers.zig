const std = @import("std");
const live_controller = @import("live_controller.zig");

pub fn seedActiveDesktopRun(allocator: std.mem.Allocator, controller: *live_controller.Controller) !void {
    const active_action_id = try allocator.dupe(u8, "desktop-run-1");
    errdefer allocator.free(active_action_id);
    const rollback_id = try allocator.dupe(u8, "RB-desktop-run-1");
    errdefer allocator.free(rollback_id);
    const audit_id = try allocator.dupe(u8, "AUD-desktop-1");
    controller.active_action_id = active_action_id;
    controller.rollback_id = rollback_id;
    controller.audit_id = audit_id;
    controller.daemon_alive = true;
}

pub fn writeControllerHistory(out: *std.Io.Writer, controller: *const live_controller.Controller) !void {
    for (controller.history.items) |record| {
        try out.writeAll(record.line);
        try out.writeByte('\n');
    }
}

pub fn writeBridgeRefusal(out: *std.Io.Writer, method: []const u8) !void {
    try out.print(
        "incident refused bridge_test method={s} reason=unsupported_bridge_method host_mutation=false bridge_mode=webkitgtk-script-message accepted=false contract=status,run,rollback,stop,subscribe\n",
        .{method},
    );
}
