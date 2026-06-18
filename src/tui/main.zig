const std = @import("std");
const tui = @import("linux_scheduler_tui");

const live_poll_timeout_ms: i32 = 250;
const live_idle_timeout_polls: usize = 40;
const active_control_poll_timeout_ms: i32 = 100;
const active_control_timeout_polls: usize = 20;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (argv.len > 1 and (std.mem.eql(u8, argv[1], "--help") or std.mem.eql(u8, argv[1], "help"))) {
        var stdout_buffer: [2048]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &stdout_buffer);
        try tui.writeUsage(&stdout_writer.interface, "zig-scheduler-tui");
        try stdout_writer.interface.flush();
        return;
    }
    const options = tui.parseArgs(argv[1..]) catch {
        var stderr_buffer: [1024]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writer(std.Io.Threaded.global_single_threaded.io(), &stderr_buffer);
        try tui.writeUsage(&stderr_writer.interface, "zig-scheduler-tui");
        try stderr_writer.interface.flush();
        std.process.exit(2);
    };
    if (options.interactive) return runInteractive(allocator, init.io, options);

    const frame = try tui.renderSnapshot(allocator, options);
    defer allocator.free(frame);
    try writeStdout(frame);
}

fn runInteractive(allocator: std.mem.Allocator, io: std.Io, options: tui.Options) !void {
    const original_termios = enableRawMode();
    defer if (original_termios) |original| std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, original) catch {};

    var current_options = options;
    const initial = try tui.renderInteractive(allocator, current_options, null);
    defer allocator.free(initial);
    try writeStdout(initial);

    var control_state = tui.interaction.ControlState{};
    var stdin_buffer: [64]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().readerStreaming(std.Io.Threaded.global_single_threaded.io(), &stdin_buffer);
    while (true) {
        const key = stdin_reader.interface.takeByte() catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (key == 3) break;
        const result = tui.interaction.controlForKey(key, &control_state, current_options.test_mode) orelse continue;
        applyNavigation(key, &current_options);
        if (result == .action and result.action.kind == .run_lab_microvm_live and current_options.daemon_state_dir != null) {
            if (try runLiveVmEventLoop(allocator, io, current_options, result.action, &control_state)) break;
            continue;
        }
        const status = try controlStatus(allocator, io, current_options, result);
        defer status.deinit(allocator);
        const frame = try tui.renderInteractiveStatus(allocator, current_options, status.text);
        defer allocator.free(frame);
        try writeStdout("\n");
        try writeStdout(frame);
        if (key == 'q') break;
    }
}

fn runLiveVmEventLoop(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: tui.Options,
    action: tui.OperatorAction,
    control_state: *tui.interaction.ControlState,
) !bool {
    var store = tui.live_store.Store.init(allocator);
    defer store.deinit();
    try store.appendControlStatus(.queued, "[queued] VM run queued", action.action_id);
    try renderLiveStore(allocator, options, &store, "RUNNING live VM queued");

    var session = tui.daemon_adapter.startLive(allocator, io, options, action) catch {
        try store.appendControlStatus(.incident, "INCIDENT qemu_unavailable", action.action_id);
        try renderLiveStore(allocator, options, &store, "INCIDENT qemu_unavailable");
        return false;
    };
    defer session.deinit(allocator, io);

    var running = true;
    var quit_requested = false;
    var saw_eof = false;
    var idle_polls: usize = 0;
    while (running) {
        var fds = [_]std.posix.pollfd{
            .{ .fd = std.posix.STDIN_FILENO, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = session.stdoutFd(), .events = std.posix.POLL.IN | std.posix.POLL.HUP, .revents = 0 },
        };
        const ready = std.posix.poll(&fds, live_poll_timeout_ms) catch 0;
        if (ready == 0) {
            idle_polls += 1;
            if (idle_polls >= live_idle_timeout_polls) {
                try store.appendControlStatus(.incident, "INCIDENT timeout", action.action_id);
                try renderLiveStore(allocator, options, &store, "INCIDENT timeout");
                session.terminate(io);
                quit_requested = true;
                running = false;
                continue;
            }
            try renderLiveStore(allocator, options, &store, "RUNNING live VM active");
            continue;
        }
        if ((fds[1].revents & (std.posix.POLL.IN | std.posix.POLL.HUP)) != 0) {
            const chunk = session.readAvailable(allocator, io) catch {
                try store.appendControlStatus(.incident, "INCIDENT lost_stream", action.action_id);
                try renderLiveStore(allocator, options, &store, "INCIDENT lost_stream");
                break;
            };
            defer allocator.free(chunk);
            if (chunk.len == 0) {
                saw_eof = true;
            } else {
                idle_polls = 0;
                try store.applyChunk(chunk);
                try renderLiveStore(allocator, options, &store, liveStatusText(&store));
            }
        }
        if ((fds[0].revents & std.posix.POLL.IN) != 0) {
            var byte: [1]u8 = undefined;
            const n = std.posix.read(std.posix.STDIN_FILENO, &byte) catch 0;
            if (n == 1) {
                switch (byte[0]) {
                    3, 'q' => {
                        try drainSessionOutput(allocator, io, &session, &store, 200);
                        try store.appendControlStatus(.cleanup_running, "[cleanup] cleanup running", action.action_id);
                        try renderLiveStore(allocator, options, &store, liveStatusText(&store));
                        quit_requested = true;
                        running = false;
                    },
                    's' => {
                        try drainSessionOutput(allocator, io, &session, &store, 200);
                        try activeStop(allocator, io, options, &store, &session, control_state);
                    },
                    'b' => {
                        try drainSessionOutput(allocator, io, &session, &store, 200);
                        try activeRollback(allocator, io, options, &store, &session, control_state);
                    },
                    'j' => try scrubEvent(&store, 1),
                    'k' => try scrubEvent(&store, -1),
                    else => {},
                }
            }
        }
        if (saw_eof) {
            try store.flushPendingLine();
            const term = session.wait(io) catch std.process.Child.Term{ .exited = 1 };
            if (term != .exited or term.exited != 0) {
                try store.appendControlStatus(.incident, "INCIDENT process_exit_unexpected", action.action_id);
                quit_requested = true;
            } else if (isValidatedClean(&store)) {
                try store.appendControlStatus(.safe, "[SAFE] footer mode SAFE", action.action_id);
            } else if (store.incidents.items.len == 0) {
                try store.appendControlStatus(.incident, "INCIDENT lost_stream", action.action_id);
                quit_requested = true;
            }
            try renderLiveStore(allocator, options, &store, liveStatusText(&store));
            break;
        }
    }
    if (isValidatedClean(&store)) {
        try store.appendControlStatus(.safe, "[SAFE] footer mode SAFE", action.action_id);
        try renderLiveStore(allocator, options, &store, "SAFE");
    } else if (store.phase != .incident) {
        try store.appendControlStatus(.cleanup_running, "[cleanup] cleanup running", action.action_id);
        try renderLiveStore(allocator, options, &store, "CLEANUP");
    } else {
        try renderLiveStore(allocator, options, &store, "INCIDENT");
    }
    return quit_requested;
}

fn isValidatedClean(store: *const tui.live_store.Store) bool {
    return store.phase != .incident and
        store.incidents.items.len == 0 and
        (store.phase == .validated or store.phase == .safe or store.lanes.validation.status == .pass) and
        store.lanes.cleanup.status == .pass;
}

fn liveStatusText(store: *const tui.live_store.Store) []const u8 {
    if (store.incidents.items.len != 0) return "INCIDENT";
    return @tagName(store.footer_mode);
}

fn activeStop(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: tui.Options,
    store: *tui.live_store.Store,
    session: *tui.daemon_adapter.LiveSession,
    state: *tui.interaction.ControlState,
) !void {
    if (state.stop_sent) {
        try store.appendControlRefusal(.duplicate_action_id, "tui-stop-active");
        try renderLiveStore(allocator, options, store, liveStatusText(store));
        return;
    }
    if (state.lab_action_id.len == 0 or state.rollback_id.len == 0 or store.active_run == null) {
        try store.appendControlRefusal(.stale_action_id, "tui-stop-active");
        try renderLiveStore(allocator, options, store, liveStatusText(store));
        return;
    }
    state.stop_sent = true;
    const action = tui.OperatorAction{
        .kind = .stop_lab_run,
        .action_id = "tui-stop-active",
        .run_id = "tui-stop-active",
        .audit_id = state.audit_id,
        .rollback_id = state.rollback_id,
        .target_action_id = state.lab_action_id,
    };
    try store.appendControlStatus(.cleanup_running, "[cleanup] stop requested", action.action_id);
    try renderLiveStore(allocator, options, store, liveStatusText(store));
    try dispatchActiveControl(allocator, io, options, store, session, action);
}

fn activeRollback(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: tui.Options,
    store: *tui.live_store.Store,
    session: *tui.daemon_adapter.LiveSession,
    state: *tui.interaction.ControlState,
) !void {
    if (state.rollback_sent) {
        try store.appendControlRefusal(.duplicate_action_id, "tui-rollback-active");
        try renderLiveStore(allocator, options, store, liveStatusText(store));
        return;
    }
    if (state.lab_action_id.len == 0 or state.rollback_id.len == 0 or store.active_run == null) {
        try store.appendControlRefusal(.stale_action_id, "tui-rollback-active");
        try renderLiveStore(allocator, options, store, liveStatusText(store));
        return;
    }
    state.rollback_sent = true;
    const action = tui.OperatorAction{
        .kind = .rollback_lab_run,
        .action_id = "tui-rollback-active",
        .run_id = "tui-rollback-active",
        .audit_id = state.audit_id,
        .rollback_id = state.rollback_id,
        .target_action_id = state.lab_action_id,
    };
    try store.appendControlStatus(.rollback_requested, "[rollback] rollback requested", action.action_id);
    try store.appendControlStatus(.rollback_running, "[rollback] rollback running", action.action_id);
    try renderLiveStore(allocator, options, store, liveStatusText(store));
    try dispatchActiveControl(allocator, io, options, store, session, action);
}

fn dispatchActiveControl(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: tui.Options,
    store: *tui.live_store.Store,
    live_session: *tui.daemon_adapter.LiveSession,
    action: tui.OperatorAction,
) !void {
    var control_session = tui.daemon_adapter.startControl(allocator, io, options, action) catch {
        try store.appendControlStatus(.incident, "INCIDENT lost_stream", action.action_id);
        try renderLiveStore(allocator, options, store, liveStatusText(store));
        return;
    };
    defer control_session.deinit(allocator, io);

    var idle_polls: usize = 0;
    while (true) {
        var fds = [_]std.posix.pollfd{
            .{ .fd = live_session.stdoutFd(), .events = std.posix.POLL.IN | std.posix.POLL.HUP, .revents = 0 },
            .{ .fd = control_session.stdoutFd(), .events = std.posix.POLL.IN | std.posix.POLL.HUP, .revents = 0 },
        };
        const ready = std.posix.poll(&fds, active_control_poll_timeout_ms) catch 0;
        if (ready == 0) {
            idle_polls += 1;
            if (idle_polls >= active_control_timeout_polls) {
                try store.appendControlStatus(.incident, "INCIDENT timeout", action.action_id);
                control_session.terminate(io);
                try renderLiveStore(allocator, options, store, liveStatusText(store));
                return;
            }
            try renderLiveStore(allocator, options, store, liveStatusText(store));
            continue;
        }
        var made_progress = false;
        if ((fds[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP)) != 0) {
            const live_chunk = live_session.readAvailable(allocator, io) catch {
                try store.appendControlStatus(.incident, "INCIDENT lost_stream", action.action_id);
                try renderLiveStore(allocator, options, store, liveStatusText(store));
                return;
            };
            defer allocator.free(live_chunk);
            if (live_chunk.len != 0) {
                made_progress = true;
                try store.applyChunk(live_chunk);
                try renderLiveStore(allocator, options, store, liveStatusText(store));
            }
        }
        if ((fds[1].revents & (std.posix.POLL.IN | std.posix.POLL.HUP)) != 0) {
            const control_chunk = control_session.readAvailable(allocator, io) catch {
                try store.appendControlStatus(.incident, "INCIDENT lost_stream", action.action_id);
                try renderLiveStore(allocator, options, store, liveStatusText(store));
                return;
            };
            defer allocator.free(control_chunk);
            if (control_chunk.len == 0) {
                try store.flushPendingLine();
                const term = control_session.wait(io) catch std.process.Child.Term{ .exited = 1 };
                if (term != .exited or term.exited != 0) {
                    try store.appendControlStatus(.incident, "INCIDENT process_exit_unexpected", action.action_id);
                }
                try renderLiveStore(allocator, options, store, liveStatusText(store));
                return;
            }
            made_progress = true;
            try store.applyChunk(control_chunk);
            try renderLiveStore(allocator, options, store, liveStatusText(store));
        }
        if (made_progress) {
            idle_polls = 0;
        } else {
            idle_polls += 1;
            if (idle_polls >= active_control_timeout_polls) {
                try store.appendControlStatus(.incident, "INCIDENT timeout", action.action_id);
                control_session.terminate(io);
                try renderLiveStore(allocator, options, store, liveStatusText(store));
                return;
            }
        }
    }
}

fn drainSessionOutput(
    allocator: std.mem.Allocator,
    io: std.Io,
    session: *tui.daemon_adapter.LiveSession,
    store: *tui.live_store.Store,
    timeout_ms: i32,
) !void {
    var fd = [_]std.posix.pollfd{.{ .fd = session.stdoutFd(), .events = std.posix.POLL.IN | std.posix.POLL.HUP, .revents = 0 }};
    const ready = std.posix.poll(&fd, timeout_ms) catch 0;
    if (ready == 0) return;
    if ((fd[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP)) == 0) return;
    const chunk = session.readAvailable(allocator, io) catch return;
    defer allocator.free(chunk);
    if (chunk.len == 0) return;
    try store.applyChunk(chunk);
    try store.flushPendingLine();
}

fn scrubEvent(store: *tui.live_store.Store, delta: i32) !void {
    if (store.event_cursor.selected_seq == null) return;
    const newest = store.event_cursor.newest_seq orelse return;
    const current: i64 = @intCast(store.event_cursor.selected_seq.?);
    const next = @min(@as(i64, @intCast(newest)), @max(1, current + delta));
    store.event_cursor.selected_seq = @intCast(next);
    store.event_cursor.scrub_offset += delta;
    store.refreshCursorLabel();
}

fn renderLiveStore(
    allocator: std.mem.Allocator,
    options: tui.Options,
    store: *const tui.live_store.Store,
    status: []const u8,
) !void {
    const frame = try tui.renderInteractiveLiveStore(allocator, options, store, status);
    defer allocator.free(frame);
    try writeStdout("\n");
    try writeStdout(frame);
}

fn applyNavigation(key: u8, options: *tui.Options) void {
    const binding = tui.actions.bindingForKey(key) orelse return;
    switch (binding.kind) {
        .help => options.screen = .help,
        .home => options.screen = .preflight,
        .run_vm_lab => options.screen = .vm_lab,
        else => {},
    }
}

const ActionStatus = struct {
    text: []const u8,
    owned: ?tui.daemon_adapter.Dispatch = null,

    fn deinit(self: ActionStatus, allocator: std.mem.Allocator) void {
        if (self.owned) |owned| owned.deinit(allocator);
    }
};

fn controlStatus(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: tui.Options,
    result: tui.interaction.ControlResult,
) !ActionStatus {
    return switch (result) {
        .status => |text| .{ .text = text },
        .action => |action| dispatchStatus(allocator, io, options, action),
    };
}

fn dispatchStatus(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: tui.Options,
    action: tui.OperatorAction,
) !ActionStatus {
    if (options.daemon_state_dir == null) return .{ .text = tui.interaction.statusForAction(action) };
    const dispatch = tui.daemon_adapter.dispatch(allocator, io, options, action) catch {
        return .{ .text = "daemon unsafe_to_assume" };
    };
    return .{ .text = dispatch.status, .owned = dispatch };
}

fn enableRawMode() ?std.posix.termios {
    const original = std.posix.tcgetattr(std.posix.STDIN_FILENO) catch return null;
    var raw = original;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, raw) catch return null;
    return original;
}

fn writeStdout(bytes: []const u8) !void {
    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &stdout_buffer);
    try stdout_writer.interface.writeAll(bytes);
    try stdout_writer.interface.flush();
}

test "tui executable links parser" {
    _ = try tui.parseArgs(&.{ "--snapshot", "--screen", "preflight" });
}
