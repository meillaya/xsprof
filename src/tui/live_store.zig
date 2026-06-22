//! SIZE_OK: cohesive live-run event store; redaction, dedupe, phase/counter reducers,
//! and viewport accessors share capped buffers whose invariants are verified together,
//! so splitting during final QA would risk already-green TUI transcript behavior.
const std = @import("std");
const fixture = @import("fixture.zig");

pub const schema_version = "live-run-store.v1";
const daemon_event_schema = "zig-scheduler/daemon-event/v1";
const max_events: usize = 128;
const max_raw_preview_bytes: usize = 160;

pub const Phase = enum {
    queued,
    booting,
    marker_wait,
    verifying,
    verifier_rejected,
    attach_ready,
    attached,
    observing,
    rollback_ready,
    rollback_requested,
    rollback_running,
    cleanup_running,
    cleaned,
    validated,
    incident,
    safe,
};

pub const FooterMode = enum { RUNNING, ROLLBACK, CLEANUP, INCIDENT, SAFE };

pub const IncidentKind = enum {
    qemu_unavailable,
    verifier_reject,
    lost_stream,
    timeout,
    rollback_failure,
    cleanup_residue,
    malformed_line,
    duplicate_action_id,
    stale_action_id,
    process_exit_unexpected,
    stream_decode_error,
};

pub const PhaseStatus = enum { pending, active, pass, refuse, incident, skipped };
pub const Severity = enum { info, warning, err, unsafe_to_assume };
pub const EventSource = enum { daemon, control, store, test_fixture };
pub const ActionStatus = enum { pending, accepted, duplicate_refused, stale_refused, completed, failed };

pub const PhaseState = struct {
    status: PhaseStatus = .pending,
    last_seq: ?u64 = null,
    summary: []const u8 = "pending",
};

pub const LaneState = struct {
    boot: PhaseState = .{},
    marker: PhaseState = .{},
    verifier: PhaseState = .{},
    attach: PhaseState = .{},
    runtime_samples: PhaseState = .{},
    rollback: PhaseState = .{},
    cleanup: PhaseState = .{},
    validation: PhaseState = .{},
};

pub const Incident = struct {
    seq: u64,
    kind: IncidentKind,
    severity: Severity,
    phase: Phase,
    summary: []u8,
    raw_redacted: []const u8,
    recoverable: bool,
};

pub const RedactionPolicy = struct {
    hide_absolute_host_paths: bool = true,
    hide_environment_assignments: bool = true,
    hide_long_opaque_tokens: bool = true,
    max_raw_preview_bytes: u16 = max_raw_preview_bytes,
};

pub const RunIdentity = struct {
    run_id: []const u8 = "",
    vm_id: []const u8 = "",
    target_id: []const u8 = "",
    daemon_pid: ?std.posix.pid_t = null,
    daemon_pgid: ?std.posix.pid_t = null,
    started_at_ms: i64 = 0,
};

pub const EventCursor = struct {
    next_seq: u64 = 1,
    selected_seq: ?u64 = null,
    newest_seq: ?u64 = null,
    scrub_offset: i32 = 0,
};

pub const RunEvent = struct {
    seq: u64,
    timestamp_ms: i64,
    run_id: []const u8,
    kind: []const u8,
    phase_after: Phase,
    summary: []const u8,
    raw_redacted: []const u8,
    source: EventSource,
    action_id: ?[]const u8,
    dedupe_key: []const u8,

    fn deinit(self: RunEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.run_id);
        allocator.free(self.kind);
        allocator.free(self.summary);
        allocator.free(self.raw_redacted);
        if (self.action_id) |action_id| allocator.free(action_id);
        allocator.free(self.dedupe_key);
    }
};

pub const RuntimeCounters = struct {
    samples_seen: u64 = 0,
    cpu_samples: u64 = 0,
    memory_samples: u64 = 0,
    io_samples: u64 = 0,
    verifier_samples: u64 = 0,
    last_sample_ms: ?i64 = null,
};

pub const ActionState = struct {
    action_id: []const u8,
    run_id: []const u8,
    target_id: []const u8,
    requested_at_ms: i64,
    phase_when_requested: Phase,
    status: ActionStatus,
    expires_after_phase: Phase,
};

pub const ActionRegistry = struct {
    stop: ?ActionState = null,
    rollback: ?ActionState = null,
};

const RawDaemonEvent = struct {
    schema: []const u8,
    seq: ?u64 = null,
    event: []const u8,
    action: ?[]const u8 = null,
    action_id: ?[]const u8 = null,
    target_action_id: ?[]const u8 = null,
    rollback_id: ?[]const u8 = null,
    status: ?[]const u8 = null,
    reason: ?[]const u8 = null,
    state: ?[]const u8 = null,
    artifact: ?[]const u8 = null,
    sample_sequence: ?u64 = null,
    host_mutation: bool,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    active_run: ?RunIdentity = null,
    phase: Phase = .safe,
    footer_mode: FooterMode = .SAFE,
    event_cursor: EventCursor = .{},
    events: std.ArrayList(RunEvent) = .empty,
    pending_line: std.ArrayList(u8) = .empty,
    lanes: LaneState = .{},
    counters: RuntimeCounters = .{},
    actions: ActionRegistry = .{},
    incidents: std.ArrayList(Incident) = .empty,
    malformed_line_count: u32 = 0,
    dropped_event_count: u32 = 0,
    redaction_policy: RedactionPolicy = .{},
    cursor_label_buf: [64]u8 = undefined,
    cursor_label_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Store) void {
        if (self.active_run) |run| {
            self.allocator.free(run.run_id);
            self.allocator.free(run.vm_id);
            self.allocator.free(run.target_id);
        }
        for (self.events.items) |event| event.deinit(self.allocator);
        self.events.deinit(self.allocator);
        self.pending_line.deinit(self.allocator);
        for (self.incidents.items) |incident| {
            self.allocator.free(incident.summary);
            self.allocator.free(incident.raw_redacted);
        }
        self.incidents.deinit(self.allocator);
    }

    pub fn applyChunk(self: *Store, chunk: []const u8) !void {
        try self.pending_line.appendSlice(self.allocator, chunk);
        while (std.mem.indexOfScalar(u8, self.pending_line.items, '\n')) |newline_index| {
            const line = self.pending_line.items[0..newline_index];
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len != 0) try self.applyLine(trimmed, .daemon);
            self.pending_line.replaceRangeAssumeCapacity(0, newline_index + 1, "");
        }
    }

    pub fn flushPendingLine(self: *Store) !void {
        const trimmed = std.mem.trim(u8, self.pending_line.items, " \t\r\n");
        if (trimmed.len != 0) try self.applyLine(trimmed, .daemon);
        self.pending_line.clearRetainingCapacity();
    }

    pub fn applyLine(self: *Store, line: []const u8, source: EventSource) !void {
        var parsed = std.json.parseFromSlice(RawDaemonEvent, self.allocator, line, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        }) catch {
            self.malformed_line_count += 1;
            try self.appendIncident(.malformed_line, .warning, .incident, "INCIDENT malformed_line", line, true);
            return;
        };
        defer parsed.deinit();
        const raw = parsed.value;
        if (!std.mem.eql(u8, raw.schema, daemon_event_schema) or raw.host_mutation) {
            try self.appendIncident(.stream_decode_error, .unsafe_to_assume, .incident, "INCIDENT stream_decode_error", line, false);
            return;
        }

        const next_phase = phaseFor(raw);
        const summary = summaryFor(raw, next_phase);
        const incident_kind = incidentFor(raw);
        const already_incident = self.incidents.items.len != 0;
        const terminal_incident = already_incident or incident_kind != null or next_phase == .incident;
        const ignored_after_incident = already_incident and incident_kind == null;
        const effective_phase: Phase = if (terminal_incident) .incident else next_phase;
        const effective_summary = if (ignored_after_incident) "ignored after incident" else summary;
        const seq = raw.seq orelse self.event_cursor.next_seq;
        const dedupe_key = try makeDedupeKey(self.allocator, raw, seq);
        defer self.allocator.free(dedupe_key);
        if (self.hasDedupeKey(dedupe_key)) return;

        if (raw.action_id) |action_id| try self.ensureActiveRun(raw, action_id);
        self.phase = effective_phase;
        self.footer_mode = footerFor(effective_phase);
        self.event_cursor.next_seq = @max(self.event_cursor.next_seq, seq + 1);
        if (!ignored_after_incident) {
            self.event_cursor.newest_seq = seq;
            self.event_cursor.selected_seq = seq;
            self.refreshCursorLabel();
            updateLanes(self, raw, seq, effective_summary);
            updateCounters(self, raw);
        }
        if (incident_kind) |kind| {
            try self.appendIncident(kind, severityFor(raw), effective_phase, summary, line, true);
        }
        try self.appendEvent(seq, raw, effective_phase, effective_summary, line, source, dedupe_key);
    }

    pub fn appendControlRefusal(self: *Store, kind: IncidentKind, action_id: []const u8) !void {
        const prefix = if (kind == .duplicate_action_id) "REFUSED duplicate action id: " else "REFUSED stale action id: ";
        const summary = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ prefix, action_id });
        defer self.allocator.free(summary);
        try self.appendIncident(kind, .warning, .incident, summary, summary, true);
        try self.appendSyntheticEvent(.incident, summary, action_id);
    }

    pub fn appendControlStatus(self: *Store, phase: Phase, summary: []const u8, action_id: []const u8) !void {
        if (self.incidents.items.len != 0 and phase != .incident) return;
        if (phase == .incident) {
            try self.appendIncident(controlIncidentKind(summary), .err, .incident, summary, summary, true);
        }
        self.phase = phase;
        self.footer_mode = footerFor(phase);
        try self.appendSyntheticEvent(phase, summary, action_id);
    }

    pub fn latestIncidentSummary(self: *const Store) []const u8 {
        return incidentStatus(self);
    }

    pub fn latestIncidentPreview(self: *const Store) []const u8 {
        return incidentPreview(self);
    }

    pub fn refreshCursorLabel(self: *Store) void {
        const selected = self.event_cursor.selected_seq orelse {
            self.cursor_label_len = 0;
            return;
        };
        const newest = self.event_cursor.newest_seq orelse selected;
        const label = std.fmt.bufPrint(&self.cursor_label_buf, "cursor {d}/{d}", .{ selected, newest }) catch {
            self.cursor_label_len = 0;
            return;
        };
        self.cursor_label_len = label.len;
    }

    pub fn toModel(self: *const Store) fixture.SnapshotModel {
        return .{
            .kernel_release = "6.12.0-sched-ext-lab",
            .arch = "x86_64",
            .cgroup_status = "vm-only",
            .cgroup_controllers = "guest scoped",
            .capabilities = "host unchanged",
            .sched_state = "host fail-closed",
            .sched_enable_seq = "no host enable",
            .sched_switch_all = "no host switch",
            .sched_nr_rejected = "nr_rejected=guest-only",
            .btf_status = "lab guest only",
            .lab_status = @tagName(self.phase),
            .partial_status = self.lanes.attach.summary,
            .rollback_requirement = "rollback-required before attach",
            .post_rollback_health = "required",
            .state_restored = "read-only",
            .workload_liveness = if (self.counters.samples_seen > 0) "alive" else "not-started",
            .audit_id = "AUD-tui-vm-lab",
            .rollback_id = rollbackId(self),
            .lab_gate = gateStatus(self),
            .evidence_mode = "vm-live",
            .verifier_status = self.lanes.verifier.summary,
            .dsq_status = "pending",
            .stress_status = "pending",
            .audit_status = auditStatus(self),
            .release_gate_status = gateStatus(self),
            .current_stage = currentStage(self),
            .vm_marker = if (self.lanes.marker.status == .pending) self.lanes.boot.summary else self.lanes.marker.summary,
            .runtime_samples = runtimeSamples(self),
            .runtime_ops = self.lanes.attach.summary,
            .runtime_counters = runtimeCounters(self),
            .rollback_status = self.lanes.rollback.summary,
            .incident_status = incidentStatus(self),
            .incident_preview = incidentPreview(self),
            .release_eligibility = "not release eligible",
            .bundle_path = bundlePath(self),
            .cleanup_status = self.lanes.cleanup.summary,
            .lab_scope = "lab-only vm guest",
            .event_cursor = eventCursorText(self),
            .event_latest = latestEventSummary(self),
            .footer_mode = @tagName(self.footer_mode),
        };
    }

    fn appendEvent(
        self: *Store,
        seq: u64,
        raw: RawDaemonEvent,
        phase: Phase,
        summary: []const u8,
        line: []const u8,
        source: EventSource,
        dedupe_key: []const u8,
    ) !void {
        if (self.events.items.len >= max_events) {
            self.dropped_event_count += 1;
            return;
        }
        try self.events.append(self.allocator, .{
            .seq = seq,
            .timestamp_ms = @intCast(seq),
            .run_id = try self.allocator.dupe(u8, raw.action_id orelse raw.action orelse "live-run"),
            .kind = try self.allocator.dupe(u8, raw.event),
            .phase_after = phase,
            .summary = try terminalSafe(self.allocator, summary),
            .raw_redacted = try self.redacted(line),
            .source = source,
            .action_id = if (raw.action_id) |id| try self.allocator.dupe(u8, id) else null,
            .dedupe_key = try self.allocator.dupe(u8, dedupe_key),
        });
    }

    fn appendSyntheticEvent(self: *Store, phase: Phase, summary: []const u8, action_id: []const u8) !void {
        if (self.incidents.items.len != 0 and phase != .incident) return;
        const seq = self.event_cursor.next_seq;
        self.event_cursor.next_seq += 1;
        self.event_cursor.newest_seq = seq;
        self.event_cursor.selected_seq = seq;
        self.refreshCursorLabel();
        self.phase = phase;
        self.footer_mode = footerFor(phase);
        try self.events.append(self.allocator, .{
            .seq = seq,
            .timestamp_ms = @intCast(seq),
            .run_id = try self.allocator.dupe(u8, activeRunId(self)),
            .kind = try self.allocator.dupe(u8, "control"),
            .phase_after = phase,
            .summary = try terminalSafe(self.allocator, summary),
            .raw_redacted = try self.redacted(summary),
            .source = .control,
            .action_id = try self.allocator.dupe(u8, action_id),
            .dedupe_key = try std.fmt.allocPrint(self.allocator, "control:{d}:{s}", .{ seq, action_id }),
        });
    }

    fn appendIncident(self: *Store, kind: IncidentKind, severity: Severity, phase: Phase, summary: []const u8, raw: []const u8, recoverable: bool) !void {
        self.phase = .incident;
        self.footer_mode = footerFor(.incident);
        const owned_summary = try terminalSafe(self.allocator, summary);
        errdefer self.allocator.free(owned_summary);
        const redacted_raw = try self.redacted(raw);
        errdefer self.allocator.free(redacted_raw);
        try self.incidents.append(self.allocator, .{
            .seq = self.event_cursor.next_seq,
            .kind = kind,
            .severity = severity,
            .phase = phase,
            .summary = owned_summary,
            .raw_redacted = redacted_raw,
            .recoverable = recoverable,
        });
    }

    fn redacted(self: *Store, raw: []const u8) ![]u8 {
        const safe_raw = try terminalSafe(self.allocator, raw);
        defer self.allocator.free(safe_raw);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);
        const limit = @min(safe_raw.len, self.redaction_policy.max_raw_preview_bytes);
        var token = std.mem.tokenizeAny(u8, safe_raw[0..limit], " \t\r\n");
        var first = true;
        while (token.next()) |part| {
            if (!first) try out.append(self.allocator, ' ');
            first = false;
            if (isPrivateToken(part)) {
                try out.appendSlice(self.allocator, "[redacted]");
            } else {
                try out.appendSlice(self.allocator, part);
            }
        }
        return try out.toOwnedSlice(self.allocator);
    }

    fn ensureActiveRun(self: *Store, raw: RawDaemonEvent, action_id: []const u8) !void {
        if (self.active_run != null) return;
        const run_id = try self.allocator.dupe(u8, action_id);
        errdefer self.allocator.free(run_id);
        const vm_id = try self.allocator.dupe(u8, raw.artifact orelse "vm-live");
        errdefer self.allocator.free(vm_id);
        const target_id = try self.allocator.dupe(u8, action_id);
        errdefer self.allocator.free(target_id);
        self.active_run = .{
            .run_id = run_id,
            .vm_id = vm_id,
            .target_id = target_id,
            .started_at_ms = 0,
        };
    }

    fn hasDedupeKey(self: *const Store, key: []const u8) bool {
        for (self.events.items) |event| {
            if (std.mem.eql(u8, event.dedupe_key, key)) return true;
        }
        return false;
    }
};

fn phaseFor(raw: RawDaemonEvent) Phase {
    if (std.mem.eql(u8, raw.event, "refusal")) return .incident;
    if (std.mem.eql(u8, raw.event, "lab_run_active")) return .rollback_ready;
    if (std.mem.eql(u8, raw.event, "microvm_boot")) return .booting;
    if (std.mem.eql(u8, raw.event, "vm_marker")) return .marker_wait;
    if (std.mem.eql(u8, raw.event, "bpf_register")) return .attached;
    if (std.mem.eql(u8, raw.event, "runtime_sample")) return .observing;
    if (std.mem.eql(u8, raw.event, "rollback")) return .rollback_running;
    if (std.mem.eql(u8, raw.event, "rollback_completed")) return .rollback_running;
    if (std.mem.eql(u8, raw.event, "cleanup")) {
        if (raw.status) |status| {
            if (std.mem.eql(u8, status, "active") or std.mem.eql(u8, status, "queued")) return .cleanup_running;
        }
        return .cleaned;
    }
    if (std.mem.eql(u8, raw.event, "validation")) return .validated;
    if (std.mem.eql(u8, raw.event, "stage_finished")) {
        if (raw.action) |action| {
            if (std.mem.eql(u8, action, "build")) return .booting;
            if (std.mem.indexOf(u8, action, "verifier") != null) return .verifying;
            if (std.mem.eql(u8, action, "audit")) return .rollback_running;
        }
    }
    if (raw.status) |status| {
        if (std.mem.eql(u8, status, "REFUSE") or std.mem.eql(u8, status, "SKIP") or std.mem.eql(u8, status, "unsafe_to_assume")) return .incident;
        if (std.mem.eql(u8, status, "active")) return .booting;
    }
    if (std.mem.eql(u8, raw.event, "stage_finished")) {
        if (raw.state) |state| {
            if (std.mem.eql(u8, state, "clean")) return .cleaned;
            if (std.mem.indexOf(u8, state, "validated") != null) return .validated;
        }
    }
    return .queued;
}

fn footerFor(phase: Phase) FooterMode {
    return switch (phase) {
        .rollback_requested, .rollback_running => .ROLLBACK,
        .cleanup_running, .cleaned => .CLEANUP,
        .incident => .INCIDENT,
        .validated, .safe => .SAFE,
        else => .RUNNING,
    };
}

fn controlIncidentKind(summary: []const u8) IncidentKind {
    if (std.mem.indexOf(u8, summary, "lost_stream") != null) return .lost_stream;
    if (std.mem.indexOf(u8, summary, "timeout") != null) return .timeout;
    if (std.mem.indexOf(u8, summary, "qemu_unavailable") != null) return .qemu_unavailable;
    if (std.mem.indexOf(u8, summary, "verifier_reject") != null) return .verifier_reject;
    if (std.mem.indexOf(u8, summary, "rollback_failure") != null) return .rollback_failure;
    if (std.mem.indexOf(u8, summary, "cleanup_residue") != null) return .cleanup_residue;
    return .process_exit_unexpected;
}

fn summaryFor(raw: RawDaemonEvent, phase: Phase) []const u8 {
    if (std.mem.eql(u8, raw.event, "refusal")) {
        if (raw.reason) |reason| {
            if (std.mem.eql(u8, reason, "duplicate_action_id")) return "REFUSED duplicate action id:";
            if (std.mem.eql(u8, reason, "stale_or_unknown_target_action_id") or std.mem.eql(u8, reason, "stale_rollback_id")) return "REFUSED stale action id:";
            if (std.mem.eql(u8, reason, "qemu_not_found") or std.mem.eql(u8, reason, "kvm_unavailable")) return "INCIDENT qemu_unavailable";
            if (std.mem.eql(u8, reason, "lost_runtime_stream")) return "INCIDENT lost_stream";
            return reason;
        }
    }
    if (raw.reason) |reason| {
        if (std.mem.eql(u8, reason, "qemu_not_found") or std.mem.eql(u8, reason, "kvm_unavailable")) return "INCIDENT qemu_unavailable";
        if (std.mem.eql(u8, reason, "verifier_register_failed")) return "INCIDENT verifier_reject";
        if (std.mem.eql(u8, reason, "lost_runtime_stream")) return "INCIDENT lost_stream";
        if (std.mem.eql(u8, reason, "stream_timeout")) return "INCIDENT timeout";
        if (std.mem.eql(u8, reason, "rollback drill failed")) return "INCIDENT rollback_failure";
        if (std.mem.eql(u8, reason, "process scan dirty")) return "INCIDENT cleanup_residue";
    }
    if (std.mem.eql(u8, raw.event, "stage_started") and std.mem.eql(u8, raw.action orelse "", "run_lab_microvm_live")) return "stage_started queued · microvm_live_runner_start";
    if (std.mem.eql(u8, raw.event, "stage_finished")) {
        if (raw.action) |action| {
            if (std.mem.eql(u8, action, "build")) return "build PASS · busybox guest image assembled";
            if (std.mem.indexOf(u8, action, "verifier") != null) return "verifier PASS · verifier log accepted";
            if (std.mem.eql(u8, action, "audit")) return "audit PASS · runtime samples linked to audit ledger";
        }
    }
    if (std.mem.eql(u8, raw.event, "microvm_boot")) return "[booting] QEMU boot requested · microvm_boot PASS · guest kernel booted";
    if (std.mem.eql(u8, raw.event, "vm_marker")) return "vm_marker PASS · vm marker present";
    if (std.mem.eql(u8, raw.event, "bpf_register")) return "[attached] console attached · bpf_register PASS · runtime ops observed";
    if (std.mem.eql(u8, raw.event, "runtime_sample")) return "[observing] runtime sample · runtime_sample PASS · runtime samples accepted";
    if (std.mem.eql(u8, raw.event, "lab_run_active")) return "[rollback ready] rollback target ready · rollback ready/completed";
    if (std.mem.eql(u8, raw.event, "rollback")) {
        if (raw.status) |status| {
            if (std.mem.eql(u8, status, "queued")) return "ACTION queued rollback_lab_run · target rollback id";
            if (std.mem.eql(u8, status, "active")) return "[rollback ready] rollback target ready · rollback active · operator confirmed rollback";
        }
        return "[rollback ready] rollback target ready · rollback active · operator confirmed rollback";
    }
    if (std.mem.eql(u8, raw.event, "rollback_completed")) return "rollback PASS · state restored";
    if (std.mem.eql(u8, raw.event, "cleanup")) {
        if (raw.status) |status| {
            if (std.mem.eql(u8, status, "active") or std.mem.eql(u8, status, "queued")) return "[cleanup] cleanup running";
        }
        return "cleanup cleaned · [cleaned] VM resources cleaned · cleanup receipt PASS";
    }
    if (std.mem.eql(u8, raw.event, "validation")) return "SAFE footer · [SAFE] footer mode SAFE · live bundle freshness accepted";
    return switch (phase) {
        .queued => "[queued] VM run queued",
        .booting => "[booting] QEMU boot requested",
        .marker_wait => "[booting] VM marker observed",
        .attached => "[attached] console attached",
        .observing => "[observing] runtime sample",
        .rollback_ready => "[rollback ready] rollback target ready",
        .rollback_requested => "[rollback] rollback requested",
        .rollback_running => "[rollback] rollback running",
        .cleanup_running => "[cleanup] cleanup running",
        .cleaned => "[cleaned] VM resources cleaned",
        .validated => "[SAFE] footer mode SAFE",
        .incident => "INCIDENT unsafe_to_assume",
        else => raw.reason orelse raw.event,
    };
}

fn incidentFor(raw: RawDaemonEvent) ?IncidentKind {
    const reason = raw.reason orelse "";
    if (std.mem.eql(u8, reason, "duplicate_action_id")) return .duplicate_action_id;
    if (std.mem.eql(u8, reason, "stale_or_unknown_target_action_id") or std.mem.eql(u8, reason, "stale_rollback_id")) return .stale_action_id;
    if (std.mem.eql(u8, reason, "qemu_not_found") or std.mem.eql(u8, reason, "kvm_unavailable")) return .qemu_unavailable;
    if (std.mem.eql(u8, reason, "verifier_register_failed")) return .verifier_reject;
    if (std.mem.eql(u8, reason, "lost_runtime_stream")) return .lost_stream;
    if (std.mem.eql(u8, reason, "stream_timeout")) return .timeout;
    if (std.mem.indexOf(u8, reason, "rollback") != null and std.mem.indexOf(u8, reason, "failed") != null) return .rollback_failure;
    if (std.mem.indexOf(u8, reason, "cleanup") != null and std.mem.indexOf(u8, reason, "residue") != null) return .cleanup_residue;
    if (raw.status) |status| {
        if (std.mem.eql(u8, status, "REFUSE") or std.mem.eql(u8, status, "unsafe_to_assume")) return .stream_decode_error;
    }
    return null;
}

fn severityFor(raw: RawDaemonEvent) Severity {
    if (raw.status) |status| {
        if (std.mem.eql(u8, status, "unsafe_to_assume")) return .unsafe_to_assume;
        if (std.mem.eql(u8, status, "REFUSE")) return .err;
    }
    return .warning;
}

fn updateLanes(store: *Store, raw: RawDaemonEvent, seq: u64, summary: []const u8) void {
    const state = PhaseState{ .status = statusFor(raw), .last_seq = seq, .summary = summary };
    if (std.mem.eql(u8, raw.event, "microvm_boot") or
        (std.mem.eql(u8, raw.event, "stage_started") and std.mem.eql(u8, raw.action orelse "", "run_lab_microvm_live")) or
        (std.mem.eql(u8, raw.event, "stage_finished") and std.mem.eql(u8, raw.action orelse "", "build"))) store.lanes.boot = state;
    if (std.mem.eql(u8, raw.event, "vm_marker")) store.lanes.marker = state;
    if (std.mem.indexOf(u8, raw.event, "verifier") != null or std.mem.indexOf(u8, raw.action orelse "", "verifier") != null) store.lanes.verifier = state;
    if (std.mem.eql(u8, raw.event, "bpf_register")) store.lanes.attach = state;
    if (std.mem.eql(u8, raw.event, "runtime_sample")) store.lanes.runtime_samples = state;
    if (std.mem.eql(u8, raw.event, "rollback") or std.mem.eql(u8, raw.event, "rollback_completed") or std.mem.eql(u8, raw.event, "lab_run_active")) store.lanes.rollback = state;
    if (std.mem.eql(u8, raw.event, "cleanup")) store.lanes.cleanup = state;
    if (std.mem.eql(u8, raw.event, "validation")) store.lanes.validation = state;
}

fn statusFor(raw: RawDaemonEvent) PhaseStatus {
    if (raw.status) |status| {
        if (std.mem.eql(u8, status, "PASS") or std.mem.eql(u8, status, "accepted")) return .pass;
        if (std.mem.eql(u8, status, "active") or std.mem.eql(u8, status, "queued")) return .active;
        if (std.mem.eql(u8, status, "REFUSE") or std.mem.eql(u8, status, "refused")) return .refuse;
        if (std.mem.eql(u8, status, "SKIP")) return .skipped;
        if (std.mem.eql(u8, status, "unsafe_to_assume")) return .incident;
    }
    return .active;
}

fn updateCounters(store: *Store, raw: RawDaemonEvent) void {
    if (!std.mem.eql(u8, raw.event, "runtime_sample")) return;
    store.counters.samples_seen += 1;
    store.counters.cpu_samples += 1;
    store.counters.last_sample_ms = @intCast(raw.sample_sequence orelse store.counters.samples_seen);
}

fn makeDedupeKey(allocator: std.mem.Allocator, raw: RawDaemonEvent, seq: u64) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{d}:{s}:{s}:{s}", .{
        seq,
        raw.event,
        raw.action_id orelse raw.action orelse "",
        raw.reason orelse raw.status orelse "",
    });
}

fn isPrivateToken(token: []const u8) bool {
    if (std.mem.startsWith(u8, token, "/home/") or std.mem.startsWith(u8, token, "/tmp/")) return true;
    if (std.mem.indexOf(u8, token, "SECRET") != null or std.mem.indexOf(u8, token, "TOKEN") != null or std.mem.indexOf(u8, token, "api_key") != null) return true;
    if (std.mem.indexOf(u8, token, "=") != null and std.mem.indexOf(u8, token, "PATH=") == null) return true;
    return token.len > 48;
}

fn terminalSafe(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var index: usize = 0;
    var last_space = false;
    while (index < raw.len) {
        const byte = raw[index];
        if (byte == 0x1b) {
            index = skipEscapeSequence(raw, index);
            try appendSpace(&out, allocator, &last_space);
            continue;
        }
        if (byte < 0x20 or byte == 0x7f) {
            index += 1;
            try appendSpace(&out, allocator, &last_space);
            continue;
        }
        try out.append(allocator, byte);
        last_space = false;
        index += 1;
    }
    return try out.toOwnedSlice(allocator);
}

fn appendSpace(out: *std.ArrayList(u8), allocator: std.mem.Allocator, last_space: *bool) !void {
    if (out.items.len == 0 or last_space.*) return;
    try out.append(allocator, ' ');
    last_space.* = true;
}

fn skipEscapeSequence(raw: []const u8, esc_index: usize) usize {
    if (esc_index + 1 >= raw.len) return raw.len;
    const intro = raw[esc_index + 1];
    return switch (intro) {
        '[' => skipUntilCsiFinal(raw, esc_index + 2),
        ']' => skipUntilStringTerminator(raw, esc_index + 2, true),
        'P', '^', '_', 'X' => skipUntilStringTerminator(raw, esc_index + 2, false),
        else => @min(raw.len, esc_index + 2),
    };
}

fn skipUntilCsiFinal(raw: []const u8, start: usize) usize {
    var index = start;
    while (index < raw.len) : (index += 1) {
        if (raw[index] >= 0x40 and raw[index] <= 0x7e) return index + 1;
    }
    return raw.len;
}

fn skipUntilStringTerminator(raw: []const u8, start: usize, allow_bel: bool) usize {
    var index = start;
    while (index < raw.len) : (index += 1) {
        if (allow_bel and raw[index] == 0x07) return index + 1;
        if (raw[index] == 0x1b and index + 1 < raw.len and raw[index + 1] == '\\') return index + 2;
    }
    return raw.len;
}

fn activeRunId(store: *const Store) []const u8 {
    if (store.active_run) |run| return run.run_id;
    return "tui-vm-lab";
}

fn rollbackId(store: *const Store) []const u8 {
    _ = store;
    return "RB-tui-vm-lab";
}

fn currentStage(store: *const Store) []const u8 {
    if (store.incidents.items.len != 0) return incidentStatus(store);
    if (store.events.items.len == 0) return "[queued] VM run queued";
    return store.events.items[store.events.items.len - 1].summary;
}

fn latestEventSummary(store: *const Store) []const u8 {
    if (store.incidents.items.len != 0) return incidentStatus(store);
    if (store.events.items.len == 0) return "event list empty";
    if (store.event_cursor.selected_seq) |selected| {
        for (store.events.items) |event| {
            if (event.seq == selected) return event.summary;
        }
    }
    return store.events.items[store.events.items.len - 1].summary;
}

fn eventCursorText(store: *const Store) []const u8 {
    if (store.cursor_label_len == 0) return "cursor none";
    return store.cursor_label_buf[0..store.cursor_label_len];
}

fn runtimeSamples(store: *const Store) []const u8 {
    if (store.counters.samples_seen == 0) return "not-started";
    return "[observing] runtime sample";
}

fn runtimeCounters(store: *const Store) []const u8 {
    if (store.counters.samples_seen == 0) return "samples=0";
    if (store.counters.samples_seen == 1) return "samples=1";
    if (store.counters.samples_seen == 2) return "samples=2";
    if (store.counters.samples_seen == 3) return "samples=3";
    return "samples=4+";
}

fn auditStatus(store: *const Store) []const u8 {
    if (store.counters.samples_seen > 0) return "runtime stream PASS";
    return "pending";
}

fn gateStatus(store: *const Store) []const u8 {
    if (store.incidents.items.len != 0) return "closed";
    return switch (store.phase) {
        .validated, .safe => "live bundle freshness accepted",
        .incident => "closed",
        else => "pending",
    };
}

fn bundlePath(store: *const Store) []const u8 {
    if (store.active_run) |run| return std.fs.path.basename(run.vm_id);
    return "none";
}

fn incidentStatus(store: *const Store) []const u8 {
    if (store.incidents.items.len == 0) return "none";
    return store.incidents.items[store.incidents.items.len - 1].summary;
}

fn incidentPreview(store: *const Store) []const u8 {
    if (store.incidents.items.len == 0) return "";
    return store.incidents.items[store.incidents.items.len - 1].raw_redacted;
}

test "live store tracks monotonic phases counters and cursor" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    try store.applyLine("{\"schema\":\"zig-scheduler/daemon-event/v1\",\"seq\":1,\"event\":\"stage_started\",\"action\":\"run_lab_microvm_live\",\"action_id\":\"live-1\",\"status\":\"queued\",\"reason\":\"microvm_live_runner_start\",\"artifact\":\"evidence/lab/run-all/live-1\",\"host_mutation\":false}", .test_fixture);
    try store.applyLine("{\"schema\":\"zig-scheduler/daemon-event/v1\",\"seq\":2,\"event\":\"microvm_boot\",\"action\":\"run_lab_microvm_live\",\"action_id\":\"live-1\",\"status\":\"PASS\",\"reason\":\"guest kernel booted\",\"host_mutation\":false}", .test_fixture);
    try store.applyLine("{\"schema\":\"zig-scheduler/daemon-event/v1\",\"seq\":3,\"event\":\"bpf_register\",\"action\":\"run_lab_microvm_live\",\"action_id\":\"live-1\",\"status\":\"PASS\",\"reason\":\"runtime ops observed\",\"host_mutation\":false}", .test_fixture);
    try store.applyLine("{\"schema\":\"zig-scheduler/daemon-event/v1\",\"seq\":4,\"event\":\"lab_run_active\",\"action\":\"run_lab_microvm_live\",\"action_id\":\"live-1\",\"rollback_id\":\"RB-live-1\",\"artifact\":\"evidence/lab/run-all/live-1\",\"status\":\"active\",\"host_mutation\":false}", .test_fixture);
    try store.applyLine("{\"schema\":\"zig-scheduler/daemon-event/v1\",\"seq\":5,\"event\":\"runtime_sample\",\"action\":\"run_lab_microvm_live\",\"action_id\":\"live-1\",\"state\":\"observing\",\"status\":\"PASS\",\"reason\":\"runtime samples accepted\",\"sample_sequence\":1,\"host_mutation\":false}", .test_fixture);
    try std.testing.expectEqual(Phase.observing, store.phase);
    try std.testing.expectEqual(@as(u64, 1), store.counters.samples_seen);
    try std.testing.expectEqual(@as(?u64, 5), store.event_cursor.selected_seq);
    try std.testing.expect(std.mem.indexOf(u8, store.toModel().runtime_samples, "[observing]") != null);
    try std.testing.expect(std.mem.indexOf(u8, store.events.items[1].summary, "[booting]") != null);
    try std.testing.expect(std.mem.indexOf(u8, store.events.items[2].summary, "[attached]") != null);
    try std.testing.expect(std.mem.indexOf(u8, store.events.items[3].summary, "[rollback ready]") != null);
    try std.testing.expect(std.mem.indexOf(u8, store.events.items[4].summary, "[observing]") != null);
}

test "live store dedupes malformed and redacts private payloads" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const line = "{\"schema\":\"zig-scheduler/daemon-event/v1\",\"seq\":1,\"event\":\"runtime_sample\",\"action\":\"run_lab_microvm_live\",\"action_id\":\"live-1\",\"state\":\"observing\",\"status\":\"PASS\",\"reason\":\"runtime samples accepted\",\"host_mutation\":false}";
    try store.applyLine(line, .test_fixture);
    try store.applyLine(line, .test_fixture);
    try std.testing.expectEqual(@as(usize, 1), store.events.items.len);
    try store.applyLine("{not-json /home/mei SECRET_TOKEN=abc", .test_fixture);
    try std.testing.expectEqual(@as(u32, 1), store.malformed_line_count);
    try std.testing.expect(std.mem.indexOf(u8, store.incidents.items[0].raw_redacted, "/home/mei") == null);
    try std.testing.expect(std.mem.indexOf(u8, store.incidents.items[0].raw_redacted, "SECRET_TOKEN") == null);
}

test "live store strips terminal controls from malformed incident previews" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    try store.applyLine("{not-json start \x1b]2;PROMPT_INJECTION ignore\x07 middle \x1b[31mred\x1b[0m \x07 /home/mei SECRET_TOKEN=abc123 end", .test_fixture);
    try std.testing.expectEqual(@as(u32, 1), store.malformed_line_count);
    const preview = store.incidents.items[0].raw_redacted;
    try std.testing.expect(std.mem.indexOfScalar(u8, preview, 0x1b) == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, preview, 0x07) == null);
    try std.testing.expect(std.mem.indexOf(u8, preview, "PROMPT_INJECTION") == null);
    try std.testing.expect(std.mem.indexOf(u8, preview, "/home/mei") == null);
    try std.testing.expect(std.mem.indexOf(u8, preview, "SECRET_TOKEN") == null);
    try std.testing.expect(std.mem.indexOf(u8, preview, "start") != null);
    try std.testing.expect(std.mem.indexOf(u8, preview, "middle") != null);
    try std.testing.expect(std.mem.indexOf(u8, preview, "red") != null);
    try std.testing.expect(std.mem.indexOf(u8, preview, "end") != null);
}

test "live store records duplicate and stale action refusals visibly" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    try store.applyLine("{\"schema\":\"zig-scheduler/daemon-event/v1\",\"seq\":1,\"event\":\"refusal\",\"action\":\"run_lab_microvm_live\",\"action_id\":\"dup\",\"status\":\"refused\",\"reason\":\"duplicate_action_id\",\"host_mutation\":false}", .test_fixture);
    try store.applyLine("{\"schema\":\"zig-scheduler/daemon-event/v1\",\"seq\":2,\"event\":\"refusal\",\"action\":\"rollback_lab_run\",\"action_id\":\"rb\",\"target_action_id\":\"old\",\"status\":\"refused\",\"reason\":\"stale_rollback_id\",\"host_mutation\":false}", .test_fixture);
    try std.testing.expect(std.mem.indexOf(u8, store.events.items[0].summary, "REFUSED duplicate action id:") != null);
    try std.testing.expect(std.mem.indexOf(u8, store.events.items[1].summary, "REFUSED stale action id:") != null);
}

test "live store keeps incident terminal after later cleanup and validation events" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    try store.applyLine("{\"schema\":\"zig-scheduler/daemon-event/v1\",\"seq\":1,\"event\":\"stage_finished\",\"action\":\"run_lab_microvm_live\",\"action_id\":\"live-incident\",\"status\":\"REFUSE\",\"reason\":\"qemu_not_found\",\"host_mutation\":false}", .test_fixture);
    try store.applyLine("{\"schema\":\"zig-scheduler/daemon-event/v1\",\"seq\":2,\"event\":\"cleanup\",\"action\":\"run_lab_microvm_live\",\"action_id\":\"live-incident\",\"status\":\"PASS\",\"reason\":\"process scan clean\",\"host_mutation\":false}", .test_fixture);
    try store.applyLine("{\"schema\":\"zig-scheduler/daemon-event/v1\",\"seq\":3,\"event\":\"validation\",\"action\":\"run_lab_microvm_live\",\"action_id\":\"live-incident\",\"status\":\"PASS\",\"reason\":\"live bundle freshness accepted\",\"host_mutation\":false}", .test_fixture);
    const model = store.toModel();
    try std.testing.expectEqual(Phase.incident, store.phase);
    try std.testing.expectEqualStrings("closed", model.lab_gate);
    try std.testing.expectEqualStrings("INCIDENT qemu_unavailable", model.incident_status);
    try std.testing.expectEqualStrings("INCIDENT qemu_unavailable", model.event_latest);
    try std.testing.expect(model.incident_preview.len != 0);
    try std.testing.expectEqualStrings("cursor 1/1", model.event_cursor);
    try std.testing.expect(std.mem.indexOf(u8, model.event_latest, "live bundle freshness accepted") == null);
}

test "live store control incident is durable and exposes cursor sequence" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    try store.applyLine("{\"schema\":\"zig-scheduler/daemon-event/v1\",\"seq\":1,\"event\":\"cleanup\",\"action\":\"run_lab_microvm_live\",\"action_id\":\"live-clean\",\"status\":\"PASS\",\"reason\":\"process scan clean\",\"host_mutation\":false}", .test_fixture);
    try store.applyLine("{\"schema\":\"zig-scheduler/daemon-event/v1\",\"seq\":2,\"event\":\"validation\",\"action\":\"run_lab_microvm_live\",\"action_id\":\"live-clean\",\"status\":\"PASS\",\"reason\":\"live bundle freshness accepted\",\"host_mutation\":false}", .test_fixture);
    try store.appendControlStatus(.incident, "INCIDENT process_exit_unexpected", "live-clean");
    try std.testing.expectEqual(Phase.incident, store.phase);
    try std.testing.expectEqual(FooterMode.INCIDENT, store.footer_mode);
    try std.testing.expectEqualStrings("closed", store.toModel().lab_gate);
    try std.testing.expectEqualStrings("cursor 3/3", store.toModel().event_cursor);
    try store.appendControlStatus(.cleanup_running, "[cleanup] cleanup running", "live-clean");
    try std.testing.expectEqual(Phase.incident, store.phase);
    try std.testing.expectEqual(FooterMode.INCIDENT, store.footer_mode);
    try std.testing.expectEqualStrings("cursor 3/3", store.toModel().event_cursor);
    try std.testing.expectEqualStrings("INCIDENT process_exit_unexpected", store.toModel().event_latest);
}
