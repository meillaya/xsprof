//! Lab shell around the five profiler screens. The rail owns source picking,
//! capture controls, and transport; actions are resolved after layout so hit
//! rectangles are exact.

const std = @import("std");
const app = @import("app.zig");
const lab_state = @import("lab/state.zig");
const action = @import("lab/action.zig");
const controls = @import("../ui/controls.zig");
const layout = @import("../ui/layout.zig");
const input_mod = @import("../ui/input.zig");
const app_util = @import("app_util.zig");

pub const rail_width: f32 = 224;

pub const Hit = enum(u32) {
    healthy = 1,
    scheduler_mix = 2,
    empty = 3,
    capture_start = 4,
    capture_stop = 5,
    play = 6,
    pause = 7,
    step = 8,
    fit = 9,
    palette_close = 20,
    palette_healthy = 21,
    palette_scheduler_mix = 22,
    palette_capture = 23,
    palette_fit = 24,
};

pub const max_messages = 8;

pub const Messages = struct {
    items: [max_messages]action.Msg = @splat(.{ .intent = .quit }),
    len: u8 = 0,
    overflow: bool = false,

    pub fn add(self: *Messages, msg: action.Msg) void {
        if (self.len >= max_messages) {
            self.overflow = true;
            return;
        }
        self.items[self.len] = msg;
        self.len += 1;
    }

    pub fn slice(self: *const Messages) []const action.Msg {
        return self.items[0..self.len];
    }
};

pub fn build(lab: *lab_state.LabState, ui: *layout.Ui) !void {
    try app.viewWithOptions(&lab.view, ui, .{
        .leading_width = if (lab.rail_open) rail_width else 0,
        .leading_user = lab,
        .leading_build = if (lab.rail_open) &rail else null,
    });
}

fn rail(user: ?*anyopaque, ui: *layout.Ui) !void {
    const lab: *lab_state.LabState = @ptrCast(@alignCast(user.?));
    const th = ui.theme;
    const column = try ui.column(.{
        .width = rail_width,
        .padding = layout.Edges.all(10),
        .gap = 8,
        .bg = th.panel,
        .border = th.hairline,
        .border_width = 1,
        .radius = 4,
    });
    try ui.text(.{ .text = "LAB", .size = 11, .color = th.live, .weight = .bold });
    try ui.text(.{ .text = "read-only bench", .size = 9, .color = th.muted });
    if (lab.palette.open) {
        try ui.text(.{ .text = "COMMANDS", .size = 9, .color = th.skip, .weight = .bold });
        try controls.button(ui, @backingInt(Hit.palette_healthy), "open healthy", .{ .width = rail_width - 20 });
        try controls.button(ui, @backingInt(Hit.palette_scheduler_mix), "open scheduler-mix", .{ .width = rail_width - 20 });
        try controls.button(ui, @backingInt(Hit.palette_capture), "start 2s capture", .{ .width = rail_width - 20, .tone = .primary });
        try controls.button(ui, @backingInt(Hit.palette_fit), "fit transport", .{ .width = rail_width - 20 });
        try controls.button(ui, @backingInt(Hit.palette_close), "close", .{ .width = rail_width - 20, .tone = .quiet });
        column.end();
        return;
    }

    try ui.text(.{ .text = "SOURCE", .size = 9, .color = th.muted, .weight = .bold });
    try controls.button(ui, @backingInt(Hit.healthy), "healthy", .{ .width = rail_width - 20 });
    try controls.button(ui, @backingInt(Hit.scheduler_mix), "scheduler-mix", .{ .width = rail_width - 20 });
    try controls.button(ui, @backingInt(Hit.empty), "empty", .{ .width = rail_width - 20 });
    try ui.text(.{
        .text = if (lab.source.path_len == 0) "no source loaded" else lab.source.pathSlice(),
        .size = 9,
        .color = if (lab.source.phase == .failed) th.refuse else th.muted,
    });
    if (lab.source.phase == .failed and lab.source.reason_len != 0) {
        try ui.text(.{ .text = lab.source.reasonSlice(), .size = 9, .color = th.refuse });
    }

    try ui.text(.{ .text = "CAPTURE", .size = 9, .color = th.muted, .weight = .bold });
    var capture_row = try ui.row(.{ .height = 26, .gap = 6 });
    try controls.button(ui, @backingInt(Hit.capture_start), "start 2s", .{
        .width = 100,
        .tone = .primary,
        .enabled = lab.capture.phase != .running and lab.capture.phase != .starting,
    });
    try controls.button(ui, @backingInt(Hit.capture_stop), "stop", .{
        .width = 88,
        .tone = .danger,
        .enabled = lab.capture.phase == .running or lab.capture.phase == .starting,
    });
    capture_row.end();
    try ui.text(.{
        .text = try std.fmt.allocPrint(ui.allocator, "state {s}  events {d}  lost {d}", .{
            @tagName(lab.capture.phase),
            lab.capture.events,
            lab.capture.lost,
        }),
        .size = 9,
        .color = switch (lab.capture.phase) {
            .failed, .refused => th.refuse,
            .skipped => th.skip,
            .running => th.live,
            else => th.muted,
        },
    });
    if (lab.capture.reason_len != 0) {
        try ui.text(.{ .text = lab.capture.reasonSlice(), .size = 9, .color = th.skip });
    }

    try ui.text(.{ .text = "TRANSPORT", .size = 9, .color = th.muted, .weight = .bold });
    var transport_row = try ui.row(.{ .height = 26, .gap = 6 });
    try controls.button(ui, @backingInt(Hit.play), "play", .{ .width = 58 });
    try controls.button(ui, @backingInt(Hit.pause), "pause", .{ .width = 62 });
    try controls.button(ui, @backingInt(Hit.step), "step", .{ .width = 58 });
    transport_row.end();
    var fit_row = try ui.row(.{ .height = 26 });
    try controls.button(ui, @backingInt(Hit.fit), "fit window", .{ .width = 100 });
    fit_row.end();
    try ui.text(.{
        .text = try std.fmt.allocPrint(ui.allocator, "cursor {d}ms", .{lab.transport.cursor_us / 1000}),
        .size = 9,
        .color = th.muted,
    });

    try ui.text(.{ .text = "INSPECTOR", .size = 9, .color = th.muted, .weight = .bold });
    if (lab.view.selection) |selection| {
        try ui.text(.{
            .text = try std.fmt.allocPrint(ui.allocator, "{s} pid={d}", .{ selection.comm, selection.pid }),
            .size = 10,
            .color = th.text,
        });
        if (app_util.selectedMetric(lab.view.session, selection.pid, selection.comm)) |task| {
            try ui.text(.{
                .text = try std.fmt.allocPrint(
                    ui.allocator,
                    "p95 {d}ms  offcpu {d}ms  switches {d}",
                    .{ task.wait_p95_us / 1000, task.offcpu_p95_us / 1000, task.switches },
                ),
                .size = 9,
                .color = th.live,
            });
        }
    } else {
        try ui.text(.{ .text = "no selection", .size = 9, .color = th.muted });
    }

    if (lab.toast_len != 0) {
        try controls.toast(ui, lab.toastSlice(), switch (lab.toast_kind) {
            .success => th.pass,
            .toast_error => th.refuse,
            else => th.skip,
        });
    }
    column.end();
}

pub fn collect(lab: *lab_state.LabState, ui: *layout.Ui, input: *input_mod.Input) Messages {
    var messages = Messages{};
    if (input.key == .lab) {
        messages.add(.{ .intent = .toggle_rail });
        input.key = .none;
    }
    if (input.key == .palette) {
        messages.add(.{ .intent = .palette_open });
        input.key = .none;
    }
    if (input.key == .escape and lab.palette.open) {
        messages.add(.{ .intent = .palette_close });
        input.key = .none;
    }
    if (input.clicked) {
        if (ui.hitAt(input.pointer_x, input.pointer_y)) |id| {
            switch (id) {
                @backingInt(Hit.healthy) => messages.add(.{ .intent = .{ .open_source = .{
                    .kind = .replay,
                    .path = "fixtures/ui/healthy.ndjson",
                } } }),
                @backingInt(Hit.scheduler_mix) => messages.add(.{ .intent = .{ .open_source = .{
                    .kind = .replay,
                    .path = "fixtures/real/scheduler-mix.ndjson",
                } } }),
                @backingInt(Hit.empty) => messages.add(.{ .intent = .{ .open_source = .{
                    .kind = .replay,
                    .path = "fixtures/ui/empty.ndjson",
                } } }),
                @backingInt(Hit.capture_start) => messages.add(.{ .intent = .{ .start_capture = .{
                    .duration_ms = 2000,
                    .preset = .scheduler,
                } } }),
                @backingInt(Hit.capture_stop) => messages.add(.{ .intent = .stop_capture }),
                @backingInt(Hit.play) => messages.add(.{ .intent = .{ .transport = .play } }),
                @backingInt(Hit.pause) => messages.add(.{ .intent = .{ .transport = .pause } }),
                @backingInt(Hit.step) => messages.add(.{ .intent = .{ .transport = .step_forward } }),
                @backingInt(Hit.fit) => messages.add(.{ .intent = .{ .transport = .fit } }),
                @backingInt(Hit.palette_close) => messages.add(.{ .intent = .palette_close }),
                @backingInt(Hit.palette_healthy) => messages.add(.{ .intent = .{ .open_source = .{
                    .kind = .replay,
                    .path = "fixtures/ui/healthy.ndjson",
                } } }),
                @backingInt(Hit.palette_scheduler_mix) => messages.add(.{ .intent = .{ .open_source = .{
                    .kind = .replay,
                    .path = "fixtures/real/scheduler-mix.ndjson",
                } } }),
                @backingInt(Hit.palette_capture) => messages.add(.{ .intent = .{ .start_capture = .{
                    .duration_ms = 2000,
                    .preset = .scheduler,
                } } }),
                @backingInt(Hit.palette_fit) => messages.add(.{ .intent = .{ .transport = .fit } }),
                else => {},
            }
            input.clicked = false;
        }
    }
    return messages;
}

test "lab rail registers the source and capture hits" {
    const frame_mod = @import("../ui/frame.zig");
    var lab = try lab_state.LabState.init(std.testing.allocator);
    defer lab.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var frame: frame_mod.Frame = undefined;
    try frame.init(arena.allocator(), 960, 540, .{});
    defer frame.deinit();
    var ui = layout.Ui.init(&frame);
    defer ui.deinit();
    try build(&lab, &ui);
    try ui.finish();
    try std.testing.expect(ui.hits.items.len > 0);
    const first = ui.hits.items[0];
    try std.testing.expectEqual(
        @as(?u32, first.id),
        ui.hitAt(first.rect.x + 1, first.rect.y + 1),
    );
}

test "palette click emits the source intent" {
    const frame_mod = @import("../ui/frame.zig");
    var lab = try lab_state.LabState.init(std.testing.allocator);
    defer lab.deinit();
    lab.palette.open = true;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var frame: frame_mod.Frame = undefined;
    try frame.init(arena.allocator(), 960, 540, .{});
    defer frame.deinit();
    var ui = layout.Ui.init(&frame);
    defer ui.deinit();
    try build(&lab, &ui);
    try ui.finish();
    var target: ?layout.Hit = null;
    for (ui.hits.items) |hit| {
        if (hit.id == @backingInt(Hit.palette_healthy)) target = hit;
    }
    try std.testing.expect(target != null);
    var input = input_mod.Input{
        .pointer_x = target.?.rect.x + 2,
        .pointer_y = target.?.rect.y + 2,
        .clicked = true,
    };
    const messages = collect(&lab, &ui, &input);
    try std.testing.expectEqual(@as(u8, 1), messages.len);
    switch (messages.slice()[0]) {
        .intent => |intent| switch (intent) {
            .open_source => |source| try std.testing.expectEqualStrings(
                "fixtures/ui/healthy.ndjson",
                source.path,
            ),
            else => try std.testing.expect(false),
        },
        else => try std.testing.expect(false),
    }
}
