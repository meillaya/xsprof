//! Bounded lab scenarios: parse JSON, apply the same intents as the GUI,
//! render per-step snapshots, and evaluate assertions headlessly.

const std = @import("std");
const json = @import("../../core/json.zig");
const session_mod = @import("../../stream/session.zig");
const chrome_trace = @import("../../viz/chrome_trace.zig");
const frame_mod = @import("../../ui/frame.zig");
const layout = @import("../../ui/layout.zig");
const lab_state = @import("state.zig");
const action = @import("action.zig");
const lab_view = @import("../lab_view.zig");
const app = @import("../app.zig");

const max_steps = 4096;
const max_file_bytes = 1024 * 1024;
const max_time_ms = 600_000;

pub const SourceKind = enum { fixture, journal };
pub const StepAction = enum { screen, filter, select, transport, snapshot, export_file };
pub const Metric = enum { events, switches, wakeups, migrations, faults, lost, cpu_count, screen, indicator };
pub const Op = enum { eq, ne, gte, lte };

pub const Source = struct {
    kind: SourceKind,
    path: []const u8,
};

pub const Step = struct {
    at_ms: u32,
    action: StepAction,
    value: []const u8,
};

pub const Assertion = struct {
    metric: Metric,
    op: Op,
    value: []const u8,
};

pub const Scenario = struct {
    id: []const u8,
    source: Source,
    steps: []const Step,
    assertions: []const Assertion,
};

pub const Options = struct {
    width: u32 = 1280,
    height: u32 = 720,
    out_dir: ?[]const u8 = null,
};

pub const AssertionResult = struct {
    metric: []const u8,
    op: []const u8,
    expected: []const u8,
    actual: []const u8,
    passed: bool,
};

pub const RunResult = struct {
    id: []const u8,
    passed: bool,
    steps: usize,
    events: u64,
    lost: u64,
    assertions: []const AssertionResult,
    snapshots: []const []const u8,
};

const WireStep = struct {
    at_ms: u32 = 0,
    action: []const u8,
    value: []const u8 = "",
};

const WireAssertion = struct {
    metric: []const u8,
    op: []const u8,
    value: []const u8,
};

const Wire = struct {
    schema: []const u8,
    id: []const u8,
    source: struct {
        kind: []const u8,
        path: []const u8,
    },
    steps: []WireStep,
    assertions: []WireAssertion = &.{},
};

fn safePath(path: []const u8) bool {
    if (path.len == 0 or path.len > 1024 or path[0] == '/') return false;
    return std.mem.indexOf(u8, path, "..") == null;
}

pub fn parse(allocator: std.mem.Allocator, data: []const u8) !Scenario {
    const wire = std.json.parseFromSliceLeaky(Wire, allocator, data, .{}) catch
        return error.InvalidScenario;
    if (!std.mem.eql(u8, wire.schema, "xsprof/lab-scenario/v1")) return error.InvalidScenario;
    if (wire.id.len == 0 or wire.id.len > 64) return error.InvalidScenario;
    if (wire.steps.len == 0 or wire.steps.len > max_steps) return error.InvalidScenario;
    if (!safePath(wire.source.path)) return error.InvalidScenario;
    const source_kind = std.meta.stringToEnum(SourceKind, wire.source.kind) orelse
        return error.InvalidScenario;
    const steps = try allocator.alloc(Step, wire.steps.len);
    var previous: u32 = 0;
    for (wire.steps, 0..) |wire_step, index| {
        const step_action = std.meta.stringToEnum(StepAction, wire_step.action) orelse
            return error.InvalidScenario;
        if (wire_step.at_ms > max_time_ms) return error.InvalidScenario;
        if (index != 0 and wire_step.at_ms < previous) return error.InvalidScenario;
        if (wire_step.value.len > 1024) return error.InvalidScenario;
        steps[index] = .{ .at_ms = wire_step.at_ms, .action = step_action, .value = wire_step.value };
        previous = wire_step.at_ms;
    }
    const assertions = try allocator.alloc(Assertion, wire.assertions.len);
    for (wire.assertions, 0..) |wire_assertion, index| {
        const metric = std.meta.stringToEnum(Metric, wire_assertion.metric) orelse
            return error.InvalidScenario;
        const op = std.meta.stringToEnum(Op, wire_assertion.op) orelse
            return error.InvalidScenario;
        if (wire_assertion.value.len == 0 or wire_assertion.value.len > 128) {
            return error.InvalidScenario;
        }
        assertions[index] = .{ .metric = metric, .op = op, .value = wire_assertion.value };
    }
    return .{
        .id = wire.id,
        .source = .{ .kind = source_kind, .path = wire.source.path },
        .steps = steps,
        .assertions = assertions,
    };
}

fn sanitize(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out = try allocator.alloc(u8, text.len);
    for (text, 0..) |byte, index| {
        out[index] = if (std.ascii.isAlphanumeric(byte)) std.ascii.toLower(byte) else '-';
    }
    return out;
}

fn writeTrace(
    io: std.Io,
    allocator: std.mem.Allocator,
    session: *const session_mod.Session,
    path: []const u8,
) !void {
    if (!safePath(path)) return error.InvalidScenario;
    const file = std.Io.Dir.cwd().createFile(io, path, .{}) catch
        return error.ExportFailed;
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var writer = file.writer(io, &buffer);
    chrome_trace.writeTimeline(&writer.interface, allocator, session.events, null, null) catch
        return error.ExportFailed;
    try writer.interface.flush();
}

fn applyStep(
    io: std.Io,
    allocator: std.mem.Allocator,
    lab: *lab_state.LabState,
    session: *const session_mod.Session,
    step: Step,
) !void {
    switch (step.action) {
        .screen => {
            const screen = app.parseScreen(step.value) orelse return error.InvalidScenario;
            _ = try lab.apply(.{ .intent = .{ .screen = screen } });
        },
        .filter => {
            _ = try lab.apply(.{ .intent = .{ .filter_comm = step.value } });
        },
        .select => {
            const pid = std.fmt.parseInt(i32, step.value, 10) catch return error.InvalidScenario;
            _ = try lab.apply(.{ .intent = .{ .select_pid = pid } });
        },
        .transport => {
            const transport = std.meta.stringToEnum(action.TransportIntent, step.value) orelse
                return error.InvalidScenario;
            _ = try lab.apply(.{ .intent = .{ .transport = transport } });
        },
        .snapshot => {},
        .export_file => try writeTrace(io, allocator, session, step.value),
    }
}

fn snapshot(
    io: std.Io,
    allocator: std.mem.Allocator,
    lab: *lab_state.LabState,
    options: Options,
    label: []const u8,
    index: usize,
) ![]const u8 {
    const out_dir = options.out_dir orelse return error.OutputDirectoryRequired;
    try std.Io.Dir.cwd().createDirPath(io, out_dir);
    var frame_arena = std.heap.ArenaAllocator.init(allocator);
    defer frame_arena.deinit();
    var frame: frame_mod.Frame = undefined;
    try frame.init(frame_arena.allocator(), options.width, options.height, .{});
    defer frame.deinit();
    var ui = layout.Ui.init(&frame);
    defer ui.deinit();
    lab_view.build(lab, &ui) catch return error.RenderFailed;
    ui.finish() catch return error.RenderFailed;
    const clean = try sanitize(allocator, if (label.len == 0) "frame" else label);
    const name = try std.fmt.allocPrint(allocator, "{s}/{d:0>4}-{s}.png", .{ out_dir, index, clean });
    frame.savePng(io, name) catch return error.RenderFailed;
    return name;
}

fn numericMetric(session: *const session_mod.Session, metric: Metric) ?u64 {
    return switch (metric) {
        .events => session.events.len,
        .switches => session.switches,
        .wakeups => session.wakeups,
        .migrations => session.migrations,
        .faults => session.faults,
        .lost => session.lost,
        .cpu_count => session.cpu_count,
        else => null,
    };
}

fn evaluate(
    allocator: std.mem.Allocator,
    session: *const session_mod.Session,
    lab: *const lab_state.LabState,
    assertion: Assertion,
) !AssertionResult {
    var passed = false;
    var actual: []const u8 = "";
    if (numericMetric(session, assertion.metric)) |value| {
        const expected = std.fmt.parseInt(u64, assertion.value, 10) catch {
            return .{
                .metric = @tagName(assertion.metric),
                .op = @tagName(assertion.op),
                .expected = assertion.value,
                .actual = "invalid",
                .passed = false,
            };
        };
        actual = try std.fmt.allocPrint(allocator, "{d}", .{value});
        passed = switch (assertion.op) {
            .eq => value == expected,
            .ne => value != expected,
            .gte => value >= expected,
            .lte => value <= expected,
        };
    } else {
        actual = switch (assertion.metric) {
            .screen => @tagName(lab.view.screen),
            .indicator => "host_mutation=false",
            else => "unavailable",
        };
        passed = switch (assertion.op) {
            .eq => std.mem.eql(u8, actual, assertion.value),
            .ne => !std.mem.eql(u8, actual, assertion.value),
            else => false,
        };
    }
    return .{
        .metric = @tagName(assertion.metric),
        .op = @tagName(assertion.op),
        .expected = assertion.value,
        .actual = actual,
        .passed = passed,
    };
}

pub fn run(
    io: std.Io,
    allocator: std.mem.Allocator,
    scenario_path: []const u8,
    options: Options,
) !RunResult {
    const data = std.Io.Dir.cwd().readFileAlloc(
        io,
        scenario_path,
        allocator,
        .limited(max_file_bytes),
    ) catch return error.ScenarioUnreadable;
    const scenario = try parse(allocator, data);
    const session = session_mod.Session.load(io, allocator, scenario.source.path) catch
        return error.SourceUnreadable;
    var lab = try lab_state.LabState.init(allocator);
    defer lab.deinit();
    _ = try lab.apply(.{ .completion = .{ .source_ready = .{ .session = &session } } });

    var snapshots: std.ArrayList([]const u8) = .empty;
    errdefer snapshots.deinit(allocator);
    for (scenario.steps, 0..) |step, index| {
        try applyStep(io, allocator, &lab, &session, step);
        if (step.action == .snapshot) {
            const name = try snapshot(io, allocator, &lab, options, step.value, index);
            try snapshots.append(allocator, name);
        }
    }
    var assertions: std.ArrayList(AssertionResult) = .empty;
    errdefer assertions.deinit(allocator);
    var passed = true;
    for (scenario.assertions) |assertion| {
        const result = try evaluate(allocator, &session, &lab, assertion);
        if (!result.passed) passed = false;
        try assertions.append(allocator, result);
    }
    return .{
        .id = scenario.id,
        .passed = passed,
        .steps = scenario.steps.len,
        .events = session.events.len,
        .lost = session.lost,
        .assertions = try assertions.toOwnedSlice(allocator),
        .snapshots = try snapshots.toOwnedSlice(allocator),
    };
}

pub fn writeJson(w: *std.Io.Writer, result: RunResult) !void {
    try w.writeAll("{\"assertions\":[");
    for (result.assertions, 0..) |assertion, index| {
        if (index != 0) try w.writeByte(',');
        try w.writeAll("{\"actual\":");
        try json.write(w, .{ .string = assertion.actual });
        try w.writeAll(",\"expected\":");
        try json.write(w, .{ .string = assertion.expected });
        try w.writeAll(",\"metric\":");
        try json.write(w, .{ .string = assertion.metric });
        try w.writeAll(",\"op\":");
        try json.write(w, .{ .string = assertion.op });
        try w.writeAll(",\"passed\":");
        try json.write(w, .{ .boolean = assertion.passed });
        try w.writeByte('}');
    }
    try w.writeAll("],\"events\":");
    try json.write(w, .{ .unsigned = result.events });
    try w.writeAll(",\"host_mutation\":false,\"lost\":");
    try json.write(w, .{ .unsigned = result.lost });
    try w.writeAll(",\"scenario\":");
    try json.write(w, .{ .string = result.id });
    try w.writeAll(",\"schema\":\"xsprof/lab-run/v1\",\"snapshots\":[");
    for (result.snapshots, 0..) |snapshot_path, index| {
        if (index != 0) try w.writeByte(',');
        try json.write(w, .{ .string = snapshot_path });
    }
    try w.writeAll("],\"status\":");
    try json.write(w, .{ .string = if (result.passed) "passed" else "failed" });
    try w.writeAll(",\"steps\":");
    try json.write(w, .{ .unsigned = result.steps });
    try w.writeByte('}');
}

test "scenario parser validates actions and bounds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const data =
        "{\"schema\":\"xsprof/lab-scenario/v1\",\"id\":\"tiny\"," ++
        "\"source\":{\"kind\":\"fixture\",\"path\":\"fixtures/ui/empty.ndjson\"}," ++
        "\"steps\":[{\"at_ms\":0,\"action\":\"screen\",\"value\":\"timeline\"}]," ++
        "\"assertions\":[{\"metric\":\"events\",\"op\":\"eq\",\"value\":\"1\"}]}";
    const scenario = try parse(arena.allocator(), data);
    try std.testing.expectEqualStrings("tiny", scenario.id);
    try std.testing.expectEqual(@as(usize, 1), scenario.steps.len);
    try std.testing.expectEqual(StepAction.screen, scenario.steps[0].action);
    try std.testing.expectError(
        error.InvalidScenario,
        parse(arena.allocator(), "{\"schema\":\"nope\"}"),
    );
}
