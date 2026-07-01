// allow: SIZE_OK — this daemon runtime-sample stream parser is intentionally
// kept in one file for the protected-live VM evidence milestone. It owns one
// tightly coupled JSON boundary: RawSample parsing, privacy filtering, and
// daemon-event conversion must evolve atomically with the golden stdio gates.
// Splitting during this second-fix pass would widen risk beyond the rejected
// maintenance concern. Follow-up split plan: extract fact/privacy/ABI helpers
// into src/control/stream_validation.zig, then move event rendering into
// src/control/stream_events.zig, keeping appendRuntimeFile as the only public
// entrypoint and preserving daemon-stdio/socket/golden tests after each step.
const std = @import("std");
const daemon = @import("daemon.zig");
const protocol = @import("protocol.zig");

pub const StreamError = error{ InvalidRuntimeSample, PrivacyUnsafe, OutOfMemory } || std.Io.Writer.Error;

pub const max_stream_events: usize = 64;
const sample_schema = "zig-scheduler/runtime-sample/v1";
const sha256_hex_len: usize = 64;
const sha256_zero = "0" ** sha256_hex_len;

const Fact = struct {
    status: []const u8,
    value: []const u8,
};

const PolicyCounters = struct {
    nr_rejected: u64,
    dispatch_failed: u64,
    fallback: u64,
    fatal: u64,
};

const SampleLoss = struct {
    lost_samples: u64,
    backpressure_dropped: u64,
    ring_buffer_overruns: ?u64 = null,
    reader_lag_events: ?u64 = null,
};

const DsqDepth = struct { global: u64, local: u64, shared: u64 };
const QueueLatency = struct { p50_us: u64, p95_us: u64, p99_us: u64, max_us: u64 };
const Fairness = struct { state: []const u8, starved_tasks: u64, max_wait_us: u64 };
const CounterMap = std.json.ArrayHashMap(u64);
const TaskCounts = struct { by_cgroup_digest: CounterMap, by_class: CounterMap };
const SchedulerCounters = struct { context_switches: u64, wakeups: u64, migrations: u64 };
const SchedExtObservation = struct { dump: Fact, tracepoints: CounterMap };
const BenchmarkHistogram = struct { record_path: []const u8, record_sha256: []const u8, histogram_id: []const u8, record_only: bool };

const abi_v3_policy_version = "sched_ext_cgroup_abi_v3";
const abi_v3_label = "zigsched-bpf-abi-v3";

const CgroupSemantics = struct {
    @"cpu.weight": []const u8,
    @"cgroup.lifecycle": []const u8,
    @"cgroup.move": []const u8,
    @"cpuset.cpus": []const u8,
    @"cpuset.cpus.effective": []const u8,
    @"cpu.pressure": []const u8,
    @"cpu.max": []const u8,
    uclamp: []const u8,
    cgroup_set_idle: []const u8,
};

const PolicyAbi = struct {
    policy_name: []const u8,
    policy_version: []const u8,
    struct_ops: []const u8,
    object_sha256: []const u8,
    btf_required: bool,
    abi_version: ?u64 = null,
    abi_label: ?[]const u8 = null,
    cgroup_semantics: ?CgroupSemantics = null,
    vm_only: ?bool = null,
    host_mutation: ?bool = null,
    production_claim: ?bool = null,
    release_eligible: ?bool = null,
};

const RawSample = struct {
    schema: []const u8,
    sequence: usize,
    git_sha: ?[]const u8 = null,
    sample_source_event: ?[]const u8 = null,
    observation_source: ?[]const u8 = null,
    sched_ext_phase: ?[]const u8 = null,
    state: Fact,
    ops: Fact,
    enable_seq: Fact,
    events: Fact,
    events_hash: []const u8,
    nr_rejected: Fact,
    debug_dump: Fact,
    root_ops: ?Fact = null,
    scheduler_events: ?Fact = null,
    task_ext_enabled: ?Fact = null,
    teardown_state: ?Fact = null,
    rollback_state: ?Fact = null,
    cgroup_semantic_labels: ?CgroupSemantics = null,
    policy_counters: ?PolicyCounters = null,
    sample_loss: ?SampleLoss = null,
    dsq_depth: ?DsqDepth = null,
    queue_latency: ?QueueLatency = null,
    fairness: ?Fairness = null,
    task_counts: ?TaskCounts = null,
    scheduler_counters: ?SchedulerCounters = null,
    sched_ext_observation: ?SchedExtObservation = null,
    benchmark_histograms: ?[]const BenchmarkHistogram = null,
    policy_abi: PolicyAbi,
    cgroup_membership_digest: []const u8,
    cgroup_membership_status: ?Fact = null,
    workload: ?Fact = null,
    workload_alive: bool,
    private_command_lines_sampled: bool,
    command_line: ?[]const u8 = null,
    cmdline: ?[]const u8 = null,
    argv: ?[]const []const u8 = null,
    env: ?[]const u8 = null,
    environment: ?[]const u8 = null,
    secret: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
};

pub fn appendRuntimeFile(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    file_bytes: []const u8,
    next_seq: *usize,
    replay_from: usize,
    current_git_sha: []const u8,
) !void {
    var emitted: usize = 0;
    var lines = std.mem.splitScalar(u8, file_bytes, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (emitted >= max_stream_events) {
            try appendDropped(allocator, output, next_seq.*);
            next_seq.* += 1;
            return;
        }
        try appendRuntimeLine(allocator, output, trimmed, next_seq, replay_from, current_git_sha);
        emitted += 1;
    }
}

pub fn appendRuntimeLine(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    line: []const u8,
    next_seq: *usize,
    replay_from: usize,
    current_git_sha: []const u8,
) !void {
    const parsed = parseSample(allocator, line) catch |err| {
        const reason = if (err == error.PrivacyUnsafe) "private_fields_rejected" else "malformed_runtime_sample";
        try appendIncident(allocator, output, next_seq.*, reason);
        next_seq.* += 1;
        return;
    };
    defer parsed.deinit();
    if (parsed.value.sequence < replay_from) return;
    if (parsed.value.git_sha) |seen| {
        if (!std.mem.eql(u8, seen, current_git_sha)) {
            try appendIncident(allocator, output, next_seq.*, "stale_git_sha");
            next_seq.* += 1;
            return;
        }
    }
    try appendSample(allocator, output, next_seq.*, parsed.value);
    next_seq.* += 1;
    if (sampleHasRejectedDispatches(parsed.value)) {
        try appendIncident(allocator, output, next_seq.*, "runtime_nr_rejected_nonzero");
        next_seq.* += 1;
    }
    if (sampleHasLoss(parsed.value)) {
        try appendIncident(allocator, output, next_seq.*, "runtime_sample_loss");
        next_seq.* += 1;
    }
    if (!parsed.value.workload_alive) {
        try appendIncident(allocator, output, next_seq.*, "runtime_workload_dead");
        next_seq.* += 1;
    }
}

fn parseSample(allocator: std.mem.Allocator, line: []const u8) StreamError!std.json.Parsed(RawSample) {
    const parsed = std.json.parseFromSlice(RawSample, allocator, line, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
    }) catch return error.InvalidRuntimeSample;
    errdefer parsed.deinit();
    const raw = parsed.value;
    if (!std.mem.eql(u8, raw.schema, sample_schema)) return error.InvalidRuntimeSample;
    if (raw.private_command_lines_sampled) return error.PrivacyUnsafe;
    if (raw.command_line != null or raw.cmdline != null or raw.argv != null) return error.PrivacyUnsafe;
    if (raw.env != null or raw.environment != null or raw.secret != null or raw.api_key != null) return error.PrivacyUnsafe;
    try requireSafeFact(raw.state);
    try requireSafeFact(raw.ops);
    try requireSafeFact(raw.enable_seq);
    try requireSafeFact(raw.events);
    try requireSafeFact(raw.nr_rejected);
    try requireSafeFact(raw.debug_dump);
    if (!std.mem.eql(u8, raw.debug_dump.status, "missing") and !std.mem.eql(u8, raw.debug_dump.status, "unknown")) {
        if (!isDigestSummary(raw.debug_dump.value)) return error.InvalidRuntimeSample;
    }
    if (raw.sched_ext_phase) |phase| try requireSchedExtPhase(phase);
    if (raw.root_ops) |fact| try requireSafeFact(fact);
    if (raw.scheduler_events) |fact| try requireSafeFact(fact);
    if (raw.task_ext_enabled) |fact| try requireTaskExtFact(fact);
    if (raw.teardown_state) |fact| try requireSafeFact(fact);
    if (raw.rollback_state) |fact| try requireSafeFact(fact);
    if (raw.cgroup_semantic_labels) |labels| try requireCgroupSemantics(labels);
    if (raw.cgroup_membership_status) |fact| try requireSafeFact(fact);
    if (raw.workload) |fact| try requireSafeFact(fact);
    try requireSchedulerTelemetry(raw);
    try requireSafePolicyAbi(raw.policy_abi);
    try requireSha256Digest(raw.cgroup_membership_digest);
    return parsed;
}

fn requireSchedulerTelemetry(raw: RawSample) StreamError!void {
    if (raw.fairness) |fairness| {
        if (!std.mem.eql(u8, fairness.state, "ok") and !std.mem.eql(u8, fairness.state, "watch") and !std.mem.eql(u8, fairness.state, "starved") and !std.mem.eql(u8, fairness.state, "unknown")) return error.InvalidRuntimeSample;
    }
    if (raw.task_counts) |counts| {
        try requireSafeCounterMap(counts.by_cgroup_digest);
        try requireSafeCounterMap(counts.by_class);
    }
    if (raw.sched_ext_observation) |observation| {
        try requireSafeFact(observation.dump);
        if (std.mem.eql(u8, observation.dump.status, "present") and !isDigestSummary(observation.dump.value)) return error.InvalidRuntimeSample;
        try requireSafeCounterMap(observation.tracepoints);
    }
    if (raw.benchmark_histograms) |refs| {
        for (refs) |ref| {
            try requireSafeRelativePath(ref.record_path);
            try requireSha256Digest(ref.record_sha256);
            try requireSafeText(ref.histogram_id);
            if (!ref.record_only) return error.InvalidRuntimeSample;
        }
    }
}

fn isDigestSummary(value: []const u8) bool {
    const digest_prefix = "sha256:";
    const bytes_prefix = ";bytes:";
    const digest_start = digest_prefix.len;
    const digest_end = digest_start + sha256_hex_len;
    if (value.len <= digest_end + bytes_prefix.len) return false;
    if (!std.mem.startsWith(u8, value, digest_prefix)) return false;
    if (!std.mem.eql(u8, value[digest_end .. digest_end + bytes_prefix.len], bytes_prefix)) return false;
    for (value[digest_start..digest_end]) |byte| {
        if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) return false;
    }
    for (value[digest_end + bytes_prefix.len ..]) |byte| {
        if (!std.ascii.isDigit(byte)) return false;
    }
    return true;
}

fn requireSafeCounterMap(map: CounterMap) StreamError!void {
    if (map.map.count() == 0) return error.InvalidRuntimeSample;
    var it = map.map.iterator();
    while (it.next()) |entry| {
        if (entry.key_ptr.*.len == 0 or std.mem.startsWith(u8, entry.key_ptr.*, "/") or std.mem.indexOf(u8, entry.key_ptr.*, "..") != null) return error.InvalidRuntimeSample;
        try requireSafeText(entry.key_ptr.*);
    }
}

fn requireSafeRelativePath(path: []const u8) StreamError!void {
    if (path.len == 0 or std.mem.startsWith(u8, path, "/") or std.mem.indexOf(u8, path, "..") != null) return error.InvalidRuntimeSample;
    try requireSafeText(path);
}

fn requireSafePolicyAbi(abi: PolicyAbi) StreamError!void {
    try requireSafeText(abi.policy_name);
    try requireSafeText(abi.policy_version);
    try requireSafeText(abi.struct_ops);
    try requireSafeText(abi.object_sha256);
    if (abi.policy_name.len == 0 or abi.policy_version.len == 0 or abi.struct_ops.len == 0 or abi.object_sha256.len == 0) return error.InvalidRuntimeSample;

    const has_v3_field = abi.abi_version != null or
        abi.abi_label != null or
        abi.cgroup_semantics != null or
        abi.vm_only != null or
        abi.host_mutation != null or
        abi.production_claim != null or
        abi.release_eligible != null;
    if (!has_v3_field) return;
    try requireAbiV3PolicyAbi(abi);
}

fn requireAbiV3PolicyAbi(abi: PolicyAbi) StreamError!void {
    if (!std.mem.eql(u8, abi.policy_version, abi_v3_policy_version)) return error.InvalidRuntimeSample;
    if ((abi.abi_version orelse return error.InvalidRuntimeSample) != 3) return error.InvalidRuntimeSample;
    const label = abi.abi_label orelse return error.InvalidRuntimeSample;
    try requireSafeText(label);
    if (!std.mem.eql(u8, label, abi_v3_label)) return error.InvalidRuntimeSample;
    if ((abi.vm_only orelse return error.InvalidRuntimeSample) != true) return error.InvalidRuntimeSample;
    if ((abi.host_mutation orelse return error.InvalidRuntimeSample) != false) return error.InvalidRuntimeSample;
    if ((abi.production_claim orelse return error.InvalidRuntimeSample) != false) return error.InvalidRuntimeSample;
    if ((abi.release_eligible orelse return error.InvalidRuntimeSample) != false) return error.InvalidRuntimeSample;
    try requireCgroupSemantics(abi.cgroup_semantics orelse return error.InvalidRuntimeSample);
}

fn requireCgroupSemantics(semantics: CgroupSemantics) StreamError!void {
    if (!std.mem.eql(u8, semantics.@"cpu.weight", "callback-observed")) return error.InvalidRuntimeSample;
    if (!std.mem.eql(u8, semantics.@"cgroup.lifecycle", "observed")) return error.InvalidRuntimeSample;
    if (!std.mem.eql(u8, semantics.@"cgroup.move", "observed")) return error.InvalidRuntimeSample;
    if (!std.mem.eql(u8, semantics.@"cpuset.cpus", "observed-only")) return error.InvalidRuntimeSample;
    if (!std.mem.eql(u8, semantics.@"cpuset.cpus.effective", "observed-only")) return error.InvalidRuntimeSample;
    if (!std.mem.eql(u8, semantics.@"cpu.pressure", "observed-only")) return error.InvalidRuntimeSample;
    if (!std.mem.eql(u8, semantics.@"cpu.max", "deferred")) return error.InvalidRuntimeSample;
    if (!std.mem.eql(u8, semantics.uclamp, "deferred")) return error.InvalidRuntimeSample;
    if (!std.mem.eql(u8, semantics.cgroup_set_idle, "refused")) return error.InvalidRuntimeSample;
}

fn requireSha256Digest(value: []const u8) StreamError!void {
    if (value.len != sha256_hex_len or std.mem.eql(u8, value, sha256_zero)) return error.InvalidRuntimeSample;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) return error.InvalidRuntimeSample;
    }
}

fn requireTaskExtFact(fact: Fact) StreamError!void {
    try requireSafeFact(fact);
    if (std.mem.eql(u8, fact.status, "present")) {
        if (!std.mem.eql(u8, fact.value, "true") and !std.mem.eql(u8, fact.value, "false")) return error.InvalidRuntimeSample;
        return;
    }
    if (fact.value.len != 0 and !std.mem.eql(u8, fact.value, "unknown") and !std.mem.eql(u8, fact.value, "unavailable")) return error.InvalidRuntimeSample;
}

fn requireSafeFact(fact: Fact) StreamError!void {
    if (!validFactStatus(fact.status)) return error.InvalidRuntimeSample;
    if (std.mem.eql(u8, fact.status, "present") and fact.value.len == 0) return error.InvalidRuntimeSample;
    try requireSafeText(fact.value);
}

fn requireSafeText(value: []const u8) StreamError!void {
    if (hasPrivateNeedle(value)) return error.PrivacyUnsafe;
}

fn requireSchedExtPhase(phase: []const u8) StreamError!void {
    try requireSafeText(phase);
    if (!std.mem.eql(u8, phase, "before_attach") and
        !std.mem.eql(u8, phase, "during_attach") and
        !std.mem.eql(u8, phase, "after_rollback"))
    {
        return error.InvalidRuntimeSample;
    }
}

fn validFactStatus(status: []const u8) bool {
    return std.mem.eql(u8, status, "present") or
        std.mem.eql(u8, status, "missing") or
        std.mem.eql(u8, status, "unreadable") or
        std.mem.eql(u8, status, "unknown");
}

fn hasPrivateNeedle(value: []const u8) bool {
    const needles = [_][]const u8{ "cmdline", "command_line", "argv", "environment", "\"env\"", "secret", "api_key", "--token", "password=", "/proc/", "/sys/" };
    for (needles) |needle| {
        if (std.ascii.indexOfIgnoreCase(value, needle) != null) return true;
    }
    return false;
}

fn sampleHasRejectedDispatches(sample: RawSample) bool {
    if (!std.mem.eql(u8, sample.nr_rejected.status, "present")) return false;
    const value = std.mem.trim(u8, sample.nr_rejected.value, " \t\r\n");
    if (value.len == 0) return false;
    const parsed = std.fmt.parseUnsigned(u64, value, 10) catch return !std.mem.eql(u8, value, "0");
    return parsed != 0;
}

fn sampleHasLoss(sample: RawSample) bool {
    if (sample.sample_loss) |loss| {
        return loss.lost_samples != 0 or loss.backpressure_dropped != 0 or
            (loss.ring_buffer_overruns orelse 0) != 0 or (loss.reader_lag_events orelse 0) != 0;
    }
    return false;
}

fn appendSample(allocator: std.mem.Allocator, output: *std.ArrayList(u8), seq: usize, sample: RawSample) !void {
    var event: std.ArrayList(u8) = .empty;
    defer event.deinit(allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(allocator, &event);
    try writer.writer.print(
        "{{\"schema\":\"{s}\",\"seq\":{d},\"event\":\"runtime_sample\",\"state\":\"observing\",\"status\":\"accepted\",\"sample_sequence\":{d},\"scheduler_state\":",
        .{ protocol.event_schema, seq, sample.sequence },
    );
    try writeJsonString(&writer.writer, sample.state.value);
    try writer.writer.writeAll(",\"ops\":");
    try writeJsonString(&writer.writer, sample.ops.value);
    try writer.writer.writeAll(",\"enable_seq\":");
    try writeJsonString(&writer.writer, sample.enable_seq.value);
    try writer.writer.writeAll(",\"events_hash\":");
    try writeJsonString(&writer.writer, sample.events_hash);
    try writer.writer.writeAll(",\"nr_rejected\":");
    try writeJsonString(&writer.writer, sample.nr_rejected.value);
    try writer.writer.writeAll(",\"cgroup_membership_digest\":");
    try writeJsonString(&writer.writer, sample.cgroup_membership_digest);
    try appendRichTelemetry(&writer.writer, sample);
    try writer.writer.print(",\"workload_alive\":{},\"host_mutation\":false}}\n", .{sample.workload_alive});
    event = writer.toArrayList();
    try daemon.ensureCanWriteEvent(output.items.len, event.items);
    try output.appendSlice(allocator, event.items);
}

fn appendRichTelemetry(writer: anytype, sample: RawSample) !void {
    if (sample.sample_loss) |loss| {
        try writer.print(",\"sample_loss\":\"lost={d} backpressure={d}", .{ loss.lost_samples, loss.backpressure_dropped });
        if (loss.ring_buffer_overruns) |value| try writer.print(" ring_buffer_overruns={d}", .{value});
        if (loss.reader_lag_events) |value| try writer.print(" reader_lag_events={d}", .{value});
        try writer.writeByte('"');
    }
    if (sample.dsq_depth) |depth| try writer.print(",\"dsq_depth\":\"global={d} local={d} shared={d}\"", .{ depth.global, depth.local, depth.shared });
    if (sample.queue_latency) |latency| try writer.print(",\"queue_latency\":\"p50_us={d} p95_us={d} p99_us={d} max_us={d}\"", .{ latency.p50_us, latency.p95_us, latency.p99_us, latency.max_us });
    if (sample.fairness) |fairness| {
        try writer.writeAll(",\"fairness\":\"state=");
        try writeJsonStringContent(writer, fairness.state);
        try writer.print(" starved_tasks={d} max_wait_us={d}\"", .{ fairness.starved_tasks, fairness.max_wait_us });
    }
    if (sample.task_counts) |counts| try writer.print(",\"task_counts\":\"cgroup_digests={d} classes={d}\"", .{ counts.by_cgroup_digest.map.count(), counts.by_class.map.count() });
    if (sample.scheduler_counters) |counters| try writer.print(",\"scheduler_counters\":\"context_switches={d} wakeups={d} migrations={d}\"", .{ counters.context_switches, counters.wakeups, counters.migrations });
    if (sample.sched_ext_observation) |observation| {
        try writer.writeAll(",\"sched_ext_observation\":\"dump=");
        try writeJsonStringContent(writer, observation.dump.value);
        try writer.print(" tracepoints={d}\"", .{observation.tracepoints.map.count()});
    }
    if (sample.benchmark_histograms) |refs| try writer.print(",\"benchmark_histograms\":\"refs={d}\"", .{refs.len});
}

fn appendIncident(allocator: std.mem.Allocator, output: *std.ArrayList(u8), seq: usize, reason: []const u8) !void {
    var event: std.ArrayList(u8) = .empty;
    defer event.deinit(allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(allocator, &event);
    try writer.writer.print(
        "{{\"schema\":\"{s}\",\"seq\":{d},\"event\":\"incident\",\"state\":\"unsafe_to_assume\",\"status\":\"unsafe_to_assume\",\"reason\":\"{s}\",\"host_mutation\":false}}\n",
        .{ protocol.event_schema, seq, reason },
    );
    event = writer.toArrayList();
    try daemon.ensureCanWriteEvent(output.items.len, event.items);
    try output.appendSlice(allocator, event.items);
}

fn appendDropped(allocator: std.mem.Allocator, output: *std.ArrayList(u8), seq: usize) !void {
    try appendIncident(allocator, output, seq, "stream_backpressure_dropped");
}

fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    try writeJsonStringContent(writer, value);
    try writer.writeByte('"');
}

fn writeJsonStringContent(writer: anytype, value: []const u8) !void {
    for (value) |byte| switch (byte) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => if (byte < 0x20) try writer.print("\\u{x:0>4}", .{byte}) else try writer.writeByte(byte),
    };
}

test "runtime stream behavior tests are linked" {
    std.testing.refAllDecls(@import("stream_tests.zig"));
}

test "runtime stream validates sched_ext_phase against the public enum" {
    const valid_samples = [_][]const u8{
        "{\"schema\":\"zig-scheduler/runtime-sample/v1\",\"sequence\":21,\"sched_ext_phase\":\"before_attach\",\"state\":{\"status\":\"present\",\"value\":\"disabled\"},\"ops\":{\"status\":\"present\",\"value\":\"none\"},\"enable_seq\":{\"status\":\"present\",\"value\":\"0\"},\"events\":{\"status\":\"present\",\"value\":\"nr_rejected: 0\"},\"events_hash\":\"phase21\",\"nr_rejected\":{\"status\":\"present\",\"value\":\"0\"},\"debug_dump\":{\"status\":\"missing\",\"value\":\"\"},\"policy_abi\":{\"policy_name\":\"zigsched_minimal\",\"policy_version\":\"sched_ext_minimal_v1\",\"struct_ops\":\"zigsched_minimal_ops\",\"object_sha256\":\"unavailable\",\"btf_required\":true},\"cgroup_membership_digest\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"workload_alive\":true,\"private_command_lines_sampled\":false}",
        "{\"schema\":\"zig-scheduler/runtime-sample/v1\",\"sequence\":22,\"sched_ext_phase\":\"during_attach\",\"state\":{\"status\":\"present\",\"value\":\"enabled\"},\"ops\":{\"status\":\"present\",\"value\":\"zigsched_minimal\"},\"enable_seq\":{\"status\":\"present\",\"value\":\"42\"},\"events\":{\"status\":\"present\",\"value\":\"nr_rejected: 0\"},\"events_hash\":\"phase22\",\"nr_rejected\":{\"status\":\"present\",\"value\":\"0\"},\"debug_dump\":{\"status\":\"missing\",\"value\":\"\"},\"policy_abi\":{\"policy_name\":\"zigsched_minimal\",\"policy_version\":\"sched_ext_minimal_v1\",\"struct_ops\":\"zigsched_minimal_ops\",\"object_sha256\":\"unavailable\",\"btf_required\":true},\"cgroup_membership_digest\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"workload_alive\":true,\"private_command_lines_sampled\":false}",
        "{\"schema\":\"zig-scheduler/runtime-sample/v1\",\"sequence\":23,\"sched_ext_phase\":\"after_rollback\",\"state\":{\"status\":\"present\",\"value\":\"disabled\"},\"ops\":{\"status\":\"present\",\"value\":\"none\"},\"enable_seq\":{\"status\":\"present\",\"value\":\"43\"},\"events\":{\"status\":\"present\",\"value\":\"nr_rejected: 0\"},\"events_hash\":\"phase23\",\"nr_rejected\":{\"status\":\"present\",\"value\":\"0\"},\"debug_dump\":{\"status\":\"missing\",\"value\":\"\"},\"policy_abi\":{\"policy_name\":\"zigsched_minimal\",\"policy_version\":\"sched_ext_minimal_v1\",\"struct_ops\":\"zigsched_minimal_ops\",\"object_sha256\":\"unavailable\",\"btf_required\":true},\"cgroup_membership_digest\":\"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\",\"workload_alive\":true,\"private_command_lines_sampled\":false}",
    };
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    var seq: usize = 1;
    for (valid_samples) |sample| {
        try appendRuntimeLine(std.testing.allocator, &output, sample, &seq, 0, "sha");
    }
    try std.testing.expectEqual(@as(usize, 4), seq);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "malformed_runtime_sample") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"sample_sequence\":21") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"sample_sequence\":22") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"sample_sequence\":23") != null);

    try appendRuntimeLine(std.testing.allocator, &output, "{\"schema\":\"zig-scheduler/runtime-sample/v1\",\"sequence\":24,\"sched_ext_phase\":\"bogus_phase\",\"state\":{\"status\":\"present\",\"value\":\"enabled\"},\"ops\":{\"status\":\"present\",\"value\":\"zigsched_minimal\"},\"enable_seq\":{\"status\":\"present\",\"value\":\"42\"},\"events\":{\"status\":\"present\",\"value\":\"nr_rejected: 0\"},\"events_hash\":\"phase24\",\"nr_rejected\":{\"status\":\"present\",\"value\":\"0\"},\"debug_dump\":{\"status\":\"missing\",\"value\":\"\"},\"policy_abi\":{\"policy_name\":\"zigsched_minimal\",\"policy_version\":\"sched_ext_minimal_v1\",\"struct_ops\":\"zigsched_minimal_ops\",\"object_sha256\":\"unavailable\",\"btf_required\":true},\"cgroup_membership_digest\":\"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\",\"workload_alive\":true,\"private_command_lines_sampled\":false}", &seq, 0, "sha");
    try std.testing.expectEqual(@as(usize, 5), seq);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"sample_sequence\":24") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "malformed_runtime_sample") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "host_mutation\":false") != null);
}
