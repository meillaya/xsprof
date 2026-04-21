const std = @import("std");

pub const Event = union(enum) {
    none,
    escape,
    enter,
    tab,
    backtab,
    space,
    left,
    right,
    up,
    down,
    home,
    end,
    backspace,
    char: u8,
};

pub const Size = struct {
    cols: u16,
    rows: u16,
};

pub const Terminal = struct {
    stdin: std.fs.File,
    stdout: std.fs.File,
    original_termios: ?std.posix.termios = null,
    alt_screen_enabled: bool = false,

    pub fn init() !Terminal {
        var term = Terminal{
            .stdin = std.fs.File.stdin(),
            .stdout = std.fs.File.stdout(),
        };

        if (!term.stdin.isTty() or !term.stdout.isTty()) {
            return error.NotATerminal;
        }

        term.original_termios = try std.posix.tcgetattr(term.stdin.handle);
        var raw = term.original_termios.?;
        raw.iflag.BRKINT = false;
        raw.iflag.ICRNL = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.IXON = false;
        raw.oflag.OPOST = true;
        raw.cflag.CSIZE = .CS8;
        raw.cflag.CREAD = true;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.cc[@intFromEnum(std.c.V.MIN)] = 0;
        raw.cc[@intFromEnum(std.c.V.TIME)] = 1;
        try std.posix.tcsetattr(term.stdin.handle, .FLUSH, raw);

        try term.stdout.writeAll("\x1b[?1049h\x1b[?25l\x1b[2J\x1b[H");
        term.alt_screen_enabled = true;
        return term;
    }

    pub fn deinit(self: *Terminal) void {
        if (self.alt_screen_enabled) {
            self.stdout.writeAll("\x1b[0m\x1b[2J\x1b[H\x1b[?25h\x1b[?1049l") catch {};
            self.alt_screen_enabled = false;
        }
        if (self.original_termios) |original| {
            std.posix.tcsetattr(self.stdin.handle, .FLUSH, original) catch {};
            self.original_termios = null;
        }
    }

    pub fn size(self: *Terminal) Size {
        _ = self;
        var wsz: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
        const fd: usize = @bitCast(@as(isize, std.fs.File.stdout().handle));
        const rc = std.os.linux.syscall3(.ioctl, fd, std.os.linux.T.IOCGWINSZ, @intFromPtr(&wsz));
        if (std.os.linux.E.init(rc) == .SUCCESS and wsz.col > 0 and wsz.row > 0) {
            return .{ .cols = wsz.col, .rows = wsz.row };
        }
        return .{ .cols = 120, .rows = 40 };
    }

    pub fn writeFrame(self: *Terminal, bytes: []const u8) !void {
        try self.stdout.writeAll("\x1b[H");
        try self.stdout.writeAll(bytes);
    }

    pub fn readEvent(self: *Terminal, timeout_ms: i32) !Event {
        var fds = [_]std.posix.pollfd{.{
            .fd = self.stdin.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};

        const ready = try std.posix.poll(&fds, timeout_ms);
        if (ready == 0) return .none;

        var buf: [8]u8 = undefined;
        const n = try self.stdin.read(&buf);
        if (n == 0) return .{ .char = 'q' };
        return parseEvent(buf[0..n]);
    }
};

fn parseEvent(bytes: []const u8) Event {
    if (bytes.len == 0) return .none;
    if (bytes[0] == '\x1b') {
        if (bytes.len == 1) return .escape;
        if (std.mem.eql(u8, bytes, "\x1b[A")) return .up;
        if (std.mem.eql(u8, bytes, "\x1b[B")) return .down;
        if (std.mem.eql(u8, bytes, "\x1b[C")) return .right;
        if (std.mem.eql(u8, bytes, "\x1b[D")) return .left;
        if (std.mem.eql(u8, bytes, "\x1b[H") or std.mem.eql(u8, bytes, "\x1b[1~") or std.mem.eql(u8, bytes, "\x1bOH")) return .home;
        if (std.mem.eql(u8, bytes, "\x1b[F") or std.mem.eql(u8, bytes, "\x1b[4~") or std.mem.eql(u8, bytes, "\x1bOF")) return .end;
        if (std.mem.eql(u8, bytes, "\x1b[Z")) return .backtab;
        return .escape;
    }

    return switch (bytes[0]) {
        '\r', '\n' => .enter,
        '\t' => .tab,
        ' ' => .space,
        0x7f => .backspace,
        else => .{ .char = bytes[0] },
    };
}
