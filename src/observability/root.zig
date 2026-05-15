const std = @import("std");
const list_writer = @import("list_writer");

pub const support_matrix_path = "fixtures/linux-observability/support-matrix.json";
pub const default_manifest_path = "fixtures/linux-observability/manifests/tracefs-sched-demo.json";

pub const support_matrix_schema = "zig-scheduler/linux-observability-support-matrix";
pub const fixture_manifest_schema = "zig-scheduler/linux-observability-fixture-manifest";
pub const approved_family = "tracefs-sched-snapshot";
pub const approved_snapshot_format_version = "tracefs-sched-text-v1";
pub const approved_scrub_policy_version = "linux-observability-scrub-v1";

pub const Error = error{
    InvalidManifest,
    InvalidSupportMatrix,
    InvalidSnapshotLine,
    MissingPayloadField,
    UnsupportedFamily,
    UnsupportedSchema,
    UnsupportedTuple,
    UnsupportedEvent,
};

pub const EventKind = enum {
    sched_switch,
    sched_wakeup,
    sched_wakeup_new,
    sched_process_fork,
    sched_process_exit,

    pub fn label(kind: EventKind) []const u8 {
        return @tagName(kind);
    }
};

pub const Event = struct {
    kind: EventKind,
    cpu: u16,
    timestamp: f64,
    subject_pid: ?u32,
    related_pid: ?u32,
    comm: ?[]const u8,
    related_comm: ?[]const u8,
    raw_line: []const u8,
};

pub const EventCounts = struct {
    sched_switch: usize = 0,
    sched_wakeup: usize = 0,
    sched_wakeup_new: usize = 0,
    sched_process_fork: usize = 0,
    sched_process_exit: usize = 0,

    fn bump(counts: *EventCounts, kind: EventKind) void {
        switch (kind) {
            .sched_switch => counts.sched_switch += 1,
            .sched_wakeup => counts.sched_wakeup += 1,
            .sched_wakeup_new => counts.sched_wakeup_new += 1,
            .sched_process_fork => counts.sched_process_fork += 1,
            .sched_process_exit => counts.sched_process_exit += 1,
        }
    }
};

pub const Tuple = struct {
    family: []const u8,
    kernel_release: []const u8,
    tool_version: []const u8,
    tracefs_root: []const u8,
    capture_recipe: []const u8,
    trace_clock: []const u8,
    enabled_sched_events: []const []const u8,
    scope: []const u8,
    mode: []const u8,
    time_window: []const u8,
    snapshot_format_version: []const u8,
    scrub_policy_version: []const u8,
};

pub const FixtureManifest = struct {
    schema: []const u8,
    version: u32,
    fixture_name: []const u8,
    source_class: []const u8,
    raw_snapshot_path: []const u8,
    redistribution_basis: []const u8,
    observability_only_caveats: []const []const u8,
    tuple: Tuple,
};

pub const SupportMatrix = struct {
    schema: []const u8,
    version: u32,
    approved_tuples: []const Tuple,
    rejected_families: []const []const u8,
};

pub const ObservabilitySummary = struct {
    fixture_name: []const u8,
    family: []const u8,
    kernel_release: []const u8,
    snapshot_format_version: []const u8,
    scrub_policy_version: []const u8,
    source_class: []const u8,
    redistribution_basis: []const u8,
    event_count: usize,
    cpu_ids: []u16,
    pid_ids: []u32,
    first_timestamp: f64,
    last_timestamp: f64,
    counts: EventCounts,

    pub fn deinit(summary: *ObservabilitySummary, allocator: std.mem.Allocator) void {
        allocator.free(summary.cpu_ids);
        allocator.free(summary.pid_ids);
    }
};

pub const LoadedFixture = struct {
    manifest: std.json.Parsed(FixtureManifest),
    snapshot_bytes: []u8,
    events: []Event,
    summary: ObservabilitySummary,

    pub fn deinit(loaded: *LoadedFixture, allocator: std.mem.Allocator) void {
        loaded.summary.deinit(allocator);
        allocator.free(loaded.events);
        allocator.free(loaded.snapshot_bytes);
        loaded.manifest.deinit();
    }
};

pub fn loadSupportMatrix(allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed(SupportMatrix) {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .unlimited);
    defer allocator.free(bytes);

    var parsed = try std.json.parseFromSlice(SupportMatrix, allocator, bytes, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
    });
    errdefer parsed.deinit();

    if (!std.mem.eql(u8, parsed.value.schema, support_matrix_schema) or parsed.value.version != 1) {
        return Error.UnsupportedSchema;
    }
    if (parsed.value.approved_tuples.len != 1) return Error.InvalidSupportMatrix;

    return parsed;
}

pub fn loadManifest(allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed(FixtureManifest) {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .unlimited);
    defer allocator.free(bytes);

    var parsed = try std.json.parseFromSlice(FixtureManifest, allocator, bytes, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
    });
    errdefer parsed.deinit();

    if (!std.mem.eql(u8, parsed.value.schema, fixture_manifest_schema) or parsed.value.version != 1) {
        return Error.UnsupportedSchema;
    }
    if (parsed.value.observability_only_caveats.len == 0) return Error.InvalidManifest;

    return parsed;
}

pub fn validateManifestAgainstMatrix(manifest: *const FixtureManifest, matrix: *const SupportMatrix) Error!void {
    if (!std.mem.eql(u8, manifest.tuple.family, approved_family)) return Error.UnsupportedFamily;
    if (!std.mem.eql(u8, manifest.tuple.snapshot_format_version, approved_snapshot_format_version)) return Error.UnsupportedTuple;
    if (!std.mem.eql(u8, manifest.tuple.scrub_policy_version, approved_scrub_policy_version)) return Error.UnsupportedTuple;

    for (matrix.rejected_families) |rejected_family| {
        if (std.mem.eql(u8, manifest.tuple.family, rejected_family)) return Error.UnsupportedFamily;
    }

    for (matrix.approved_tuples) |tuple| {
        if (tupleEql(&manifest.tuple, &tuple)) return;
    }
    return Error.UnsupportedTuple;
}

pub fn loadFixture(allocator: std.mem.Allocator, manifest_path: []const u8) !LoadedFixture {
    var matrix = try loadSupportMatrix(allocator, support_matrix_path);
    defer matrix.deinit();

    var manifest = try loadManifest(allocator, manifest_path);
    errdefer manifest.deinit();

    try validateManifestAgainstMatrix(&manifest.value, &matrix.value);

    const snapshot_bytes = try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), manifest.value.raw_snapshot_path, allocator, .unlimited);
    errdefer allocator.free(snapshot_bytes);

    const events = try parseSnapshot(allocator, snapshot_bytes, &manifest.value.tuple);
    errdefer allocator.free(events);

    var summary = try summarizeEvents(allocator, &manifest.value, events);
    errdefer summary.deinit(allocator);

    return .{
        .manifest = manifest,
        .snapshot_bytes = snapshot_bytes,
        .events = events,
        .summary = summary,
    };
}

pub fn renderSummaryMarkdown(allocator: std.mem.Allocator, summary: *const ObservabilitySummary) ![]u8 {
    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(allocator);
    var writer = list_writer.writer(&buffer, allocator);

    try writer.print(
        "# Linux observability summary\n\n" ++
            "- Fixture: `{s}`\n" ++
            "- Approved tuple: `{s}` / `{s}` / `{s}` / `{s}`\n" ++
            "- Source class: {s}\n" ++
            "- Redistribution basis: {s}\n" ++
            "- Observability boundary: offline committed fixture only; not replay, calibration, or Linux-performance evidence\n" ++
            "- Event count: {}\n" ++
            "- Timestamp span: {d:.6} -> {d:.6}\n",
        .{
            summary.fixture_name,
            summary.family,
            summary.kernel_release,
            summary.snapshot_format_version,
            summary.scrub_policy_version,
            summary.source_class,
            summary.redistribution_basis,
            summary.event_count,
            summary.first_timestamp,
            summary.last_timestamp,
        },
    );

    try writer.writeAll("- CPUs seen: ");
    try writeIntegerList(u16, &writer, summary.cpu_ids);
    try writer.writeByte('\n');

    try writer.writeAll("- PIDs seen: ");
    try writeIntegerList(u32, &writer, summary.pid_ids);
    try writer.writeByte('\n');

    try writer.writeAll("\n## Event counts\n\n");
    try writer.print(
        "- `sched_switch`: {}\n- `sched_wakeup`: {}\n- `sched_wakeup_new`: {}\n- `sched_process_fork`: {}\n- `sched_process_exit`: {}\n",
        .{
            summary.counts.sched_switch,
            summary.counts.sched_wakeup,
            summary.counts.sched_wakeup_new,
            summary.counts.sched_process_fork,
            summary.counts.sched_process_exit,
        },
    );

    return try buffer.toOwnedSlice(allocator);
}

pub fn loadFixtureSummaryMarkdown(allocator: std.mem.Allocator, manifest_path: []const u8) ![]u8 {
    var loaded = try loadFixture(allocator, manifest_path);
    defer loaded.deinit(allocator);
    return try renderSummaryMarkdown(allocator, &loaded.summary);
}

fn tupleEql(lhs: *const Tuple, rhs: *const Tuple) bool {
    return std.mem.eql(u8, lhs.family, rhs.family) and
        std.mem.eql(u8, lhs.kernel_release, rhs.kernel_release) and
        std.mem.eql(u8, lhs.tool_version, rhs.tool_version) and
        std.mem.eql(u8, lhs.tracefs_root, rhs.tracefs_root) and
        std.mem.eql(u8, lhs.capture_recipe, rhs.capture_recipe) and
        std.mem.eql(u8, lhs.trace_clock, rhs.trace_clock) and
        stringSliceEql(lhs.enabled_sched_events, rhs.enabled_sched_events) and
        std.mem.eql(u8, lhs.scope, rhs.scope) and
        std.mem.eql(u8, lhs.mode, rhs.mode) and
        std.mem.eql(u8, lhs.time_window, rhs.time_window) and
        std.mem.eql(u8, lhs.snapshot_format_version, rhs.snapshot_format_version) and
        std.mem.eql(u8, lhs.scrub_policy_version, rhs.scrub_policy_version);
}

fn stringSliceEql(lhs: []const []const u8, rhs: []const []const u8) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |lhs_item, rhs_item| {
        if (!std.mem.eql(u8, lhs_item, rhs_item)) return false;
    }
    return true;
}

fn parseSnapshot(allocator: std.mem.Allocator, snapshot_bytes: []const u8, tuple: *const Tuple) ![]Event {
    var events: std.ArrayList(Event) = .empty;
    errdefer events.deinit(allocator);

    var line_iter = std.mem.splitScalar(u8, snapshot_bytes, '\n');
    while (line_iter.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        const event = try parseEventLine(line, tuple);
        try events.append(allocator, event);
    }

    if (events.items.len == 0) return Error.InvalidManifest;
    return try events.toOwnedSlice(allocator);
}

fn parseEventLine(line: []const u8, tuple: *const Tuple) !Event {
    const event_marker = std.mem.indexOf(u8, line, ": sched_") orelse return Error.InvalidSnapshotLine;
    const left = line[0..event_marker];
    const after_timestamp = line[event_marker + 2 ..];
    const kind_end = std.mem.indexOfScalar(u8, after_timestamp, ':') orelse return Error.InvalidSnapshotLine;

    var token_iter = std.mem.tokenizeAny(u8, left, " \t");
    var timestamp_token: ?[]const u8 = null;
    while (token_iter.next()) |token| {
        timestamp_token = token;
    }
    const timestamp = try std.fmt.parseFloat(f64, timestamp_token orelse return Error.InvalidSnapshotLine);

    const cpu = try parseCpu(line);
    const kind_name = after_timestamp[0..kind_end];
    const kind = try parseEventKind(kind_name);
    try ensureEventAllowed(kind, tuple);

    const payload = std.mem.trimStart(u8, after_timestamp[kind_end + 1 ..], " \t");

    return switch (kind) {
        .sched_switch => .{
            .kind = kind,
            .cpu = cpu,
            .timestamp = timestamp,
            .subject_pid = try parsePayloadInt(payload, "next_pid"),
            .related_pid = try parsePayloadInt(payload, "prev_pid"),
            .comm = try parsePayloadString(payload, "next_comm"),
            .related_comm = try parsePayloadString(payload, "prev_comm"),
            .raw_line = line,
        },
        .sched_process_fork => .{
            .kind = kind,
            .cpu = cpu,
            .timestamp = timestamp,
            .subject_pid = try parsePayloadInt(payload, "pid"),
            .related_pid = try parsePayloadInt(payload, "child_pid"),
            .comm = try parsePayloadString(payload, "comm"),
            .related_comm = try parsePayloadString(payload, "child_comm"),
            .raw_line = line,
        },
        else => .{
            .kind = kind,
            .cpu = cpu,
            .timestamp = timestamp,
            .subject_pid = try parsePayloadInt(payload, "pid"),
            .related_pid = null,
            .comm = try parsePayloadString(payload, "comm"),
            .related_comm = null,
            .raw_line = line,
        },
    };
}

fn ensureEventAllowed(kind: EventKind, tuple: *const Tuple) !void {
    for (tuple.enabled_sched_events) |allowed| {
        if (std.mem.eql(u8, allowed, kind.label())) return;
    }
    return Error.UnsupportedEvent;
}

fn parseEventKind(kind_name: []const u8) !EventKind {
    inline for (std.meta.fields(EventKind)) |field| {
        if (std.mem.eql(u8, field.name, kind_name)) {
            return @field(EventKind, field.name);
        }
    }
    return Error.UnsupportedEvent;
}

fn parseCpu(line: []const u8) !u16 {
    const start = std.mem.indexOfScalar(u8, line, '[') orelse return Error.InvalidSnapshotLine;
    const end = std.mem.indexOfScalarPos(u8, line, start + 1, ']') orelse return Error.InvalidSnapshotLine;
    return try std.fmt.parseInt(u16, line[start + 1 .. end], 10);
}

fn parsePayloadString(payload: []const u8, key: []const u8) ![]const u8 {
    return findPayloadValue(payload, key) orelse Error.MissingPayloadField;
}

fn parsePayloadInt(payload: []const u8, key: []const u8) !u32 {
    const value = findPayloadValue(payload, key) orelse return Error.MissingPayloadField;
    return try std.fmt.parseInt(u32, value, 10);
}

fn findPayloadValue(payload: []const u8, key: []const u8) ?[]const u8 {
    var token_iter = std.mem.tokenizeScalar(u8, payload, ' ');
    while (token_iter.next()) |token| {
        if (std.mem.eql(u8, token, "==>")) continue;
        if (!std.mem.containsAtLeast(u8, token, 1, "=")) continue;

        const eq_index = std.mem.indexOfScalar(u8, token, '=') orelse continue;
        if (!std.mem.eql(u8, token[0..eq_index], key)) continue;
        return token[eq_index + 1 ..];
    }
    return null;
}

fn summarizeEvents(allocator: std.mem.Allocator, manifest: *const FixtureManifest, events: []const Event) !ObservabilitySummary {
    var cpu_set = std.AutoHashMap(u16, void).init(allocator);
    defer cpu_set.deinit();
    var pid_set = std.AutoHashMap(u32, void).init(allocator);
    defer pid_set.deinit();

    var counts: EventCounts = .{};
    var first_timestamp = events[0].timestamp;
    var last_timestamp = events[0].timestamp;

    for (events) |event| {
        counts.bump(event.kind);
        try cpu_set.put(event.cpu, {});
        if (event.subject_pid) |pid| try pid_set.put(pid, {});
        if (event.related_pid) |pid| try pid_set.put(pid, {});
        first_timestamp = @min(first_timestamp, event.timestamp);
        last_timestamp = @max(last_timestamp, event.timestamp);
    }

    const cpu_ids = try sortedKeys(u16, allocator, &cpu_set);
    errdefer allocator.free(cpu_ids);
    const pid_ids = try sortedKeys(u32, allocator, &pid_set);
    errdefer allocator.free(pid_ids);

    return .{
        .fixture_name = manifest.fixture_name,
        .family = manifest.tuple.family,
        .kernel_release = manifest.tuple.kernel_release,
        .snapshot_format_version = manifest.tuple.snapshot_format_version,
        .scrub_policy_version = manifest.tuple.scrub_policy_version,
        .source_class = manifest.source_class,
        .redistribution_basis = manifest.redistribution_basis,
        .event_count = events.len,
        .cpu_ids = cpu_ids,
        .pid_ids = pid_ids,
        .first_timestamp = first_timestamp,
        .last_timestamp = last_timestamp,
        .counts = counts,
    };
}

fn sortedKeys(comptime T: type, allocator: std.mem.Allocator, map: *std.AutoHashMap(T, void)) ![]T {
    var list: std.ArrayList(T) = .empty;
    errdefer list.deinit(allocator);

    var iterator = map.keyIterator();
    while (iterator.next()) |key| {
        try list.append(allocator, key.*);
    }

    std.mem.sort(T, list.items, {}, comptime std.sort.asc(T));
    return try list.toOwnedSlice(allocator);
}

fn writeIntegerList(comptime T: type, writer: anytype, values: []const T) !void {
    for (values, 0..) |value, index| {
        if (index != 0) try writer.writeAll(", ");
        try writer.print("{}", .{value});
    }
}
