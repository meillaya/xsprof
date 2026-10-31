//! Minimal standalone xsui example: build a theme, a layout tree, a flat draw
//! list, and a deterministic PNG through only the public package API.
//!
//!   ../../tools/zig build example -- --out /tmp/xsui-example.png

const std = @import("std");
const xsui = @import("xsui");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var out: []const u8 = "zig-out/xsui-example.png";
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--out") and index + 1 < args.len) {
            index += 1;
            out = args[index];
        }
    }
    if (std.fs.path.dirname(out)) |dir| {
        // The absolute case is expected to exist (for example /tmp); the
        // std Io Dir API only creates relative path chains.
        if (!std.fs.path.isAbsolute(dir)) {
            try std.Io.Dir.cwd().createDirPath(init.io, dir);
        }
    }

    var frame: xsui.Frame = undefined;
    try frame.init(arena, 640, 360, xsui.themes.dark);
    defer frame.deinit();
    var ui = xsui.Ui.init(&frame);
    defer ui.deinit();
    try buildView(&ui);
    try ui.finish();
    try frame.savePng(init.io, out);
    std.debug.print("xsui example: {s} ({d} instances)\n", .{ out, frame.list.items.items.len });
}

fn buildView(ui: *xsui.Ui) !void {
    const th = ui.theme;
    var root = try ui.column(.{ .bg = th.bg });

    var header = try ui.row(.{
        .height = 46,
        .padding = .{ .left = 16, .right = 16 },
        .align_items = .center,
        .bg = th.raised,
    });
    try ui.text(.{ .text = "xsui", .size = 20, .color = th.live, .weight = .bold });
    try ui.text(.{ .text = "  standalone GPU UI package", .size = 11, .color = th.muted });
    var spacer = try ui.column(.{ .flex = 1 });
    spacer.end();
    var version = try xsui.widgets.chip(ui, "v" ++ xsui.version, th.pass);
    version.end();
    header.end();

    var body = try ui.row(.{
        .flex = 1,
        .padding = xsui.Edges.all(16),
        .gap = 16,
    });
    var left = try ui.column(.{ .flex = 1, .gap = 12 });
    var cards = try ui.row(.{ .height = 58, .gap = 12 });
    var draw_card = try xsui.widgets.statCard(ui, "DRAW LIST", "one stream", th.live);
    draw_card.end();
    var atlas_card = try xsui.widgets.statCard(ui, "ATLAS", "1024 x 1024", th.vm);
    atlas_card.end();
    var instance_card = try xsui.widgets.statCard(ui, "INSTANCE", "72 bytes", th.live);
    instance_card.end();
    cards.end();

    var panel = try xsui.widgets.panel(ui, "BACKENDS", .{ .flex = 1 });
    try backendRow(ui, "CPU raster", "snapshots, parity", th.pass);
    try backendRow(ui, "Metal", "macOS, instanced", th.live);
    try backendRow(ui, "OpenGL 3.3", "Linux, runtime loaded", th.live);
    try backendRow(ui, "WebGL2", "browser shim", th.pending);
    panel.end();
    left.end();

    var right = try ui.column(.{ .flex = 1, .gap = 12 });
    var contracts = try xsui.widgets.panel(ui, "CONTRACTS", .{ .flex = 1 });
    try xsui.widgets.rule(ui);
    try ui.text(.{ .text = "custom painters via Ui.custom", .size = 11, .color = th.text });
    try ui.text(.{ .text = "theme tokens via themes.derive", .size = 11, .color = th.text });
    try ui.text(.{ .text = "fonts via FrameOptions.fonts", .size = 11, .color = th.text });
    try ui.text(.{ .text = "backends via gpu.Renderer", .size = 11, .color = th.text });
    try ui.text(.{ .text = "headless frames via Tester", .size = 11, .color = th.text });
    contracts.end();

    var safety = try xsui.widgets.panel(ui, "SAFETY", .{ .height = 106 });
    try ui.text(.{ .text = "read-only UI", .size = 14, .color = th.pass, .weight = .bold });
    try ui.text(.{
        .text = "No host mutation, no telemetry, no network.",
        .size = 10,
        .color = th.muted,
    });
    try ui.text(.{
        .text = "Missing GPU or data is reported as SKIP, never faked.",
        .size = 10,
        .color = th.skip,
    });
    safety.end();
    right.end();

    body.end();

    var footer = try ui.row(.{
        .height = 26,
        .padding = .{ .left = 16, .right = 16 },
        .gap = 12,
        .align_items = .center,
        .bg = th.raised,
    });
    try ui.text(.{
        .text = "deterministic PNG snapshots  ·  same draw list everywhere",
        .size = 9,
        .color = th.muted,
    });
    footer.end();
    root.end();
}

fn backendRow(ui: *xsui.Ui, name: []const u8, detail: []const u8, color: xsui.Color) !void {
    var row = try ui.row(.{ .height = 22, .gap = 10, .align_items = .center });
    try ui.text(.{ .text = name, .size = 11, .color = color, .weight = .bold });
    try ui.text(.{ .text = detail, .size = 10, .color = ui.theme.muted });
    row.end();
}
