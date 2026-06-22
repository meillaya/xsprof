const std = @import("std");
const args = @import("args.zig");
const helpers = @import("bridge_helpers.zig");
const live_controller = @import("live_controller.zig");

const Options = args.Options;

pub fn write(allocator: std.mem.Allocator, io: std.Io, out: *std.Io.Writer, options: Options, method: []const u8) !bool {
    if (std.mem.eql(u8, method, "run")) return writeRun(allocator, io, out, options);
    if (std.mem.eql(u8, method, "timeout-run")) return writeTimeoutRun(allocator, io, out, options);
    if (std.mem.eql(u8, method, "duplicate-run")) return writeDuplicateRun(allocator, io, out, options);
    if (std.mem.eql(u8, method, "stale-rollback")) return writeStaleRollback(allocator, io, out, options);
    if (std.mem.eql(u8, method, "status")) return writeStatus(allocator, out, options);
    if (std.mem.eql(u8, method, "subscribe")) return writeSubscribe(out);
    if (std.mem.eql(u8, method, "rollback")) return writeRollback(allocator, io, out, options);
    if (std.mem.eql(u8, method, "stop") or std.mem.eql(u8, method, "gui-stop")) return writeStop(allocator, io, out, options, method);
    return false;
}

fn writeRun(allocator: std.mem.Allocator, io: std.Io, out: *std.Io.Writer, options: Options) !bool {
    const daemon_path = options.fake_daemon_path orelse options.daemon_bin;
    if (!live_controller.isValidDaemonPath(daemon_path)) {
        try out.print("incident refused bridge_test method=run reason=invalid_daemon_path host_mutation=false\n", .{});
        return true;
    }
    var controller = live_controller.Controller.init(allocator, .{ .daemon_path = daemon_path, .state_dir = options.state_dir });
    defer controller.deinit();
    try controller.statusJson(out);
    const run_status = try controller.run(io);
    try out.print("bridge_test method=run controller_status={s} host_mutation=false active_action_id={s} rollback_id={s}\n", .{ @tagName(run_status), controller.active_action_id, controller.rollback_id });
    const target = controller.active_action_id;
    if (run_status == .accepted and target.len != 0) {
        const rollback_status = try controller.rollback(io, target);
        try out.print("bridge_test method=rollback controller_status={s} host_mutation=false target_action_id={s} rollback_id={s}\n", .{ @tagName(rollback_status), target, controller.rollback_id });
    }
    try helpers.writeControllerHistory(out, &controller);
    try controller.statusJson(out);
    return true;
}

fn writeTimeoutRun(allocator: std.mem.Allocator, io: std.Io, out: *std.Io.Writer, options: Options) !bool {
    const daemon_path = options.fake_daemon_path orelse options.daemon_bin;
    if (!live_controller.isValidDaemonPath(daemon_path)) {
        try out.print("incident refused bridge_test method=timeout-run reason=invalid_daemon_path host_mutation=false\n", .{});
        return true;
    }
    var controller = live_controller.Controller.init(allocator, .{ .daemon_path = daemon_path, .state_dir = options.state_dir, .stream_timeout_ms = 200 });
    defer controller.deinit();
    try controller.statusJson(out);
    const run_status = try controller.run(io);
    try out.print("bridge_test method=timeout-run controller_status={s} child_terminated={} host_mutation=false active_action_id={s}\n", .{ @tagName(run_status), controller.last_child_was_terminated, controller.active_action_id });
    try helpers.writeControllerHistory(out, &controller);
    try controller.statusJson(out);
    return true;
}

fn writeDuplicateRun(allocator: std.mem.Allocator, io: std.Io, out: *std.Io.Writer, options: Options) !bool {
    var controller = live_controller.Controller.init(allocator, .{ .daemon_path = options.fake_daemon_path orelse options.daemon_bin, .state_dir = options.state_dir });
    defer controller.deinit();
    controller.active_action_id = try allocator.dupe(u8, "desktop-run-duplicate");
    controller.rollback_id = try allocator.dupe(u8, "RB-desktop-run-duplicate");
    controller.audit_id = try allocator.dupe(u8, "AUD-desktop-duplicate");
    controller.daemon_alive = true;
    const status = try controller.run(io);
    try out.print("bridge_test method=duplicate-run controller_status={s} host_mutation=false\n", .{@tagName(status)});
    try helpers.writeControllerHistory(out, &controller);
    try controller.statusJson(out);
    return true;
}

fn writeStaleRollback(allocator: std.mem.Allocator, io: std.Io, out: *std.Io.Writer, options: Options) !bool {
    var controller = live_controller.Controller.init(allocator, .{ .daemon_path = options.fake_daemon_path orelse options.daemon_bin, .state_dir = options.state_dir });
    defer controller.deinit();
    try helpers.seedActiveDesktopRun(allocator, &controller);
    const status = try controller.rollback(io, "desktop-run-stale");
    try out.print("bridge_test method=stale-rollback controller_status={s} host_mutation=false\n", .{@tagName(status)});
    try helpers.writeControllerHistory(out, &controller);
    try controller.statusJson(out);
    return true;
}

fn writeStatus(allocator: std.mem.Allocator, out: *std.Io.Writer, options: Options) !bool {
    var controller = live_controller.Controller.init(allocator, .{ .daemon_path = options.fake_daemon_path orelse options.daemon_bin, .state_dir = options.state_dir });
    defer controller.deinit();
    try out.print("bridge_test method=status controller_status=accepted bridge_mode=webkitgtk-script-message host_mutation=false contract=status,run,rollback,stop,subscribe\n", .{});
    try controller.statusJson(out);
    return true;
}

fn writeSubscribe(out: *std.Io.Writer) !bool {
    try out.print("bridge_test method=subscribe controller_status=accepted bridge_mode=webkitgtk-script-message subscription=event_history host_mutation=false contract=status,run,rollback,stop,subscribe\n", .{});
    return true;
}

fn writeRollback(allocator: std.mem.Allocator, io: std.Io, out: *std.Io.Writer, options: Options) !bool {
    var controller = live_controller.Controller.init(allocator, .{ .daemon_path = options.fake_daemon_path orelse options.daemon_bin, .state_dir = options.state_dir });
    defer controller.deinit();
    try helpers.seedActiveDesktopRun(allocator, &controller);
    const status = try controller.rollback(io, "desktop-run-1");
    try out.print("bridge_test method=rollback controller_status={s} bridge_mode=webkitgtk-script-message host_mutation=false target_action_id=desktop-run-1 rollback_id={s}\n", .{ @tagName(status), controller.rollback_id });
    try helpers.writeControllerHistory(out, &controller);
    try controller.statusJson(out);
    return true;
}

fn writeStop(allocator: std.mem.Allocator, io: std.Io, out: *std.Io.Writer, options: Options, method: []const u8) !bool {
    const daemon_path = options.fake_daemon_path orelse options.daemon_bin;
    if (!live_controller.isValidDaemonPath(daemon_path)) {
        try out.print("incident refused bridge_test method=stop reason=invalid_daemon_path host_mutation=false\n", .{});
        return true;
    }
    var controller = live_controller.Controller.init(allocator, .{ .daemon_path = daemon_path, .state_dir = options.state_dir });
    defer controller.deinit();
    try helpers.seedActiveDesktopRun(allocator, &controller);
    const status = try controller.stop(io, "desktop-run-1");
    try out.print("{s} method=stop controller_status={s} bridge_mode=webkitgtk-script-message host_mutation=false target_action_id=desktop-run-1 dispatched=stop_lab_run action_id_prefix=desktop-stop rollback_id={s}\n", .{
        if (std.mem.eql(u8, method, "gui-stop")) "gui_bridge" else "bridge_test",
        @tagName(status),
        controller.rollback_id,
    });
    try helpers.writeControllerHistory(out, &controller);
    try controller.statusJson(out);
    return true;
}
