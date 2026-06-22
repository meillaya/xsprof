//! SIZE_OK: executable glue owns one interactive/live-event loop where raw terminal mode,
//! daemon polling, control-session draining, and redraw ordering must stay synchronized;
//! a late split would risk the verified PTY lifecycle and no-host-mutation gates.
const std = @import("std");
const tui = @import("linux_scheduler_tui");

const live_poll_timeout_ms: i32 = 250;
const live_idle_timeout_polls: usize = 40;

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
    if (options.interactive) return runInteractive(allocator, init.io, init.environ_map, options);

    const frame = try tui.renderSnapshot(allocator, options);
    defer allocator.free(frame);
    try writeStdout(frame);
}

fn runInteractive(allocator: std.mem.Allocator, io: std.Io, environ_map: *const std.process.Environ.Map, options: tui.Options) !void {
    const original_termios = enableRawMode();
    defer if (original_termios) |original| std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, original) catch {};
    try enterFullScreen();
    defer leaveFullScreen() catch {};

    var current_options = options;
    applyTerminalSize(&current_options);
    var control_state = tui.interaction.ControlState{};
    const initial = if (current_options.screen == .vm_lab)
        try tui.renderInteractiveModeWithTheme(allocator, current_options, control_state.ui_mode, "", control_state.theme_id)
    else
        try tui.renderInteractive(allocator, current_options, null);
    defer allocator.free(initial);
    try writeFrameStdout(initial);

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
        applyTerminalSize(&current_options);
        switch (result) {
            .action => |action| {
                if (action.kind == .run_lab_microvm_live and current_options.daemon_state_dir != null) {
                    if (try runLiveVmEventLoop(allocator, io, environ_map, current_options, action, &control_state)) break;
                    continue;
                }
            },
            .status => {},
        }
        const status = try controlStatus(allocator, io, current_options, result);
        defer status.deinit(allocator);
        const frame = if (current_options.screen == .vm_lab)
            try tui.renderInteractiveModeWithTheme(allocator, current_options, control_state.ui_mode, status.text, control_state.theme_id)
        else
            try tui.renderInteractiveStatus(allocator, current_options, status.text);
        defer allocator.free(frame);
        try writeFrameStdout(frame);
        if (key == 'q') break;
    }
}

fn applyTerminalSize(options: *tui.Options) void {
    if (options.width_explicit and options.height_explicit) return;
    var size: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const rc = std.os.linux.ioctl(std.posix.STDOUT_FILENO, std.os.linux.T.IOCGWINSZ, @intFromPtr(&size));
    if (std.os.linux.errno(rc) != .SUCCESS) return;
    if (!options.width_explicit and size.col >= 80) options.width = size.col;
    if (!options.height_explicit and size.row >= 8) options.height = size.row;
}

fn runLiveVmEventLoop(
    allocator: std.mem.Allocator,
    io: std.Io,
    _: *const std.process.Environ.Map,
    options: tui.Options,
    action: tui.OperatorAction,
    control_state: *tui.interaction.ControlState,
) !bool {
    var store = tui.live_store.Store.init(allocator);
    defer store.deinit();
    tui.interaction.enterLiveMode(control_state);
    try store.appendControlStatus(.queued, "[queued] VM run queued", action.action_id);
    try renderLiveStoreMode(allocator, options, control_state.ui_mode, &store, "RUNNING live VM queued", control_state.theme_id);

    var session = tui.daemon_adapter.startLive(allocator, io, options, action) catch {
        tui.interaction.enterIncidentMode(control_state);
        try store.appendControlStatus(.incident, "INCIDENT qemu_unavailable", action.action_id);
        try renderLiveStoreMode(allocator, options, control_state.ui_mode, &store, "INCIDENT qemu_unavailable", control_state.theme_id);
        return false;
    };
    defer session.deinit(allocator, io);
    var control_sessions: std.ArrayList(tui.daemon_adapter.LiveSession) = .empty;
    defer {
        for (control_sessions.items) |*control_session| control_session.deinit(allocator, io);
        control_sessions.deinit(allocator);
    }

    const idle_timeout_polls = liveIdleTimeoutPolls(options);
    const force_idle_timeout_on_empty_read = options.test_mode and idle_timeout_polls != live_idle_timeout_polls;
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
            if (idle_polls >= idle_timeout_polls) {
                try store.appendControlStatus(.incident, "INCIDENT timeout", action.action_id);
                tui.interaction.enterIncidentMode(control_state);
                try renderLiveStoreMode(allocator, options, control_state.ui_mode, &store, "INCIDENT timeout", control_state.theme_id);
                session.terminate(io);
                quit_requested = true;
                running = false;
                continue;
            }
            try renderLiveStoreMode(allocator, options, control_state.ui_mode, &store, "RUNNING live VM active", control_state.theme_id);
            continue;
        }
        if ((fds[1].revents & (std.posix.POLL.IN | std.posix.POLL.HUP)) != 0) {
            const chunk = session.readAvailable(allocator, io) catch {
                try store.appendControlStatus(.incident, "INCIDENT lost_stream", action.action_id);
                tui.interaction.enterIncidentMode(control_state);
                try renderLiveStoreMode(allocator, options, control_state.ui_mode, &store, "INCIDENT lost_stream", control_state.theme_id);
                break;
            };
            defer allocator.free(chunk);
            if (chunk.len == 0) {
                if (force_idle_timeout_on_empty_read and store.phase != .incident and !isValidatedClean(&store)) {
                    try store.appendControlStatus(.incident, "INCIDENT timeout", action.action_id);
                    tui.interaction.enterIncidentMode(control_state);
                    try renderLiveStoreMode(allocator, options, control_state.ui_mode, &store, "INCIDENT timeout", control_state.theme_id);
                    session.terminate(io);
                    quit_requested = true;
                    running = false;
                    continue;
                }
                saw_eof = true;
            } else {
                idle_polls = 0;
                try store.applyChunk(chunk);
                if (store.phase == .incident) tui.interaction.enterIncidentMode(control_state);
                try renderLiveStoreMode(allocator, options, control_state.ui_mode, &store, liveStatusText(&store), control_state.theme_id);
            }
        }
        if ((fds[0].revents & std.posix.POLL.IN) != 0) {
            var byte: [1]u8 = undefined;
            const n = std.posix.read(std.posix.STDIN_FILENO, &byte) catch 0;
            if (n == 1) {
                switch (byte[0]) {
                    3, 'q' => {
                        try drainSessionOutput(allocator, io, &session, &store, 200);
                        try drainControlSessions(allocator, io, options, &control_sessions, &store, control_state.theme_id, 500);
                        try store.appendControlStatus(.cleanup_running, "[cleanup] cleanup running", action.action_id);
                        try renderLiveStore(allocator, options, &store, liveStatusText(&store), control_state.theme_id);
                        quit_requested = true;
                        running = false;
                    },
                    's' => {
                        try drainSessionOutput(allocator, io, &session, &store, 25);
                        if (try activeStop(allocator, io, options, &store, control_state)) |control_session| {
                            try control_sessions.append(allocator, control_session);
                        }
                    },
                    'b' => {
                        try drainSessionOutput(allocator, io, &session, &store, 25);
                        if (try activeRollback(allocator, io, options, &store, control_state)) |control_session| {
                            try control_sessions.append(allocator, control_session);
                        }
                    },
                    'w' => {
                        const theme = tui.interaction.controlForKey('w', control_state, options.test_mode).?;
                        try renderLiveStoreMode(allocator, options, control_state.ui_mode, &store, theme.status, control_state.theme_id);
                    },
                    '?' => {
                        const help = tui.interaction.controlForKey('?', control_state, options.test_mode).?;
                        try renderLiveStoreMode(allocator, options, control_state.ui_mode, &store, help.status, control_state.theme_id);
                    },
                    27, 'h' => if (control_state.ui_mode == .help) {
                        const help = tui.interaction.controlForKey(byte[0], control_state, options.test_mode).?;
                        try renderLiveStoreMode(allocator, options, control_state.ui_mode, &store, help.status, control_state.theme_id);
                    },
                    'j' => {
                        try scrubEvent(&store, 1);
                        try renderLiveStoreMode(allocator, options, control_state.ui_mode, &store, "SCRUB event cursor j/k", control_state.theme_id);
                    },
                    'k' => {
                        try scrubEvent(&store, -1);
                        try renderLiveStoreMode(allocator, options, control_state.ui_mode, &store, "SCRUB event cursor j/k", control_state.theme_id);
                    },
                    'r', 'v', 'p', 'o', 'i' => _ = try activeHiddenAction(allocator, options, &store, control_state, byte[0]),
                    else => {},
                }
            }
        }
        try drainControlSessions(allocator, io, options, &control_sessions, &store, control_state.theme_id, 0);
        if (saw_eof) {
            try store.flushPendingLine();
            try drainControlSessions(allocator, io, options, &control_sessions, &store, control_state.theme_id, 750);
            const term = session.wait(io) catch std.process.Child.Term{ .exited = 1 };
            if (term != .exited or term.exited != 0) {
                try store.appendControlStatus(.incident, "INCIDENT process_exit_unexpected", action.action_id);
                tui.interaction.enterIncidentMode(control_state);
                quit_requested = true;
            } else if (isValidatedClean(&store)) {
                tui.interaction.enterLiveMode(control_state);
                try store.appendControlStatus(.safe, "[SAFE] footer mode SAFE", action.action_id);
            } else if (store.incidents.items.len == 0) {
                try store.appendControlStatus(.incident, "INCIDENT lost_stream", action.action_id);
                tui.interaction.enterIncidentMode(control_state);
                quit_requested = true;
            }
            try renderLiveStoreMode(allocator, options, control_state.ui_mode, &store, liveStatusText(&store), control_state.theme_id);
            break;
        }
    }
    if (isValidatedClean(&store)) {
        try store.appendControlStatus(.safe, "[SAFE] footer mode SAFE", action.action_id);
        tui.interaction.enterLiveMode(control_state);
        try renderLiveStoreMode(allocator, options, control_state.ui_mode, &store, "SAFE", control_state.theme_id);
    } else if (store.phase != .incident) {
        if (options.test_idle_timeout_polls != null and !isValidatedClean(&store)) {
            try store.appendControlStatus(.incident, "INCIDENT timeout", action.action_id);
            tui.interaction.enterIncidentMode(control_state);
            try renderLiveStoreMode(allocator, options, control_state.ui_mode, &store, "INCIDENT timeout", control_state.theme_id);
        } else {
            try store.appendControlStatus(.cleanup_running, "[cleanup] cleanup running", action.action_id);
            try renderLiveStoreMode(allocator, options, control_state.ui_mode, &store, "CLEANUP", control_state.theme_id);
        }
    } else {
        tui.interaction.enterIncidentMode(control_state);
        try renderLiveStoreMode(allocator, options, control_state.ui_mode, &store, liveStatusText(&store), control_state.theme_id);
    }
    return quit_requested;
}

fn liveIdleTimeoutPolls(options: tui.Options) usize {
    const requested = options.test_idle_timeout_polls orelse return live_idle_timeout_polls;
    return @max(@as(usize, 1), @min(requested, live_idle_timeout_polls));
}

fn isValidatedClean(store: *const tui.live_store.Store) bool {
    return store.phase != .incident and
        store.incidents.items.len == 0 and
        (store.phase == .validated or store.phase == .safe or store.lanes.validation.status == .pass) and
        store.lanes.cleanup.status == .pass;
}

fn liveStatusText(store: *const tui.live_store.Store) []const u8 {
    if (store.incidents.items.len != 0) return store.latestIncidentSummary();
    return @tagName(store.footer_mode);
}

fn activeStop(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: tui.Options,
    store: *tui.live_store.Store,
    state: *tui.interaction.ControlState,
) !?tui.daemon_adapter.LiveSession {
    if (state.stop_sent) {
        try store.appendControlRefusal(.duplicate_action_id, "tui-stop-active");
        try renderLiveStore(allocator, options, store, "REFUSED duplicate action id: tui-stop-active", state.theme_id);
        return null;
    }
    if (state.rollback_sent or !hasActiveLiveTarget(store, state)) {
        try store.appendControlRefusal(.stale_action_id, "tui-stop-active");
        try renderLiveStore(allocator, options, store, "REFUSED stale action id: tui-stop-active · no live target", state.theme_id);
        return null;
    }
    if (!state.stop_confirm_pending) {
        state.stop_confirm_pending = true;
        state.rollback_confirm_pending = false;
        try store.appendControlStatus(store.phase, "CONFIRM stop — press s again", "tui-stop-active");
        try renderLiveStore(allocator, options, store, liveStatusText(store), state.theme_id);
        return null;
    }
    state.stop_confirm_pending = false;
    state.stop_sent = true;
    const action = tui.OperatorAction{
        .kind = .stop_lab_run,
        .action_id = "tui-stop-active",
        .run_id = "tui-stop-active",
        .audit_id = state.audit_id,
        .rollback_id = state.rollback_id,
        .target_action_id = state.lab_action_id,
    };
    try store.appendControlStatus(.cleanup_running, "ACTION queued stop_lab_run · target rollback id", action.action_id);
    try renderLiveStore(allocator, options, store, liveStatusText(store), state.theme_id);
    try store.appendControlStatus(.cleanup_running, "stop active · operator confirmed safe stop", action.action_id);
    try renderLiveStore(allocator, options, store, liveStatusText(store), state.theme_id);
    return tui.daemon_adapter.startControl(allocator, io, options, action) catch {
        try store.appendControlStatus(.incident, "INCIDENT lost_stream", action.action_id);
        try renderLiveStore(allocator, options, store, liveStatusText(store), state.theme_id);
        return null;
    };
}

fn activeRollback(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: tui.Options,
    store: *tui.live_store.Store,
    state: *tui.interaction.ControlState,
) !?tui.daemon_adapter.LiveSession {
    if (state.rollback_sent) {
        try store.appendControlRefusal(.duplicate_action_id, "tui-rollback-active");
        try renderLiveStore(allocator, options, store, "REFUSED duplicate action id: tui-rollback-active", state.theme_id);
        return null;
    }
    if (!hasActiveLiveTarget(store, state)) {
        try store.appendControlRefusal(.stale_action_id, "tui-rollback-active");
        try renderLiveStore(allocator, options, store, "REFUSED stale action id: tui-rollback-active", state.theme_id);
        return null;
    }
    if (!state.rollback_confirm_pending) {
        state.rollback_confirm_pending = true;
        state.stop_confirm_pending = false;
        try store.appendControlStatus(store.phase, "CONFIRM rollback — press b again", "tui-rollback-active");
        try renderLiveStore(allocator, options, store, liveStatusText(store), state.theme_id);
        return null;
    }
    state.rollback_confirm_pending = false;
    state.rollback_sent = true;
    const action = tui.OperatorAction{
        .kind = .rollback_lab_run,
        .action_id = "tui-rollback-active",
        .run_id = "tui-rollback-active",
        .audit_id = state.audit_id,
        .rollback_id = state.rollback_id,
        .target_action_id = state.lab_action_id,
    };
    try store.appendControlStatus(.rollback_requested, "ACTION queued rollback_lab_run · target rollback id", action.action_id);
    try renderLiveStore(allocator, options, store, "ACTION queued rollback_lab_run · target rollback id", state.theme_id);
    try store.appendControlStatus(.rollback_running, "rollback active · operator confirmed rollback", action.action_id);
    try renderLiveStore(allocator, options, store, liveStatusText(store), state.theme_id);
    return tui.daemon_adapter.startControl(allocator, io, options, action) catch {
        try store.appendControlStatus(.incident, "INCIDENT lost_stream", action.action_id);
        try renderLiveStore(allocator, options, store, liveStatusText(store), state.theme_id);
        return null;
    };
}

fn activeHiddenAction(
    allocator: std.mem.Allocator,
    options: tui.Options,
    store: *tui.live_store.Store,
    state: *tui.interaction.ControlState,
    key: u8,
) !bool {
    const action = tui.interaction.actionForKey(key) orelse return false;
    const status = tui.interaction.statusForAction(action);
    switch (action.kind) {
        .incident_drill => {
            try store.appendControlStatus(.incident, "INCIDENT unsafe_to_assume on gaps · incident drill", "tui-incident-drill");
            tui.interaction.enterIncidentMode(state);
            try renderLiveStoreMode(allocator, options, state.ui_mode, store, "INCIDENT unsafe_to_assume on gaps", state.theme_id);
        },
        .verifier_only => {
            try store.appendControlStatus(store.phase, "ACTION queued verifier_only · VM-live replay verifier", "tui-verifier-only");
            try renderLiveStoreMode(allocator, options, state.ui_mode, store, status, state.theme_id);
        },
        .partial_attach => {
            try store.appendControlStatus(store.phase, "ACTION queued partial_attach · partial attach observed", "tui-partial-attach");
            try renderLiveStoreMode(allocator, options, state.ui_mode, store, status, state.theme_id);
        },
        .observe => {
            try store.appendControlStatus(.observing, "ACTION queued observe · runtime samples accepted", "tui-observe");
            try renderLiveStoreMode(allocator, options, state.ui_mode, store, status, state.theme_id);
        },
        .run_lab_host_safe => {
            try store.appendControlStatus(store.phase, "ACTION queued run_lab_host_safe · host-safe verifier", "tui-host-safe");
            try renderLiveStoreMode(allocator, options, state.ui_mode, store, status, state.theme_id);
        },
        else => return false,
    }
    return true;
}

fn hasActiveLiveTarget(store: *const tui.live_store.Store, state: *const tui.interaction.ControlState) bool {
    if (state.lab_action_id.len == 0 or state.rollback_id.len == 0 or state.audit_id.len == 0) return false;
    if (store.active_run == null) return false;
    return switch (store.phase) {
        .cleaned, .validated, .safe, .incident => false,
        else => true,
    };
}

fn drainControlSessions(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: tui.Options,
    control_sessions: *std.ArrayList(tui.daemon_adapter.LiveSession),
    store: *tui.live_store.Store,
    theme_id: tui.render.ThemeId,
    timeout_ms: i32,
) !void {
    var index: usize = 0;
    while (index < control_sessions.items.len) {
        var fd = [_]std.posix.pollfd{.{ .fd = control_sessions.items[index].stdoutFd(), .events = std.posix.POLL.IN | std.posix.POLL.HUP, .revents = 0 }};
        const ready = std.posix.poll(&fd, timeout_ms) catch 0;
        if (ready == 0 or (fd[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP)) == 0) {
            index += 1;
            continue;
        }
        const chunk = control_sessions.items[index].readAvailable(allocator, io) catch {
            try store.appendControlStatus(.incident, "INCIDENT lost_stream", "tui-active-control");
            try renderLiveStore(allocator, options, store, liveStatusText(store), theme_id);
            var failed = control_sessions.swapRemove(index);
            failed.deinit(allocator, io);
            continue;
        };
        defer allocator.free(chunk);
        if (chunk.len == 0) {
            try store.flushPendingLine();
            const term = control_sessions.items[index].wait(io) catch std.process.Child.Term{ .exited = 1 };
            if (term != .exited or term.exited != 0) try store.appendControlStatus(.incident, "INCIDENT process_exit_unexpected", "tui-active-control");
            var finished = control_sessions.swapRemove(index);
            finished.deinit(allocator, io);
            try renderLiveStore(allocator, options, store, liveStatusText(store), theme_id);
            continue;
        }
        try store.applyChunk(chunk);
        try renderLiveStore(allocator, options, store, liveStatusText(store), theme_id);
        index += 1;
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
    theme_id: tui.render.ThemeId,
) !void {
    try renderLiveStoreMode(allocator, options, .live, store, status, theme_id);
}

fn renderLiveStoreMode(
    allocator: std.mem.Allocator,
    options: tui.Options,
    mode: tui.interaction.UiMode,
    store: *const tui.live_store.Store,
    status: []const u8,
    theme_id: tui.render.ThemeId,
) !void {
    var render_options = options;
    applyTerminalSize(&render_options);
    const frame = try tui.renderInteractiveLiveStoreModeWithTheme(allocator, render_options, mode, store, status, theme_id);
    defer allocator.free(frame);
    try writeFrameStdout(frame);
}

fn applyNavigation(key: u8, options: *tui.Options) void {
    const binding = tui.actions.bindingForKey(key) orelse return;
    if (options.screen == .vm_lab) {
        switch (binding.kind) {
            .run_vm_lab => options.screen = .vm_lab,
            else => {},
        }
        return;
    }
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

fn writeFrameStdout(frame: []const u8) !void {
    try writeStdout("\x1b[?25l\x1b[H\x1b[2J\x1b[3J");
    try writeStdout(frame);
}

fn enterFullScreen() !void {
    try writeStdout("\x1b[?1049h\x1b[?25l\x1b[H\x1b[2J\x1b[3J");
}

fn leaveFullScreen() !void {
    try writeStdout("\x1b[?25h\x1b[?1049l");
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
