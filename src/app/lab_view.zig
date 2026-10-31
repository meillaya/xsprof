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
const compare_mod = @import("../analyze/compare.zig");

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
    export_trace = 10,
    source_input = 30,
    source_load = 31,
    export_input = 32,
    export_write = 33,
    compare_set = 40,
    compare_clear = 41,
    snapshot_write = 42,
    report_write = 43,
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
        .gap = 6,
        .bg = th.panel,
        .border = th.hairline,
        .border_width = 1,
        .radius = 4,
    });
    try ui.text(.{ .text = "LAB", .size = 11, .color = th.live, .weight = .bold });
    if (lab.palette.open) {
        try ui.text(.{ .text = "COMMANDS", .size = 9, .color = th.skip, .weight = .bold });
        if (lab.host_controls) {
            try controls.button(ui, @backingInt(Hit.palette_healthy), "open healthy", .{ .width = rail_width - 20 });
            try controls.button(ui, @backingInt(Hit.palette_scheduler_mix), "open scheduler-mix", .{ .width = rail_width - 20 });
            try controls.button(ui, @backingInt(Hit.palette_capture), "start 2s capture", .{ .width = rail_width - 20, .tone = .primary });
        }
        try controls.button(ui, @backingInt(Hit.palette_fit), "fit transport", .{ .width = rail_width - 20 });
        try controls.button(ui, @backingInt(Hit.palette_close), "close", .{ .width = rail_width - 20, .tone = .quiet });
        column.end();
        return;
    }

    try ui.text(.{ .text = "SOURCE", .size = 9, .color = th.muted, .weight = .bold });
    if (lab.host_controls) {
        try controls.textField(
            ui,
            @backingInt(Hit.source_input),
            lab.sourceInputSlice(),
            lab.input_focus == .source_path,
            "journal path",
        );
        var load_row = try ui.row(.{ .height = 26 });
        try controls.button(ui, @backingInt(Hit.source_load), "load path", .{ .width = 100, .tone = .primary });
        load_row.end();
        var sources = try ui.row(.{ .height = 26, .gap = 4 });
        try controls.button(ui, @backingInt(Hit.healthy), "healthy", .{ .width = 62 });
        try controls.button(ui, @backingInt(Hit.scheduler_mix), "real", .{ .width = 58 });
        try controls.button(ui, @backingInt(Hit.empty), "empty", .{ .width = 58 });
        sources.end();
    } else {
        try ui.text(.{ .text = "replay only; open a journal", .size = 9, .color = th.skip });
    }
    try ui.text(.{
        .text = if (lab.source.path_len == 0) "no source loaded" else lab.source.pathSlice(),
        .size = 9,
        .color = if (lab.source.phase == .failed) th.refuse else th.muted,
    });
    if (lab.source.phase == .failed and lab.source.reason_len != 0) {
        try ui.text(.{ .text = lab.source.reasonSlice(), .size = 9, .color = th.refuse });
    }
    if (lab.host_controls) {
        var compare_row = try ui.row(.{ .height = 24, .gap = 4 });
        try controls.button(ui, @backingInt(Hit.compare_set), "set A", .{ .width = 64 });
        try controls.button(ui, @backingInt(Hit.compare_clear), "clear", .{ .width = 60 });
        compare_row.end();
        if (lab.compare.phase == .failed) {
            try ui.text(.{ .text = "compare A failed", .size = 9, .color = th.refuse });
        }
    }
    if (lab.compare.session) |base| {
        const report = compare_mod.build(
            ui.allocator,
            if (lab.compare.path_len == 0) "compare" else lab.compare.pathSlice(),
            base.metrics,
            if (lab.source.path_len == 0) "active" else lab.source.pathSlice(),
            lab.view.session.metrics,
            10.0,
        ) catch null;
        if (report) |value| {
            try ui.text(.{
                .text = try std.fmt.allocPrint(
                    ui.allocator,
                    "A/B regressions {d} of {d}",
                    .{ value.regressions, value.tasks.len },
                ),
                .size = 9,
                .color = if (value.regressions == 0) th.pass else th.refuse,
            });
        }
    }

    if (lab.host_controls and lab.host.seen) {
        try ui.text(.{
            .text = try std.fmt.allocPrint(
                ui.allocator,
                "HOST pressure {s} {d}/{d}/{d} cg {d}",
                .{
                    if (lab.host.pressure_available) "ok" else "skip",
                    lab.host.cpu_bp,
                    lab.host.memory_bp,
                    lab.host.io_bp,
                    lab.host.cgroup_groups,
                },
            ),
            .size = 9,
            .color = if (lab.host.pressure_available) th.live else th.skip,
        });
    }

    try ui.text(.{ .text = "CAPTURE", .size = 9, .color = th.muted, .weight = .bold });
    if (lab.host_controls) {
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
    } else {
        try ui.text(.{ .text = "native only", .size = 9, .color = th.skip });
    }
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

    if (lab.host_controls) {
        try ui.text(.{ .text = "EXPORT", .size = 9, .color = th.muted, .weight = .bold });
        try controls.textField(
            ui,
            @backingInt(Hit.export_input),
            lab.exportInputSlice(),
            lab.input_focus == .export_path,
            "trace.json",
        );
        var write_row = try ui.row(.{ .height = 26, .gap = 4 });
        try controls.button(ui, @backingInt(Hit.export_write), "trace", .{ .width = 60 });
        try controls.button(ui, @backingInt(Hit.report_write), "report", .{ .width = 60 });
        try controls.button(ui, @backingInt(Hit.snapshot_write), "PNG", .{ .width = 52 });
        write_row.end();
    }
    if (lab.view.selection) |selection| {
        try ui.text(.{ .text = "INSPECTOR", .size = 9, .color = th.muted, .weight = .bold });
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
    if (lab.input_focus != .none) {
        for (input.keyEvents()) |event| {
            if (event.text_len != 0) {
                messages.add(.{ .intent = .{ .text_input = .{
                    .field = lab.input_focus,
                    .text = event.textSlice(),
                } } });
            }
        }
        if (input.key == .backspace) {
            messages.add(.{ .intent = .{ .backspace_input = lab.input_focus } });
            input.key = .none;
        }
        if (input.key == .enter) {
            messages.add(.{ .intent = .{ .submit_input = lab.input_focus } });
            input.key = .none;
        }
        if (input.key == .escape) {
            messages.add(.{ .intent = .cancel_input });
            input.key = .none;
        }
    }
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
                @backingInt(Hit.export_trace) => messages.add(.{ .intent = .{ .exports = .{
                    .kind = .trace,
                    .path = "xsprof-trace.json",
                } } }),
                @backingInt(Hit.source_input) => messages.add(.{ .intent = .{ .focus_input = .source_path } }),
                @backingInt(Hit.source_load) => messages.add(.{ .intent = .{ .submit_input = .source_path } }),
                @backingInt(Hit.export_input) => messages.add(.{ .intent = .{ .focus_input = .export_path } }),
                @backingInt(Hit.export_write) => messages.add(.{ .intent = .{ .submit_input = .export_path } }),
                @backingInt(Hit.compare_set) => messages.add(.{ .intent = .set_compare }),
                @backingInt(Hit.compare_clear) => messages.add(.{ .intent = .clear_compare }),
                @backingInt(Hit.snapshot_write) => messages.add(.{ .intent = .{ .exports = .{
                    .kind = .snapshot,
                    .path = "xsprof-lab.png",
                } } }),
                @backingInt(Hit.report_write) => messages.add(.{ .intent = .{ .exports = .{
                    .kind = .report,
                    .path = "xsprof-report.json",
                } } }),
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
