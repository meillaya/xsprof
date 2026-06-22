const std = @import("std");
const args = @import("args.zig");
const helpers = @import("bridge_helpers.zig");
const live_controller = @import("live_controller.zig");

const Options = args.Options;

pub fn write(allocator: std.mem.Allocator, io: std.Io, out: *std.Io.Writer, options: Options, method: []const u8) !bool {
    if (std.mem.eql(u8, method, "gui-run")) {
        try writeRun(allocator, io, out, options);
        return true;
    }
    if (std.mem.eql(u8, method, "gui-duplicate-run")) {
        try writeDuplicateRun(allocator, io, out, options);
        return true;
    }
    if (std.mem.eql(u8, method, "gui-stale-rollback")) {
        try writeStaleRollback(allocator, io, out, options);
        return true;
    }
    return false;
}

fn writeRun(allocator: std.mem.Allocator, io: std.Io, out: *std.Io.Writer, options: Options) !void {
    const daemon_path = options.fake_daemon_path orelse options.daemon_bin;
    if (!live_controller.isValidDaemonPath(daemon_path)) {
        try out.print("gui_bridge method=run controller_status=incident qa_state=incident reason=invalid_daemon_path host_mutation=false\n", .{});
        return;
    }
    var controller = live_controller.Controller.init(allocator, .{
        .daemon_path = daemon_path,
        .state_dir = options.state_dir,
    });
    defer controller.deinit();
    const status = try controller.run(io);
    try out.print("gui_bridge method=run controller_status={s} qa_state=running controller_source=event_history host_mutation=false active_action_id={s} rollback_id={s}\n", .{
        @tagName(status),
        controller.active_action_id,
        controller.rollback_id,
    });
    try helpers.writeControllerHistory(out, &controller);
    try controller.statusJson(out);
}

fn writeDuplicateRun(allocator: std.mem.Allocator, io: std.Io, out: *std.Io.Writer, options: Options) !void {
    var controller = live_controller.Controller.init(allocator, .{
        .daemon_path = options.fake_daemon_path orelse options.daemon_bin,
        .state_dir = options.state_dir,
    });
    defer controller.deinit();
    try helpers.seedActiveDesktopRun(allocator, &controller);
    const status = try controller.run(io);
    try out.print("gui_bridge method=duplicate-run controller_status={s} qa_state=duplicate_refusal controller_source=event_history host_mutation=false\n", .{@tagName(status)});
    try helpers.writeControllerHistory(out, &controller);
    try controller.statusJson(out);
}

fn writeStaleRollback(allocator: std.mem.Allocator, io: std.Io, out: *std.Io.Writer, options: Options) !void {
    var controller = live_controller.Controller.init(allocator, .{
        .daemon_path = options.fake_daemon_path orelse options.daemon_bin,
        .state_dir = options.state_dir,
    });
    defer controller.deinit();
    controller.active_action_id = try allocator.dupe(u8, "desktop-run-1");
    controller.rollback_id = try allocator.dupe(u8, "RB-desktop-run-1");
    controller.audit_id = try allocator.dupe(u8, "AUD-desktop-1");
    const status = try controller.rollback(io, "desktop-run-stale");
    try out.print("gui_bridge method=stale-rollback controller_status={s} qa_state=stale_refusal controller_source=event_history host_mutation=false\n", .{@tagName(status)});
    try helpers.writeControllerHistory(out, &controller);
    try controller.statusJson(out);
}
