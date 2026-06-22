// SIZE_OK: single fail-closed desktop controller state machine; CLI bridge, event records, and tests are split out.
// Keeping run/rollback/stop latch state together avoids drift in incident/refusal semantics.
const std = @import("std");
const live_events = @import("live_events.zig");
const linux = @import("linux_scheduler");

const protocol = linux.control.protocol;

pub const event_schema = protocol.event_schema;
pub const max_history_events: usize = 256;
pub const default_stream_timeout_ms: i64 = 1500;

const RawDaemonEvent = live_events.RawDaemonEvent;
pub const EventRecord = live_events.EventRecord;

pub const IncidentReason = enum {
    daemon_unavailable,
    daemon_spawn_failed,
    duplicate_action_id,
    stale_or_unknown_target_action_id,
    lost_stream_empty,
    lost_stream_non_json,
    stream_timeout,
    host_mutation_not_false,
    daemon_exit_nonzero,
    schema_violation,
};

pub const DispatchStatus = enum {
    accepted,
    refused,
    incident,
};

pub const Config = struct {
    daemon_path: []const u8,
    state_dir: []const u8,
    stream_timeout_ms: i64 = default_stream_timeout_ms,
};

pub const Controller = struct {
    allocator: std.mem.Allocator,
    config: Config,
    next_action_seq: u64 = 1,
    active_action_id: []u8 = &.{},
    rollback_id: []u8 = &.{},
    audit_id: []u8 = &.{},
    daemon_alive: bool = false,
    history: std.ArrayList(EventRecord) = .empty,
    last_child_was_terminated: bool = false,
    dispatch_status_latch: ?DispatchStatus = null,
    expected_event_action_id: []const u8 = &.{},
    expected_event_target_action_id: []const u8 = &.{},

    pub fn init(allocator: std.mem.Allocator, config: Config) Controller {
        return .{
            .allocator = allocator,
            .config = config,
            .next_action_seq = 1,
            .active_action_id = &.{},
            .rollback_id = &.{},
            .audit_id = &.{},
            .daemon_alive = false,
            .history = .empty,
            .last_child_was_terminated = false,
            .dispatch_status_latch = null,
            .expected_event_action_id = &.{},
            .expected_event_target_action_id = &.{},
        };
    }

    pub fn deinit(self: *Controller) void {
        self.clearActiveIds();
        for (self.history.items) |record| record.deinit(self.allocator);
        self.history.deinit(self.allocator);
    }

    pub fn statusJson(self: *const Controller, writer: *std.Io.Writer) !void {
        try writer.print(
            "{{\"schema\":\"zig-scheduler/live-vm-desktop-controller/v1\",\"mode\":\"vm-lab-only\",\"host_mutation\":false,\"production_ready\":false,\"active\":{},\"active_action_id\":",
            .{self.daemon_alive},
        );
        try live_events.writeJsonString(writer, self.active_action_id);
        try writer.writeAll(",\"rollback_id\":");
        try live_events.writeJsonString(writer, self.rollback_id);
        try writer.print(",\"event_count\":{d}}}\n", .{self.history.items.len});
    }

    pub fn run(self: *Controller, io: std.Io) !DispatchStatus {
        if (self.daemon_alive) {
            const id = if (self.active_action_id.len != 0) self.active_action_id else "unknown-active-run";
            try self.appendSynthetic(.refusal, id, "refused", @tagName(IncidentReason.duplicate_action_id));
            return .refused;
        }

        const action_id = try std.fmt.allocPrint(self.allocator, "desktop-run-{d}", .{self.next_action_seq});
        errdefer self.allocator.free(action_id);
        const rb = try std.fmt.allocPrint(self.allocator, "RB-{s}", .{action_id});
        errdefer self.allocator.free(rb);
        const audit = try std.fmt.allocPrint(self.allocator, "AUD-desktop-{d}", .{self.next_action_seq});
        errdefer self.allocator.free(audit);
        self.next_action_seq += 1;

        self.clearActiveIds();
        self.active_action_id = action_id;
        self.rollback_id = rb;
        self.audit_id = audit;
        self.daemon_alive = true;

        const action = protocol.OperatorAction{
            .kind = .run_lab_microvm_live,
            .action_id = self.active_action_id,
            .run_id = self.active_action_id,
            .audit_id = self.audit_id,
            .rollback_id = self.rollback_id,
        };
        return self.dispatch(io, action, true);
    }

    pub fn rollback(self: *Controller, io: std.Io, target_action_id: []const u8) !DispatchStatus {
        if (self.active_action_id.len == 0 or self.rollback_id.len == 0) {
            try self.appendSynthetic(.refusal, target_action_id, "refused", @tagName(IncidentReason.stale_or_unknown_target_action_id));
            return .refused;
        }
        if (!std.mem.eql(u8, target_action_id, self.active_action_id)) {
            try self.appendSynthetic(.refusal, target_action_id, "refused", @tagName(IncidentReason.stale_or_unknown_target_action_id));
            return .refused;
        }
        const action_id = try std.fmt.allocPrint(self.allocator, "desktop-rollback-{d}", .{self.next_action_seq});
        defer self.allocator.free(action_id);
        self.next_action_seq += 1;
        const action = protocol.OperatorAction{
            .kind = .rollback_lab_run,
            .action_id = action_id,
            .run_id = "desktop-rollback",
            .audit_id = self.audit_id,
            .rollback_id = self.rollback_id,
            .target_action_id = self.active_action_id,
        };
        const status = try self.dispatch(io, action, false);
        self.daemon_alive = false;
        return status;
    }

    pub fn stop(self: *Controller, io: std.Io, target_action_id: []const u8) !DispatchStatus {
        if (self.active_action_id.len == 0 or !std.mem.eql(u8, target_action_id, self.active_action_id)) {
            try self.appendSynthetic(.refusal, target_action_id, "refused", @tagName(IncidentReason.stale_or_unknown_target_action_id));
            return .refused;
        }
        const action_id = try std.fmt.allocPrint(self.allocator, "desktop-stop-{d}", .{self.next_action_seq});
        defer self.allocator.free(action_id);
        self.next_action_seq += 1;
        const action = protocol.OperatorAction{
            .kind = .stop_lab_run,
            .action_id = action_id,
            .run_id = "desktop-stop",
            .audit_id = self.audit_id,
            .rollback_id = self.rollback_id,
            .target_action_id = self.active_action_id,
        };
        const status = try self.dispatch(io, action, false);
        self.daemon_alive = false;
        return status;
    }

    pub fn appendLine(self: *Controller, line: []const u8) !void {
        var parsed = std.json.parseFromSlice(RawDaemonEvent, self.allocator, line, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        }) catch {
            try self.appendStreamIncident(self.active_action_id, @tagName(IncidentReason.lost_stream_non_json));
            return;
        };
        defer parsed.deinit();
        const raw = parsed.value;
        if (!std.mem.eql(u8, raw.schema, event_schema)) {
            try self.appendStreamIncident(raw.action_id orelse self.active_action_id, @tagName(IncidentReason.schema_violation));
            return;
        }
        if (raw.host_mutation) {
            try self.appendStreamIncident(raw.action_id orelse self.active_action_id, @tagName(IncidentReason.host_mutation_not_false));
            return;
        }
        if (!self.daemonEventMatchesControllerAction(raw)) {
            try self.appendStreamIncident(raw.action_id orelse self.active_action_id, @tagName(IncidentReason.stale_or_unknown_target_action_id));
            return;
        }
        try self.appendRaw(line, raw.event, raw.action_id orelse "", raw.status orelse "", raw.reason orelse "");
        if (std.mem.eql(u8, raw.event, "validation") or std.mem.eql(u8, raw.event, "cleanup")) {
            if (raw.status) |status| {
                if (std.mem.eql(u8, status, "PASS")) self.daemon_alive = false;
            }
        }
    }

    pub fn appendSynthetic(self: *Controller, event: protocol.EventKind, action_id: []const u8, status: []const u8, reason: []const u8) !void {
        var line_list: std.ArrayList(u8) = .empty;
        errdefer line_list.deinit(self.allocator);
        var allocating = std.Io.Writer.Allocating.fromArrayList(self.allocator, &line_list);
        try allocating.writer.print(
            "{{\"schema\":\"{s}\",\"event\":\"{s}\",\"action_id\":",
            .{ event_schema, @tagName(event) },
        );
        try live_events.writeJsonString(&allocating.writer, action_id);
        try allocating.writer.writeAll(",\"status\":");
        try live_events.writeJsonString(&allocating.writer, status);
        try allocating.writer.writeAll(",\"reason\":");
        try live_events.writeJsonString(&allocating.writer, reason);
        try allocating.writer.writeAll(",\"host_mutation\":false}");
        line_list = allocating.toArrayList();
        const line = try line_list.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(line);
        try self.appendOwned(line, @tagName(event), action_id, status, reason);
    }

    fn dispatch(self: *Controller, io: std.Io, action: protocol.OperatorAction, follow: bool) !DispatchStatus {
        self.dispatch_status_latch = null;
        self.expected_event_action_id = action.action_id;
        self.expected_event_target_action_id = action.target_action_id;
        defer {
            self.expected_event_action_id = &.{};
            self.expected_event_target_action_id = &.{};
        }
        if (!isValidDaemonPath(self.config.daemon_path)) {
            try self.appendSynthetic(.incident, action.action_id, "refused", @tagName(IncidentReason.daemon_unavailable));
            self.daemon_alive = false;
            return .incident;
        }
        const payload = try action.toJson(self.allocator);
        defer self.allocator.free(payload);
        const input = try std.fmt.allocPrint(self.allocator, "{s}\n", .{payload});
        defer self.allocator.free(input);

        var argv_list = try buildDaemonArgv(self.allocator, self.config.daemon_path, self.config.state_dir, follow);
        defer argv_list.deinit(self.allocator);

        var child = std.process.spawn(io, .{
            .argv = argv_list.items,
            .expand_arg0 = .no_expand,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
            .pgid = 0,
        }) catch |err| {
            const reason = try std.fmt.allocPrint(self.allocator, "daemon_spawn_failed:{s}", .{@errorName(err)});
            defer self.allocator.free(reason);
            try self.appendSynthetic(.incident, action.action_id, "refused", reason);
            self.daemon_alive = false;
            return .incident;
        };
        var child_waited = false;
        defer if (!child_waited) self.terminateChild(io, &child);

        try child.stdin.?.writeStreamingAll(io, input);
        child.stdin.?.close(io);
        child.stdin = null;

        const read_status = self.readChildStdout(io, &child, follow) catch |err| switch (err) {
            error.StreamTimeout => blk: {
                try self.noteTimeoutCleanup(action.action_id);
                self.terminateChild(io, &child);
                child_waited = true;
                break :blk DispatchStatus.incident;
            },
            else => |e| return e,
        };
        if (child_waited) return read_status;

        const term = try child.wait(io);
        child_waited = true;
        if (term != .exited or term.exited != 0) {
            try self.appendStreamIncident(action.action_id, @tagName(IncidentReason.daemon_exit_nonzero));
            return .incident;
        }
        if (read_status != .accepted) self.daemon_alive = false;
        return read_status;
    }

    fn readChildStdout(self: *Controller, io: std.Io, child: *std.process.Child, follow: bool) !DispatchStatus {
        var pending: std.ArrayList(u8) = .empty;
        defer pending.deinit(self.allocator);
        var saw_line = false;
        var idle_polls: usize = 0;
        const poll_timeout_ms: i32 = 100;
        const idle_limit: usize = @max(@as(usize, 1), @as(usize, @intCast(@divTrunc(self.config.stream_timeout_ms, poll_timeout_ms))));
        while (true) {
            var fds = [_]std.posix.pollfd{.{
                .fd = child.stdout.?.handle,
                .events = std.posix.POLL.IN | std.posix.POLL.HUP,
                .revents = 0,
            }};
            const ready = try std.posix.poll(&fds, poll_timeout_ms);
            if (ready == 0) {
                idle_polls += 1;
                if (follow and idle_polls >= idle_limit) return error.StreamTimeout;
                if (!follow and idle_polls >= idle_limit) break;
                continue;
            }
            idle_polls = 0;
            var chunk: [2048]u8 = undefined;
            const read_len = child.stdout.?.readStreaming(io, &.{&chunk}) catch |err| switch (err) {
                error.EndOfStream => break,
                else => |e| return e,
            };
            if (read_len == 0) break;
            try pending.appendSlice(self.allocator, chunk[0..read_len]);
            while (std.mem.indexOfScalar(u8, pending.items, '\n')) |newline_index| {
                const line = std.mem.trim(u8, pending.items[0..newline_index], " \t\r");
                if (line.len != 0) {
                    saw_line = true;
                    try self.appendLine(line);
                }
                pending.replaceRangeAssumeCapacity(0, newline_index + 1, "");
            }
        }
        const final_line = std.mem.trim(u8, pending.items, " \t\r\n");
        if (final_line.len != 0) {
            saw_line = true;
            try self.appendLine(final_line);
        }
        if (!saw_line) {
            try self.appendStreamIncident(self.active_action_id, @tagName(IncidentReason.lost_stream_empty));
            return .incident;
        }
        return self.dispatch_status_latch orelse .accepted;
    }

    fn appendStreamIncident(self: *Controller, action_id: []const u8, reason: []const u8) !void {
        self.daemon_alive = false;
        const status = if (std.mem.eql(u8, reason, @tagName(IncidentReason.host_mutation_not_false))) "refused" else "incident";
        try self.appendSynthetic(.incident, action_id, status, reason);
    }

    fn daemonEventMatchesControllerAction(self: *const Controller, raw: RawDaemonEvent) bool {
        const expected_action_id = if (self.expected_event_action_id.len != 0) self.expected_event_action_id else self.active_action_id;
        if (expected_action_id.len == 0) return true;
        if (raw.action_id == null and raw.action == null and std.mem.eql(u8, raw.event, "state_changed")) return true;
        if (raw.action_id) |event_action_id| {
            if (!std.mem.eql(u8, event_action_id, expected_action_id)) return false;
        } else if (raw.action) |event_action| {
            if (!std.mem.eql(u8, event_action, "run_lab_microvm_live") and
                !std.mem.eql(u8, event_action, "rollback_lab_run") and
                !std.mem.eql(u8, event_action, "stop_lab_run")) return false;
        } else return false;

        if (self.expected_event_target_action_id.len != 0) {
            const target_action_id = raw.target_action_id orelse return false;
            return std.mem.eql(u8, target_action_id, self.expected_event_target_action_id);
        }

        if (raw.target_action_id) |target_action_id| {
            if (target_action_id.len != 0 and !std.mem.eql(u8, target_action_id, self.active_action_id)) return false;
        }
        return true;
    }

    fn appendRaw(self: *Controller, line: []const u8, event: []const u8, action_id: []const u8, status: []const u8, reason: []const u8) !void {
        const owned = try self.allocator.dupe(u8, line);
        errdefer self.allocator.free(owned);
        try self.appendOwned(owned, event, action_id, status, reason);
    }

    fn appendOwned(self: *Controller, owned_line: []u8, event: []const u8, action_id: []const u8, status: []const u8, reason: []const u8) !void {
        if (self.history.items.len >= max_history_events) {
            var dropped = self.history.orderedRemove(0);
            dropped.deinit(self.allocator);
        }
        try self.history.append(self.allocator, .{
            .line = owned_line,
            .event = try self.allocator.dupe(u8, event),
            .action_id = try self.allocator.dupe(u8, action_id),
            .status = try self.allocator.dupe(u8, status),
            .reason = try self.allocator.dupe(u8, reason),
            .host_mutation = false,
        });
        self.noteDispatchStatus(event, status);
    }

    fn noteDispatchStatus(self: *Controller, event: []const u8, status: []const u8) void {
        if (std.mem.eql(u8, event, "incident") or std.mem.eql(u8, status, "incident") or std.mem.eql(u8, status, "SKIP")) {
            self.dispatch_status_latch = .incident;
            self.daemon_alive = false;
            return;
        }
        if (std.mem.eql(u8, status, "REFUSE")) {
            if (self.dispatch_status_latch == null) self.dispatch_status_latch = .refused;
            self.daemon_alive = false;
            return;
        }
        if (self.dispatch_status_latch == null and (std.mem.eql(u8, event, "refusal") or std.mem.eql(u8, status, "refused"))) {
            self.dispatch_status_latch = .refused;
            self.daemon_alive = false;
        }
    }

    fn terminateChild(self: *Controller, io: std.Io, child: *std.process.Child) void {
        self.last_child_was_terminated = true;
        const pgid = child.id orelse {
            child.kill(io);
            _ = child.wait(io) catch {};
            return;
        };
        if (pgid > 1) {
            const group_pid: std.posix.pid_t = -pgid;
            std.posix.kill(group_pid, .TERM) catch {};
            boundedGracePoll();
            std.posix.kill(group_pid, .KILL) catch {};
        } else {
            child.kill(io);
        }
        _ = child.wait(io) catch {};
    }

    pub fn noteTimeoutCleanup(self: *Controller, action_id: []const u8) !void {
        self.last_child_was_terminated = true;
        self.daemon_alive = false;
        try self.appendSynthetic(.incident, action_id, "unsafe_to_assume", @tagName(IncidentReason.stream_timeout));
    }

    fn clearActiveIds(self: *Controller) void {
        if (self.active_action_id.len != 0) self.allocator.free(self.active_action_id);
        if (self.rollback_id.len != 0) self.allocator.free(self.rollback_id);
        if (self.audit_id.len != 0) self.allocator.free(self.audit_id);
        self.active_action_id = &.{};
        self.rollback_id = &.{};
        self.audit_id = &.{};
        self.daemon_alive = false;
    }
};

pub fn buildDaemonArgv(allocator: std.mem.Allocator, daemon_path: []const u8, state_dir: []const u8, follow: bool) !std.ArrayList([]const u8) {
    var argv_list: std.ArrayList([]const u8) = .empty;
    errdefer argv_list.deinit(allocator);
    if (std.mem.endsWith(u8, daemon_path, ".py")) {
        try argv_list.appendSlice(allocator, &.{ "/usr/bin/env", "python3" });
    }
    try argv_list.append(allocator, daemon_path);
    try argv_list.appendSlice(allocator, &.{ "--foreground", "--state-dir", state_dir });
    if (follow) try argv_list.insert(allocator, if (std.mem.endsWith(u8, daemon_path, ".py")) 3 else 1, "--follow");
    return argv_list;
}

pub fn isValidDaemonPath(path: []const u8) bool {
    if (path.len == 0) return false;
    for (path) |byte| {
        if (byte <= 0x20 or byte == 0x7f or byte == '"' or byte == '\'' or byte == '`' or byte == ';' or byte == '|') return false;
    }
    return std.mem.eql(u8, path, "zig-out/bin/zig-scheduler-daemon") or
        std.mem.eql(u8, path, "tools/tui_pty_authoritative_daemon.py") or
        std.mem.eql(u8, path, "tools/tui_pty_malformed_redaction.py") or
        std.mem.eql(u8, path, "tools/live_controller_hung_daemon.py") or
        std.mem.eql(u8, path, "tools/live_vm_desktop_failure_daemon.py");
}

fn boundedGracePoll() void {
    var fds = [_]std.posix.pollfd{};
    _ = std.posix.poll(&fds, 100) catch {};
}
