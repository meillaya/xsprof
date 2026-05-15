const std = @import("std");
const list_writer = @import("list_writer");
const report_contract = @import("report_contract");
const cli_report = @import("../cli/report.zig");
const sim_engine = @import("../sim/engine.zig");
const sim_scenario = @import("../sim/scenario.zig");
const sim_types = @import("../sim/types.zig");
const observability = @import("root.zig");

pub const schema_name = "zig-scheduler/observability-comparison";
pub const schema_version: u32 = 1;
pub const pairing_manifest_schema = "zig-scheduler/observability-comparison-pairing";
pub const pairing_manifest_version: u32 = 1;

pub const default_pairing_manifest_path = "fixtures/linux-observability/pairings/sleep-wakeup-vs-tracefs-sched-demo.json";
pub const default_pairing_id = "sleep-wakeup-vs-tracefs-sched-demo";
pub const default_simulator_scenario_path = "scenarios/basic/sleep-wakeup.zon";
pub const default_simulator_policy = "cfs_like";
pub const default_observability_manifest_path = observability.default_manifest_path;

pub const top_level_fields = [_][]const u8{
    "schema",
    "version",
    "pairing_id",
    "simulator_source",
    "observability_fixture_manifest",
    "normalized_order_summary",
    "metric_rows",
    "caveats",
};
pub const simulator_source_fields = [_][]const u8{
    "scenario_path",
    "policy",
    "report_schema",
    "report_version",
};
pub const observability_fixture_manifest_fields = [_][]const u8{
    "manifest_path",
    "family",
    "kernel_release",
    "snapshot_format_version",
    "scrub_policy_version",
};
pub const normalized_order_summary_fields = [_][]const u8{
    "simulator_families",
    "observability_families",
};
pub const metric_row_fields = [_][]const u8{
    "metric_key",
    "simulator_value",
    "observability_value",
    "delta",
    "caveat_key",
};

pub const approved_metric_set = [_][]const u8{
    "activation_count_delta",
    "selection_count_delta",
    "retirement_count_delta",
    "total_event_count_delta",
    "cpu_cardinality_delta",
    "actor_cardinality_delta",
    "time_span_delta",
};

pub const approved_caveat_keys = [_][]const u8{
    "observability_only",
    "units_not_equivalent",
    "identity_not_equivalent",
    "unmatched_events_present",
    "not_fidelity",
};

pub const rejected_claim_labels = [_][]const u8{
    "faithful",
    "validated",
    "kernel-accurate",
    "replay match",
    "performance baseline",
    "calibrated against Linux truth",
};

pub const supports_raw_event_alignment = false;
pub const supports_entity_equivalence = false;

const PairingError = error{
    InvalidPairingManifest,
    UnsupportedPairing,
    UnsupportedMetricSet,
    UnsupportedCaveatKey,
};

pub const Numeric = union(enum) {
    int: i64,
    float: f64,

    pub fn jsonStringify(self: Numeric, jw: anytype) !void {
        switch (self) {
            .int => |value| try jw.write(value),
            .float => |value| try jw.write(value),
        }
    }
};

pub const PairingManifest = struct {
    schema: []const u8,
    version: u32,
    pairing_id: []const u8,
    simulator_scenario: []const u8,
    simulator_policy: []const u8,
    observability_fixture_manifest: []const u8,
    approved_metric_set: []const []const u8,
    required_caveat_keys: []const []const u8,
};

pub const SimulatorSource = struct {
    scenario_path: []const u8,
    policy: []const u8,
    report_schema: []const u8,
    report_version: u32,
};

pub const ObservabilityFixtureManifestRef = struct {
    manifest_path: []const u8,
    family: []const u8,
    kernel_release: []const u8,
    snapshot_format_version: []const u8,
    scrub_policy_version: []const u8,
};

pub const NormalizedOrderSummary = struct {
    simulator_families: []const []const u8,
    observability_families: []const []const u8,
};

pub const MetricRow = struct {
    metric_key: []const u8,
    simulator_value: Numeric,
    observability_value: Numeric,
    delta: Numeric,
    caveat_key: []const u8,
};

pub const Caveats = struct {
    observability_only: []const u8,
    units_not_equivalent: []const u8,
    identity_not_equivalent: []const u8,
    unmatched_events_present: []const u8,
    not_fidelity: []const u8,
};

pub const ComparisonSummary = struct {
    schema: []const u8,
    version: u32,
    pairing_id: []const u8,
    simulator_source: SimulatorSource,
    observability_fixture_manifest: ObservabilityFixtureManifestRef,
    normalized_order_summary: NormalizedOrderSummary,
    metric_rows: []MetricRow,
    caveats: Caveats,

    pub fn deinit(self: *ComparisonSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.pairing_id);
        allocator.free(self.simulator_source.scenario_path);
        allocator.free(self.simulator_source.policy);
        allocator.free(self.observability_fixture_manifest.manifest_path);
        allocator.free(self.observability_fixture_manifest.family);
        allocator.free(self.observability_fixture_manifest.kernel_release);
        allocator.free(self.observability_fixture_manifest.snapshot_format_version);
        allocator.free(self.observability_fixture_manifest.scrub_policy_version);
        allocator.free(self.normalized_order_summary.simulator_families);
        allocator.free(self.normalized_order_summary.observability_families);
        allocator.free(self.metric_rows);
        self.* = undefined;
    }
};

const NormalizedFamily = enum {
    activation,
    selection,
    retirement,

    fn label(self: NormalizedFamily) []const u8 {
        return switch (self) {
            .activation => "activation",
            .selection => "selection",
            .retirement => "retirement",
        };
    }
};

const NormalizedSummary = struct {
    activation_count: usize,
    selection_count: usize,
    retirement_count: usize,
    families: []const []const u8,

    fn deinit(self: *NormalizedSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.families);
        self.* = undefined;
    }
};

pub fn loadPairingManifest(allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed(PairingManifest) {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .unlimited);
    defer allocator.free(bytes);

    var parsed = try std.json.parseFromSlice(PairingManifest, allocator, bytes, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
    });
    errdefer parsed.deinit();

    try validatePairingManifest(&parsed.value);
    return parsed;
}

pub fn validatePairingManifest(manifest: *const PairingManifest) PairingError!void {
    if (!std.mem.eql(u8, manifest.schema, pairing_manifest_schema)) return error.InvalidPairingManifest;
    if (manifest.version != pairing_manifest_version) return error.InvalidPairingManifest;
    if (!std.mem.eql(u8, manifest.pairing_id, default_pairing_id)) return error.UnsupportedPairing;
    if (!std.mem.eql(u8, manifest.simulator_scenario, default_simulator_scenario_path)) return error.UnsupportedPairing;
    if (!std.mem.eql(u8, manifest.simulator_policy, default_simulator_policy)) return error.UnsupportedPairing;
    if (!std.mem.eql(u8, manifest.observability_fixture_manifest, default_observability_manifest_path)) return error.UnsupportedPairing;
    if (!stringSliceEql(manifest.approved_metric_set, approved_metric_set[0..])) return error.UnsupportedMetricSet;
    if (!stringSliceEql(manifest.required_caveat_keys, approved_caveat_keys[0..])) return error.UnsupportedCaveatKey;
}

pub fn buildApprovedComparison(allocator: std.mem.Allocator, pairing_manifest_path: []const u8) !ComparisonSummary {
    var pairing = try loadPairingManifest(allocator, pairing_manifest_path);
    defer pairing.deinit();

    const policy = try parseApprovedPolicy(pairing.value.simulator_policy);
    var scenario = try sim_scenario.loadScenarioFile(allocator, pairing.value.simulator_scenario);
    defer scenario.deinit();

    var result = try sim_engine.simulate(allocator, &scenario, policy);
    defer result.deinit();

    var fixture = try observability.loadFixture(allocator, pairing.value.observability_fixture_manifest);
    defer fixture.deinit(allocator);

    return try buildComparisonFromInputs(allocator, &pairing.value, &result, &fixture);
}

pub fn renderComparisonJson(allocator: std.mem.Allocator, summary: *const ComparisonSummary) ![]u8 {
    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(allocator);
    var writer = list_writer.writer(&buffer, allocator);
    try writer.print("{f}", .{std.json.fmt(summary.*, .{})});
    return try buffer.toOwnedSlice(allocator);
}

pub fn renderComparisonMarkdown(allocator: std.mem.Allocator, summary: *const ComparisonSummary) ![]u8 {
    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(allocator);
    var writer = list_writer.writer(&buffer, allocator);

    try writer.print(
        "# comparison simulator-to-trace comparison\n\n" ++
            "- Contract: `{s}` v{d}\n" ++
            "- Pairing: `{s}`\n" ++
            "- Simulator source: `{s}` with `{s}` against `{s}` v{d}\n" ++
            "- Observability manifest: `{s}` (`{s}` / `{s}` / `{s}` / `{s}`)\n" ++
            "- Boundary: separate library/docs/tests-only comparison surface; not replay authority or Linux-performance evidence\n",
        .{
            summary.schema,
            summary.version,
            summary.pairing_id,
            summary.simulator_source.scenario_path,
            summary.simulator_source.policy,
            summary.simulator_source.report_schema,
            summary.simulator_source.report_version,
            summary.observability_fixture_manifest.manifest_path,
            summary.observability_fixture_manifest.family,
            summary.observability_fixture_manifest.kernel_release,
            summary.observability_fixture_manifest.snapshot_format_version,
            summary.observability_fixture_manifest.scrub_policy_version,
        },
    );

    try writer.writeAll("\n## Normalized family order\n\n- Simulator: ");
    try writeFamilyOrder(&writer, summary.normalized_order_summary.simulator_families);
    try writer.writeAll("\n- Observability: ");
    try writeFamilyOrder(&writer, summary.normalized_order_summary.observability_families);
    try writer.writeAll("\n\n## Metric rows\n\n| metric | simulator | observability | delta | caveat |\n| --- | ---: | ---: | ---: | --- |\n");

    for (summary.metric_rows) |row| {
        try writer.print("| `{s}` | ", .{row.metric_key});
        try writeNumeric(&writer, row.simulator_value);
        try writer.writeAll(" | ");
        try writeNumeric(&writer, row.observability_value);
        try writer.writeAll(" | ");
        try writeNumeric(&writer, row.delta);
        try writer.print(" | `{s}` |\n", .{row.caveat_key});
    }

    try writer.writeAll("\n## Caveats\n\n");
    try writer.print("- `observability_only`: {s}\n", .{summary.caveats.observability_only});
    try writer.print("- `units_not_equivalent`: {s}\n", .{summary.caveats.units_not_equivalent});
    try writer.print("- `identity_not_equivalent`: {s}\n", .{summary.caveats.identity_not_equivalent});
    try writer.print("- `unmatched_events_present`: {s}\n", .{summary.caveats.unmatched_events_present});
    try writer.print("- `not_fidelity`: {s}\n", .{summary.caveats.not_fidelity});

    return try buffer.toOwnedSlice(allocator);
}

pub fn assertSupportedPresentationLabel(label: []const u8) error{UnsupportedClaim}!void {
    const trimmed = std.mem.trim(u8, label, " \t\r\n");
    for (rejected_claim_labels) |blocked| {
        if (std.ascii.eqlIgnoreCase(trimmed, blocked)) return error.UnsupportedClaim;
    }
}

fn buildComparisonFromInputs(
    allocator: std.mem.Allocator,
    pairing: *const PairingManifest,
    result: *const sim_types.SimulationResult,
    fixture: *const observability.LoadedFixture,
) !ComparisonSummary {
    var simulator_normalized = try summarizeSimulatorFamilies(allocator, result);
    defer simulator_normalized.deinit(allocator);

    var observability_normalized = try summarizeObservabilityFamilies(allocator, fixture.events);
    defer observability_normalized.deinit(allocator);

    const simulator_total_event_count = try intValue(result.trace.len);
    const observability_total_event_count = try intValue(fixture.events.len);
    const simulator_cpu_cardinality = try computeSimulatorCpuCardinality(allocator, result);
    const observability_cpu_cardinality = try intValue(fixture.summary.cpu_ids.len);
    const simulator_actor_cardinality = try intValue(result.tasks.len);
    const observability_actor_cardinality = try intValue(fixture.summary.pid_ids.len);
    const simulator_time_span = computeSimulatorTimeSpan(result);
    const observability_time_span = fixture.summary.last_timestamp - fixture.summary.first_timestamp;

    const metric_rows = try allocator.alloc(MetricRow, approved_metric_set.len);
    errdefer allocator.free(metric_rows);

    metric_rows[0] = makeIntMetric(
        approved_metric_set[0],
        try intValue(simulator_normalized.activation_count),
        try intValue(observability_normalized.activation_count),
        "not_fidelity",
    );
    metric_rows[1] = makeIntMetric(
        approved_metric_set[1],
        try intValue(simulator_normalized.selection_count),
        try intValue(observability_normalized.selection_count),
        "not_fidelity",
    );
    metric_rows[2] = makeIntMetric(
        approved_metric_set[2],
        try intValue(simulator_normalized.retirement_count),
        try intValue(observability_normalized.retirement_count),
        "not_fidelity",
    );
    metric_rows[3] = makeIntMetric(
        approved_metric_set[3],
        simulator_total_event_count,
        observability_total_event_count,
        "unmatched_events_present",
    );
    metric_rows[4] = makeIntMetric(
        approved_metric_set[4],
        simulator_cpu_cardinality,
        observability_cpu_cardinality,
        "observability_only",
    );
    metric_rows[5] = makeIntMetric(
        approved_metric_set[5],
        simulator_actor_cardinality,
        observability_actor_cardinality,
        "identity_not_equivalent",
    );
    metric_rows[6] = makeFloatMetric(
        approved_metric_set[6],
        simulator_time_span,
        observability_time_span,
        "units_not_equivalent",
    );

    return .{
        .schema = schema_name,
        .version = schema_version,
        .pairing_id = try allocator.dupe(u8, pairing.pairing_id),
        .simulator_source = .{
            .scenario_path = try allocator.dupe(u8, pairing.simulator_scenario),
            .policy = try allocator.dupe(u8, pairing.simulator_policy),
            .report_schema = report_contract.schema_name,
            .report_version = report_contract.schema_version,
        },
        .observability_fixture_manifest = .{
            .manifest_path = try allocator.dupe(u8, pairing.observability_fixture_manifest),
            .family = try allocator.dupe(u8, fixture.manifest.value.tuple.family),
            .kernel_release = try allocator.dupe(u8, fixture.manifest.value.tuple.kernel_release),
            .snapshot_format_version = try allocator.dupe(u8, fixture.manifest.value.tuple.snapshot_format_version),
            .scrub_policy_version = try allocator.dupe(u8, fixture.manifest.value.tuple.scrub_policy_version),
        },
        .normalized_order_summary = .{
            .simulator_families = try cloneStringSlice(allocator, simulator_normalized.families),
            .observability_families = try cloneStringSlice(allocator, observability_normalized.families),
        },
        .metric_rows = metric_rows,
        .caveats = .{
            .observability_only = "Comparison uses a committed offline observability snapshot and remains a bounded teaching aid.",
            .units_not_equivalent = "Simulator ticks and trace-clock seconds are juxtaposed numerically only; the units are not equivalent.",
            .identity_not_equivalent = "Simulator task ids and observed Linux PIDs are different identity domains and are not matched.",
            .unmatched_events_present = "Unmapped approved-trace events stay in raw totals while normalized family summaries exclude them.",
            .not_fidelity = "These rows do not score replay fidelity and must not be treated as replay authority.",
        },
    };
}

fn parseApprovedPolicy(policy: []const u8) !sim_types.PolicyKind {
    const parsed = std.meta.stringToEnum(sim_types.PolicyKind, policy) orelse return error.UnsupportedPairing;
    if (parsed != .cfs_like) return error.UnsupportedPairing;
    return parsed;
}

fn makeIntMetric(metric_key: []const u8, simulator_value: i64, observability_value: i64, caveat_key: []const u8) MetricRow {
    return .{
        .metric_key = metric_key,
        .simulator_value = .{ .int = simulator_value },
        .observability_value = .{ .int = observability_value },
        .delta = .{ .int = simulator_value - observability_value },
        .caveat_key = caveat_key,
    };
}

fn makeFloatMetric(metric_key: []const u8, simulator_value: f64, observability_value: f64, caveat_key: []const u8) MetricRow {
    return .{
        .metric_key = metric_key,
        .simulator_value = .{ .float = simulator_value },
        .observability_value = .{ .float = observability_value },
        .delta = .{ .float = simulator_value - observability_value },
        .caveat_key = caveat_key,
    };
}

fn summarizeSimulatorFamilies(allocator: std.mem.Allocator, result: *const sim_types.SimulationResult) !NormalizedSummary {
    var order: std.ArrayList([]const u8) = .empty;
    errdefer order.deinit(allocator);
    var seen = [_]bool{ false, false, false };
    var activation_count: usize = 0;
    var selection_count: usize = 0;
    var retirement_count: usize = 0;

    for (result.trace) |entry| {
        const family = simulatorFamily(entry.kind) orelse continue;
        switch (family) {
            .activation => activation_count += 1,
            .selection => selection_count += 1,
            .retirement => retirement_count += 1,
        }
        try appendFamilyOrder(allocator, &order, &seen, family);
    }

    return .{
        .activation_count = activation_count,
        .selection_count = selection_count,
        .retirement_count = retirement_count,
        .families = try order.toOwnedSlice(allocator),
    };
}

fn summarizeObservabilityFamilies(allocator: std.mem.Allocator, events: []const observability.Event) !NormalizedSummary {
    var order: std.ArrayList([]const u8) = .empty;
    errdefer order.deinit(allocator);
    var seen = [_]bool{ false, false, false };
    var activation_count: usize = 0;
    var selection_count: usize = 0;
    var retirement_count: usize = 0;

    for (events) |event| {
        const family = observabilityFamily(event.kind) orelse continue;
        switch (family) {
            .activation => activation_count += 1,
            .selection => selection_count += 1,
            .retirement => retirement_count += 1,
        }
        try appendFamilyOrder(allocator, &order, &seen, family);
    }

    return .{
        .activation_count = activation_count,
        .selection_count = selection_count,
        .retirement_count = retirement_count,
        .families = try order.toOwnedSlice(allocator),
    };
}

fn simulatorFamily(kind: sim_types.TraceEventKind) ?NormalizedFamily {
    return switch (kind) {
        .arrival, .wakeup => .activation,
        .dispatch => .selection,
        .complete => .retirement,
        else => null,
    };
}

fn observabilityFamily(kind: observability.EventKind) ?NormalizedFamily {
    return switch (kind) {
        .sched_wakeup, .sched_wakeup_new => .activation,
        .sched_switch => .selection,
        .sched_process_exit => .retirement,
        else => null,
    };
}

fn appendFamilyOrder(
    allocator: std.mem.Allocator,
    order: *std.ArrayList([]const u8),
    seen: *[3]bool,
    family: NormalizedFamily,
) !void {
    const index = @intFromEnum(family);
    if (seen[index]) return;
    seen[index] = true;
    try order.append(allocator, family.label());
}

fn computeSimulatorCpuCardinality(allocator: std.mem.Allocator, result: *const sim_types.SimulationResult) !i64 {
    var seen = std.AutoHashMap(sim_types.CoreId, void).init(allocator);
    defer seen.deinit();

    for (result.trace) |entry| {
        if (entry.core_id) |core_id| {
            try seen.put(core_id, {});
        }
    }
    return try intValue(seen.count());
}

fn computeSimulatorTimeSpan(result: *const sim_types.SimulationResult) f64 {
    if (result.trace.len == 0) return 0;
    const first_tick = result.trace[0].tick;
    const last_tick = result.trace[result.trace.len - 1].tick;
    return @as(f64, @floatFromInt(last_tick - first_tick));
}

fn cloneStringSlice(allocator: std.mem.Allocator, input: []const []const u8) ![]const []const u8 {
    const output = try allocator.alloc([]const u8, input.len);
    for (input, output) |value, *slot| slot.* = value;
    return output;
}

fn intValue(value: usize) !i64 {
    return std.math.cast(i64, value) orelse unreachable;
}

fn stringSliceEql(lhs: []const []const u8, rhs: []const []const u8) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |lhs_item, rhs_item| {
        if (!std.mem.eql(u8, lhs_item, rhs_item)) return false;
    }
    return true;
}

fn writeFamilyOrder(writer: anytype, families: []const []const u8) !void {
    for (families, 0..) |family, index| {
        if (index != 0) try writer.writeAll(" -> ");
        try writer.print("`{s}`", .{family});
    }
}

fn writeNumeric(writer: anytype, value: Numeric) !void {
    switch (value) {
        .int => |int_value| try writer.print("{d}", .{int_value}),
        .float => |float_value| try writer.print("{d:.6}", .{float_value}),
    }
}

comptime {
    _ = cli_report;
}
