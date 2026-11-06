//! Procedural stroke icons for the operator console. The prototype uses small
//! inline SVGs; these are equivalent axis/diagonal compositions on the draw
//! list, so they stay sharp on every GPU backend without an SVG dependency.

const std = @import("std");
const xsui = @import("xsui");

const Canvas = xsui.Canvas;
const Color = xsui.Color;
const Rect = xsui.Rect;

pub const Kind = enum {
    overview,
    timeline,
    advisor,
    events,
    capture,
    home,
    audit,
    settings,
    menu,
    sun,
    help,
    folder,
    play,
    pause,
    lock,
    question,
    chart,
    chevron,
    close,
};

pub fn draw(canvas: *Canvas, kind: Kind, rect: Rect, color: Color) !void {
    const w = rect.w;
    const scale = w / 20.0;
    const x = rect.x;
    const y = rect.y;
    switch (kind) {
        .overview => {
            const cell = 8 * scale;
            try canvas.stroke(.{ .x = x + 2 * scale, .y = y + 2 * scale, .w = cell, .h = cell }, 1, color, 1);
            try canvas.stroke(.{ .x = x + 11 * scale, .y = y + 2 * scale, .w = cell, .h = cell }, 1, color, 1);
            try canvas.stroke(.{ .x = x + 2 * scale, .y = y + 11 * scale, .w = cell, .h = cell }, 1, color, 1);
            try canvas.stroke(.{ .x = x + 11 * scale, .y = y + 11 * scale, .w = cell, .h = cell }, 1, color, 1);
        },
        .timeline => {
            var row: usize = 0;
            while (row < 3) : (row += 1) {
                const yy = y + @as(f32, @floatFromInt(5 + row * 5)) * scale;
                try canvas.line(x + 2 * scale, yy, x + 18 * scale, yy, 1, color);
                try canvas.line(x + @as(f32, @floatFromInt(4 + row * 3)) * scale, yy - 2 * scale, x + @as(f32, @floatFromInt(4 + row * 3)) * scale, yy + 2 * scale, 1, color);
            }
        },
        .advisor => {
            try canvas.line(x + 4 * scale, y + 5 * scale, x + 16 * scale, y + 5 * scale, 1, color);
            try canvas.line(x + 4 * scale, y + 5 * scale, x + 4 * scale, y + 12 * scale, 1, color);
            try canvas.line(x + 16 * scale, y + 5 * scale, x + 16 * scale, y + 12 * scale, 1, color);
            try canvas.line(x + 4 * scale, y + 12 * scale, x + 10 * scale, y + 16 * scale, 1, color);
            try canvas.line(x + 16 * scale, y + 12 * scale, x + 10 * scale, y + 16 * scale, 1, color);
        },
        .events => {
            var row: usize = 0;
            while (row < 3) : (row += 1) {
                const yy = y + @as(f32, @floatFromInt(5 + row * 5)) * scale;
                try canvas.fill(.{ .x = x + 3 * scale, .y = yy - 1 * scale, .w = 2 * scale, .h = 2 * scale }, color);
                try canvas.line(x + 7 * scale, yy, x + 17 * scale, yy, 1, color);
            }
        },
        .capture => {
            try canvas.stroke(.{ .x = x + 3 * scale, .y = y + 4 * scale, .w = 14 * scale, .h = 12 * scale }, 1, color, 1);
            try canvas.line(x + 7 * scale, y + 10 * scale, x + 12 * scale, y + 10 * scale, 1, color);
            try canvas.line(x + 9.5 * scale, y + 7.5 * scale, x + 9.5 * scale, y + 12.5 * scale, 1, color);
        },
        .home => {
            try canvas.line(x + 3 * scale, y + 10 * scale, x + 10 * scale, y + 3 * scale, 1, color);
            try canvas.line(x + 10 * scale, y + 3 * scale, x + 17 * scale, y + 10 * scale, 1, color);
            try canvas.line(x + 5 * scale, y + 9 * scale, x + 5 * scale, y + 17 * scale, 1, color);
            try canvas.line(x + 5 * scale, y + 17 * scale, x + 15 * scale, y + 17 * scale, 1, color);
            try canvas.line(x + 15 * scale, y + 9 * scale, x + 15 * scale, y + 17 * scale, 1, color);
        },
        .audit => {
            try canvas.stroke(.{ .x = x + 3 * scale, .y = y + 3 * scale, .w = 14 * scale, .h = 15 * scale }, 1, color, 1);
            try canvas.line(x + 6 * scale, y + 7 * scale, x + 14 * scale, y + 7 * scale, 1, color);
            try canvas.line(x + 6 * scale, y + 10 * scale, x + 14 * scale, y + 10 * scale, 1, color);
            try canvas.line(x + 6 * scale, y + 13 * scale, x + 11 * scale, y + 13 * scale, 1, color);
        },
        .settings => {
            try canvas.stroke(.{ .x = x + 4 * scale, .y = y + 4 * scale, .w = 12 * scale, .h = 12 * scale }, 4, color, 1);
            try canvas.fill(.{ .x = x + 8.5 * scale, .y = y + 8.5 * scale, .w = 3 * scale, .h = 3 * scale }, color);
        },
        .menu => {
            try canvas.line(x + 3 * scale, y + 6 * scale, x + 17 * scale, y + 6 * scale, 1.2, color);
            try canvas.line(x + 3 * scale, y + 10 * scale, x + 17 * scale, y + 10 * scale, 1.2, color);
            try canvas.line(x + 3 * scale, y + 14 * scale, x + 12 * scale, y + 14 * scale, 1.2, color);
        },
        .sun => {
            try canvas.circle(x + 10 * scale, y + 10 * scale, 4 * scale, color);
            try canvas.line(x + 10 * scale, y + 2 * scale, x + 10 * scale, y + 4 * scale, 1, color);
            try canvas.line(x + 10 * scale, y + 16 * scale, x + 10 * scale, y + 18 * scale, 1, color);
            try canvas.line(x + 2 * scale, y + 10 * scale, x + 4 * scale, y + 10 * scale, 1, color);
            try canvas.line(x + 16 * scale, y + 10 * scale, x + 18 * scale, y + 10 * scale, 1, color);
            try canvas.line(x + 4 * scale, y + 4 * scale, x + 6 * scale, y + 6 * scale, 1, color);
            try canvas.line(x + 14 * scale, y + 14 * scale, x + 16 * scale, y + 16 * scale, 1, color);
            try canvas.line(x + 16 * scale, y + 4 * scale, x + 14 * scale, y + 6 * scale, 1, color);
            try canvas.line(x + 6 * scale, y + 14 * scale, x + 4 * scale, y + 16 * scale, 1, color);
        },
        .help, .question => {
            try canvas.circle(x + 10 * scale, y + 10 * scale, 7 * scale, color);
        },
        .folder => {
            try canvas.stroke(.{ .x = x + 3 * scale, .y = y + 5 * scale, .w = 14 * scale, .h = 11 * scale }, 1, color, 1);
            try canvas.line(x + 3 * scale, y + 5 * scale, x + 8 * scale, y + 5 * scale, 1, color);
            try canvas.line(x + 8 * scale, y + 5 * scale, x + 9 * scale, y + 7 * scale, 1, color);
        },
        .play => {
            var i: usize = 0;
            while (i < 9) : (i += 1) {
                const t = @as(f32, @floatFromInt(i)) / 8.0;
                const yy = y + (4 + 12 * t) * scale;
                const xx = x + (6.5 + 7 * (1 - @abs(t * 2 - 1))) * scale;
                try canvas.line(x + 6.5 * scale, yy, xx, yy, 1, color);
            }
        },
        .pause => {
            try canvas.fill(.{ .x = x + 6 * scale, .y = y + 4 * scale, .w = 2.6 * scale, .h = 12 * scale }, color);
            try canvas.fill(.{ .x = x + 11.4 * scale, .y = y + 4 * scale, .w = 2.6 * scale, .h = 12 * scale }, color);
        },
        .lock => {
            try canvas.stroke(.{ .x = x + 5 * scale, .y = y + 9 * scale, .w = 10 * scale, .h = 7 * scale }, 1, color, 1);
            try canvas.line(x + 7 * scale, y + 9 * scale, x + 7 * scale, y + 7 * scale, 1, color);
            try canvas.line(x + 7 * scale, y + 7 * scale, x + 10 * scale, y + 5 * scale, 1, color);
            try canvas.line(x + 10 * scale, y + 5 * scale, x + 13 * scale, y + 7 * scale, 1, color);
            try canvas.line(x + 13 * scale, y + 7 * scale, x + 13 * scale, y + 9 * scale, 1, color);
        },
        .chart => {
            try canvas.line(x + 3 * scale, y + 15 * scale, x + 5 * scale, y + 11 * scale, 1.5, color);
            try canvas.line(x + 5 * scale, y + 11 * scale, x + 8 * scale, y + 13 * scale, 1.5, color);
            try canvas.line(x + 8 * scale, y + 13 * scale, x + 12 * scale, y + 6 * scale, 1.5, color);
            try canvas.line(x + 12 * scale, y + 6 * scale, x + 17 * scale, y + 4 * scale, 1.5, color);
        },
        .chevron => {
            try canvas.line(x + 7 * scale, y + 8 * scale, x + 11 * scale, y + 12 * scale, 1, color);
            try canvas.line(x + 11 * scale, y + 12 * scale, x + 7 * scale, y + 16 * scale, 1, color);
        },
        .close => {
            try canvas.line(x + 6 * scale, y + 6 * scale, x + 14 * scale, y + 14 * scale, 1.2, color);
            try canvas.line(x + 14 * scale, y + 6 * scale, x + 6 * scale, y + 14 * scale, 1.2, color);
        },
    }
}

pub fn brandMark(canvas: *Canvas, rect: Rect) !void {
    try canvas.rounded(rect, 5, .{ .r = 0x10, .g = 0x10, .b = 0x0e }, .{ .r = 0x3a, .g = 0x33, .b = 0x2b }, 1);
    const s = rect.w / 24.0;
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        try canvas.fill(.{
            .x = rect.x + 4 * s,
            .y = rect.y + @as(f32, @floatFromInt(6 + i * 6)) * s,
            .w = 16 * s,
            .h = 2 * s,
        }, .{ .r = 0x2a, .g = 0x27, .b = 0x23 });
    }
    try canvas.line(rect.x + 4.5 * s, rect.y + 17 * s, rect.x + 9 * s, rect.y + 12 * s, 1.4 * s, .{ .r = 0x58, .g = 0xd7, .b = 0xe8 });
    try canvas.line(rect.x + 9 * s, rect.y + 12 * s, rect.x + 13 * s, rect.y + 14 * s, 1.4 * s, .{ .r = 0x58, .g = 0xd7, .b = 0xe8 });
    try canvas.line(rect.x + 13 * s, rect.y + 14 * s, rect.x + 19 * s, rect.y + 6.5 * s, 1.4 * s, .{ .r = 0x58, .g = 0xd7, .b = 0xe8 });
}

pub fn stateGlyph(canvas: *Canvas, glyph: []const u8, rect: Rect, color: Color, size: f32) !void {
    if (std.mem.eql(u8, glyph, "◐")) {
        try canvas.circle(rect.x + rect.w * 0.5, rect.y + rect.h * 0.5, size * 0.32, color);
        try canvas.fill(.{
            .x = rect.x + rect.w * 0.5,
            .y = rect.y + rect.h * 0.5 - size * 0.32,
            .w = size * 0.32,
            .h = size * 0.64,
        }, .{ .r = 0x10, .g = 0x10, .b = 0x0e });
        return;
    }
}
