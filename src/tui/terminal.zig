const std = @import("std");

pub const enter_alternate_screen_sequence = "\x1b[?1049h\x1b[?25l\x1b[2J\x1b[H";
pub const exit_and_clear_terminal_sequence = "\x1b[0m\x1b[?25h\x1b[?1049l\x1b[2J\x1b[H";
pub const frame_home_sequence = "\x1b[H";

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

pub fn eqlSize(lhs: Size, rhs: Size) bool {
    return lhs.cols == rhs.cols and lhs.rows == rhs.rows;
}

pub const Terminal = struct {
    stdin: std.Io.File,
    stdout: std.Io.File,
    original_termios: ?std.posix.termios = null,
    alt_screen_enabled: bool = false,

    pub fn init() !Terminal {
        var term = Terminal{
            .stdin = std.Io.File.stdin(),
            .stdout = std.Io.File.stdout(),
        };

        if (!try term.stdin.isTty(std.Io.Threaded.global_single_threaded.io()) or !try term.stdout.isTty(std.Io.Threaded.global_single_threaded.io())) {
            return error.NotATerminal;
        }

        term.original_termios = try std.posix.tcgetattr(term.stdin.handle);
        const raw = rawModeFrom(term.original_termios.?);
        try std.posix.tcsetattr(term.stdin.handle, .FLUSH, raw);

        try term.stdout.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), enter_alternate_screen_sequence);
        term.alt_screen_enabled = true;
        return term;
    }

    pub fn deinit(self: *Terminal) void {
        if (self.original_termios) |original| {
            std.posix.tcsetattr(self.stdin.handle, .FLUSH, original) catch {};
            self.original_termios = null;
        }
        if (self.alt_screen_enabled) {
            self.stdout.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), exit_and_clear_terminal_sequence) catch {};
            self.alt_screen_enabled = false;
        }
    }

    pub fn size(self: *Terminal) Size {
        _ = self;
        var wsz: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
        const fd: usize = @bitCast(@as(isize, std.Io.File.stdout().handle));
        const rc = std.os.linux.syscall3(.ioctl, fd, std.os.linux.T.IOCGWINSZ, @intFromPtr(&wsz));
        if (std.os.linux.errno(rc) == .SUCCESS and wsz.col > 0 and wsz.row > 0) {
            return .{ .cols = wsz.col, .rows = wsz.row };
        }
        return .{ .cols = 120, .rows = 40 };
    }

    pub fn writeFrame(self: *Terminal, bytes: []const u8) !void {
        try self.stdout.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), frame_home_sequence);
        try self.stdout.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), bytes);
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
        const n = try self.stdin.readStreaming(std.Io.Threaded.global_single_threaded.io(), &.{&buf});
        if (n == 0) return .{ .char = 'q' };
        return parseEvent(buf[0..n]);
    }
};

pub fn rawModeFrom(original: std.posix.termios) std.posix.termios {
    var raw = original;
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
    raw.lflag.ISIG = false;
    raw.cc[@intFromEnum(std.c.V.MIN)] = 0;
    raw.cc[@intFromEnum(std.c.V.TIME)] = 1;
    return raw;
}

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

test "raw terminal mode routes ctrl-c through input instead of signal" {
    var original = std.mem.zeroes(std.posix.termios);
    original.lflag.ECHO = true;
    original.lflag.ICANON = true;
    original.lflag.IEXTEN = true;
    original.lflag.ISIG = true;
    original.iflag.BRKINT = true;
    original.iflag.ICRNL = true;
    original.iflag.INPCK = true;
    original.iflag.ISTRIP = true;
    original.iflag.IXON = true;

    const raw = rawModeFrom(original);
    try std.testing.expect(!raw.lflag.ECHO);
    try std.testing.expect(!raw.lflag.ICANON);
    try std.testing.expect(!raw.lflag.IEXTEN);
    try std.testing.expect(!raw.lflag.ISIG);
    try std.testing.expect(!raw.iflag.BRKINT);
    try std.testing.expect(!raw.iflag.ICRNL);
    try std.testing.expectEqual(@as(u8, 0), raw.cc[@intFromEnum(std.c.V.MIN)]);
    try std.testing.expectEqual(@as(u8, 1), raw.cc[@intFromEnum(std.c.V.TIME)]);
}

test "terminal cleanup sequence exits alternate screen then clears visible terminal" {
    try std.testing.expect(std.mem.indexOf(u8, enter_alternate_screen_sequence, "\x1b[?1049h") != null);
    try std.testing.expect(std.mem.indexOf(u8, enter_alternate_screen_sequence, "\x1b[?25l") != null);
    const exit_index = std.mem.indexOf(u8, exit_and_clear_terminal_sequence, "\x1b[?1049l") orelse return error.TestUnexpectedResult;
    const clear_index = std.mem.lastIndexOf(u8, exit_and_clear_terminal_sequence, "\x1b[2J") orelse return error.TestUnexpectedResult;
    const home_index = std.mem.lastIndexOf(u8, exit_and_clear_terminal_sequence, "\x1b[H") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, exit_and_clear_terminal_sequence, "\x1b[?25h") != null);
    try std.testing.expect(exit_index < clear_index);
    try std.testing.expect(clear_index < home_index);
}

test "ctrl-c byte is parsed as an input character for action dispatch" {
    const event = parseEvent(&.{3});
    try std.testing.expectEqual(Event{ .char = 3 }, event);
}
