//! Display formatting shared by the console screens.

const std = @import("std");

pub fn int(buf: []u8, value: u64) []const u8 {
    var reverse: [32]u8 = undefined;
    var count: usize = 0;
    var v = value;
    if (v == 0) return "0";
    while (v != 0) : (v /= 10) {
        reverse[count] = @intCast('0' + v % 10);
        count += 1;
    }
    var out: usize = 0;
    while (count > 0) {
        count -= 1;
        if (out != 0 and (count + 1) % 3 == 0 and out < buf.len) {
            buf[out] = ',';
            out += 1;
        }
        if (out < buf.len) buf[out] = reverse[count];
        out += 1;
    }
    return buf[0..@min(out, buf.len)];
}

pub fn intI32(buf: []u8, value: i32) []const u8 {
    if (value >= 0) return int(buf, @intCast(value));
    if (buf.len == 0) return "";
    buf[0] = '-';
    return std.fmt.bufPrint(buf[1..], "{s}", .{int(buf[1..], @intCast(-@as(i64, value)))}) catch "-";
}

pub fn secs(buf: []u8, milliseconds: f64, digits: usize) []const u8 {
    return switch (digits) {
        0 => std.fmt.bufPrint(buf, "{d:.0} s", .{milliseconds / 1000.0}) catch "?",
        1 => std.fmt.bufPrint(buf, "{d:.1} s", .{milliseconds / 1000.0}) catch "?",
        2 => std.fmt.bufPrint(buf, "{d:.2} s", .{milliseconds / 1000.0}) catch "?",
        else => std.fmt.bufPrint(buf, "{d:.3} s", .{milliseconds / 1000.0}) catch "?",
    };
}

pub fn ms(buf: []u8, value: f64, digits: usize) []const u8 {
    return switch (digits) {
        0 => std.fmt.bufPrint(buf, "{d:.0} ms", .{value}) catch "?",
        1 => std.fmt.bufPrint(buf, "{d:.1} ms", .{value}) catch "?",
        else => std.fmt.bufPrint(buf, "{d:.2} ms", .{value}) catch "?",
    };
}

pub fn pct(buf: []u8, value: u8) []const u8 {
    return std.fmt.bufPrint(buf, "{d}%", .{value}) catch "?";
}

pub fn pctF(buf: []u8, value: f64, digits: usize) []const u8 {
    return switch (digits) {
        0 => std.fmt.bufPrint(buf, "{d:.0}%", .{value}) catch "?",
        1 => std.fmt.bufPrint(buf, "{d:.1}%", .{value}) catch "?",
        else => std.fmt.bufPrint(buf, "{d:.2}%", .{value}) catch "?",
    };
}

pub fn f1(buf: []u8, value: f64) []const u8 {
    return std.fmt.bufPrint(buf, "{d:.1}", .{value}) catch "?";
}

pub fn f2(buf: []u8, value: f64) []const u8 {
    return std.fmt.bufPrint(buf, "{d:.2}", .{value}) catch "?";
}

pub fn f3(buf: []u8, value: f64) []const u8 {
    return std.fmt.bufPrint(buf, "{d:.3}", .{value}) catch "?";
}
