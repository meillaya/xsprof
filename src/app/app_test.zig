const std = @import("std");
const app = @import("app.zig");
const session_mod = @import("../stream/session.zig");
const frame_mod = @import("../ui/frame.zig");
const layout = @import("../ui/layout.zig");

const State = app.State;
const Screen = app.Screen;
const view = app.view;

test "overview and timeline views render" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const session = try session_mod.Session.load(
        std.testing.io,
        arena.allocator(),
        "fixtures/ui/healthy.ndjson",
    );
    var state = State{ .session = &session };
    var frame: frame_mod.Frame = undefined;
    try frame.init(arena.allocator(), 960, 540, .{});
    defer frame.deinit();
    for ([_]Screen{ .overview, .timeline, .advisor, .events, .capture }) |screen| {
        state.screen = screen;
        var ui = layout.Ui.init(&frame);
        defer ui.deinit();
        try view(&state, &ui);
        try ui.finish();
    }
}

test "capability-only session keeps counters at zero" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const line =
        "{\"schema\":\"xsprof/event/v1\",\"event\":\"capability\",\"ts_ns\":0," ++
        "\"cpu\":-1,\"pid\":-1,\"tid\":-1,\"a\":0,\"b\":0,\"c\":0," ++
        "\"comm\":\"live_capture\",\"detail\":\"live_capture:SKIP:why\"," ++
        "\"host_mutation\":false}\n";
    const data = line ++ line ++ line;
    const session = try session_mod.Session.fromData(arena.allocator(), "test", data);
    try std.testing.expectEqual(@as(u32, 0), session.lost);
    try std.testing.expectEqual(@as(u32, 0), session.refusals);
    try std.testing.expectEqual(@as(usize, 3), session.events.len);
    var state = State{ .session = &session };
    var frame: frame_mod.Frame = undefined;
    try frame.init(arena.allocator(), 960, 540, .{});
    defer frame.deinit();
    var ui = layout.Ui.init(&frame);
    defer ui.deinit();
    try view(&state, &ui);
    try ui.finish();
    var expect_zero = false;
    var i: usize = 0;
    while (i < ui.nodes.items.len) : (i += 1) {
        const text = ui.nodeText(i) orelse continue;
        if (std.mem.eql(u8, text, "lost / refusals")) {
            try std.testing.expect(i + 1 < ui.nodes.items.len);
            const value = ui.nodeText(i + 1) orelse "";
            if (std.mem.eql(u8, value, "0 / 0")) expect_zero = true;
        }
    }
    try std.testing.expect(expect_zero);
}

// Checks that a click inside the painted timeline selects the slice under the
// pointer and that the selection survives into the next frame.
test "timeline click selects a slice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const session = try session_mod.Session.load(
        std.testing.io,
        arena.allocator(),
        "fixtures/ui/healthy.ndjson",
    );
    var state = State{ .session = &session, .screen = .timeline };
    var frame: frame_mod.Frame = undefined;
    try frame.init(arena.allocator(), 960, 540, .{});
    defer frame.deinit();

    var first = layout.Ui.init(&frame);
    defer first.deinit();
    try view(&state, &first);
    try first.finish();
    try std.testing.expect(state.timeline.valid);

    const geometry = state.timeline;
    const start = if (state.window) |window| window.start_us else session.first_us;
    const end = if (state.window) |window| window.end_us else session.last_us;
    var target: ?session_mod.Slice = null;
    for (session.slices) |slice| {
        if (slice.start_us >= start and slice.end_us <= end) {
            target = slice;
            break;
        }
    }
    try std.testing.expect(target != null);
    const slice = target.?;
    frame.input.pointer_x = geometry.plot.x +
        geometry.plot.w * @as(f32, @floatFromInt(slice.start_us - start)) /
            @as(f32, @floatFromInt(@max(1, end - start))) + 2;
    frame.input.pointer_y = geometry.plot.y + 20 +
        geometry.lane_h * (@as(f32, @floatFromInt(slice.cpu)) + 0.5);
    frame.input.clicked = true;

    var second = layout.Ui.init(&frame);
    defer second.deinit();
    try view(&state, &second);
    try second.finish();
    try std.testing.expect(state.selection != null);
    try std.testing.expectEqual(slice.pid, state.selection.?.pid);
}

// Checks that wheel input over the event ledger advances the scroll window.
test "event ledger wheel scrolls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const session = try session_mod.Session.load(
        std.testing.io,
        arena.allocator(),
        "fixtures/ui/healthy.ndjson",
    );
    var state = State{ .session = &session, .screen = .events };
    var frame: frame_mod.Frame = undefined;
    try frame.init(arena.allocator(), 960, 540, .{});
    defer frame.deinit();

    var first = layout.Ui.init(&frame);
    defer first.deinit();
    try view(&state, &first);
    try first.finish();
    try std.testing.expect(state.events_visible > 0);

    frame.input.pointer_x = state.events_rect.x + 10;
    frame.input.pointer_y = state.events_rect.y + 10;
    frame.input.scroll_y = 1;
    var second = layout.Ui.init(&frame);
    defer second.deinit();
    try view(&state, &second);
    try second.finish();
    try std.testing.expect(state.event_scroll > 0);
}
