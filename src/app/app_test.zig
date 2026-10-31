const std = @import("std");
const app = @import("app.zig");
const session_mod = @import("../stream/session.zig");
const frame_mod = @import("../ui/frame.zig");
const layout = @import("../ui/layout.zig");
const input_mod = @import("../ui/input.zig");

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
    try std.testing.expect(state.events.visible > 0);

    frame.input.pointer_x = state.events.rect.x + 10;
    frame.input.pointer_y = state.events.rect.y + 10;
    frame.input.scroll_y = 1;
    var second = layout.Ui.init(&frame);
    defer second.deinit();
    try view(&state, &second);
    try second.finish();
    try std.testing.expect(state.events.scroll > 0);
}

// Checks that clicking an event row moves the timeline window to that event.
test "event click opens the timeline" {
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
    try std.testing.expect(state.events.start < session.events.len);

    frame.input.pointer_x = state.events.rect.x + 10;
    frame.input.pointer_y = state.events.rect.y + 5;
    frame.input.clicked = true;
    var second = layout.Ui.init(&frame);
    defer second.deinit();
    try view(&state, &second);
    try second.finish();
    try std.testing.expectEqual(Screen.timeline, state.screen);
    try std.testing.expect(state.window != null);
}

// Checks that the filter shortcut follows the selected task and clears.
test "timeline filter shortcut" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const session = try session_mod.Session.load(
        std.testing.io,
        arena.allocator(),
        "fixtures/ui/healthy.ndjson",
    );
    var state = State{
        .session = &session,
        .screen = .timeline,
        .selection = .{ .pid = session.slices[0].pid, .comm = session.slices[0].comm },
    };
    var frame: frame_mod.Frame = undefined;
    try frame.init(arena.allocator(), 960, 540, .{});
    defer frame.deinit();
    frame.input.key = input_mod.Key.filter;
    var first = layout.Ui.init(&frame);
    defer first.deinit();
    try view(&state, &first);
    try first.finish();
    try std.testing.expect(state.filter.comm != null);
    frame.input.key = input_mod.Key.clear;
    var second = layout.Ui.init(&frame);
    defer second.deinit();
    try view(&state, &second);
    try second.finish();
    try std.testing.expect(state.filter.comm == null);
}

// Checks that combined filters narrow the ledger without losing the event
// index mapping used by click-to-timeline.
test "combined filters narrow the event ledger" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const data =
        "{\"schema\":\"xsprof/event/v1\",\"event\":\"sched_switch\",\"ts_ns\":1," ++
        "\"cpu\":0,\"pid\":10,\"tid\":10,\"comm\":\"worker\",\"host_mutation\":false}\n" ++
        "{\"schema\":\"xsprof/event/v1\",\"event\":\"page_fault\",\"ts_ns\":2," ++
        "\"cpu\":0,\"pid\":11,\"tid\":11,\"comm\":\"worker\",\"host_mutation\":false}\n" ++
        "{\"schema\":\"xsprof/event/v1\",\"event\":\"marker\",\"ts_ns\":3," ++
        "\"cpu\":-1,\"pid\":-1,\"tid\":-1,\"detail\":\"sample_loss dropped=3\"," ++
        "\"host_mutation\":false}\n";
    const session = try session_mod.Session.fromData(arena.allocator(), "test", data);
    var state = State{ .session = &session, .screen = .events };
    var frame: frame_mod.Frame = undefined;
    try frame.init(arena.allocator(), 960, 540, .{});
    defer frame.deinit();

    state.filter.comm = "worker";
    state.filter.kind = .page_fault;
    var first = layout.Ui.init(&frame);
    defer first.deinit();
    try view(&state, &first);
    try first.finish();
    try std.testing.expectEqual(@as(usize, 1), state.events.match_total);
    try std.testing.expectEqual(@as(usize, 1), state.events.visible_count);
    try std.testing.expect(state.events.clickedIndex(0) != null);

    state.filter.clear();
    state.filter.loss_only = true;
    var second = layout.Ui.init(&frame);
    defer second.deinit();
    try view(&state, &second);
    try second.finish();
    try std.testing.expectEqual(@as(usize, 1), state.events.match_total);
    try std.testing.expectEqual(@as(usize, 1), state.events.visible_count);
    try std.testing.expectEqual(@as(usize, 2), state.events.clickedIndex(0).?);

    state.filter.clear();
    state.filter.comm = "absent";
    var third = layout.Ui.init(&frame);
    defer third.deinit();
    try view(&state, &third);
    try third.finish();
    try std.testing.expectEqual(@as(usize, 0), state.events.match_total);
    try std.testing.expectEqual(@as(usize, 0), state.events.visible_count);
}
