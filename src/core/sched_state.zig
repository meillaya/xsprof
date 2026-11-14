//! Bounded decode of `sched_switch` `prev_state` values.
//!
//! Perf records the outgoing task's `task_struct.__state` in the third packed
//! field of a switch row. That value is a bitmask, not an enum: a small primary
//! state (`TASK_RUNNING`, `TASK_INTERRUPTIBLE`, `TASK_UNINTERRUPTIBLE`, ...) is
//! optionally OR-ed with wait modifiers (`TASK_WAKEKILL`, `TASK_WAKING`,
//! `TASK_NOLOAD`, `TASK_RTLOCK_WAIT`, freeze bits). Bit values are kernel ABI
//! (include/linux/sched.h) and have been stable for the supported kernels.
//!
//! The decoder never guesses. Bits outside `known_mask` decode to `unknown` and
//! are rendered as `unknown:0x...`; a known-but-not-primary modifier decodes to
//! `other`. Aggregation keys (`Cause`) are a separate bounded set so a report
//! can say "off-CPU because the task was sleeping" without inventing a state
//! the kernel never reported. The canonical JSON writers iterate `Cause` in
//! declaration order and the fields are declared in ascending name order, so
//! the emitted object keys are canonical without an extra sort.

const std = @import("std");

// Primary states (include/linux/sched.h).
pub const task_running: u64 = 0x0000;
pub const task_interruptible: u64 = 0x0001;
pub const task_uninterruptible: u64 = 0x0002;
pub const task_stopped: u64 = 0x0004;
pub const task_traced: u64 = 0x0008;
pub const exit_dead: u64 = 0x0010;
pub const exit_zombie: u64 = 0x0020;
// Wait modifiers.
pub const task_parked: u64 = 0x0040;
pub const task_dead: u64 = 0x0080;
pub const task_wakekill: u64 = 0x0100;
pub const task_waking: u64 = 0x0200;
pub const task_noload: u64 = 0x0400;
pub const task_new: u64 = 0x0800;
pub const task_rtlock_wait: u64 = 0x1000;
pub const task_freezable: u64 = 0x2000;
pub const task_freezable_unsafe: u64 = 0x4000;
pub const task_frozen: u64 = 0x8000;

/// Every state/modifier bit the decoder understands. Anything outside this
/// mask is reported as unknown rather than folded into a neighbouring state.
pub const known_mask: u64 = 0xffff;

/// Bounded display label. `unknown` is rendered with the raw bits by
/// `labelText`; the other tags are stable wire/debug strings.
pub const Label = enum {
    running,
    interruptible,
    uninterruptible,
    stopped,
    traced,
    dead,
    zombie,
    parked,
    idle,
    wakekill,
    waking,
    new,
    rtlock_wait,
    freezable,
    frozen,
    other,
    unknown,
};

/// Bounded aggregation key: why a task was off-CPU. Names are lower-case and
/// declared in ascending order so canonical writers can emit object keys by
/// iterating the enum. `preempted` covers `prev_state == TASK_RUNNING` (the task
/// was involuntarily switched out); it is tracked by the preemption histogram,
/// not by the blocked-sleep cause totals.
pub const Cause = enum(u8) {
    dead,
    idle,
    interruptible,
    other,
    parked,
    preempted,
    stopped,
    traced,
    uninterruptible,
    unknown,
    zombie,
};

pub const cause_count = @typeInfo(Cause).@"enum".field_names.len;

pub fn causeName(cause: Cause) []const u8 {
    return @tagName(cause);
}

/// Decode a raw `prev_state` bitmask into the bounded label set.
pub fn classify(state: u64) Label {
    if (state & ~known_mask != 0) return .unknown;
    if (state == task_running) return .running;
    // TASK_IDLE is TASK_UNINTERRUPTIBLE|TASK_NOLOAD; idle must win so idle time
    // is not reported as unreclaimable sleep.
    if (state & task_noload != 0) return .idle;
    if (state & task_uninterruptible != 0) return .uninterruptible;
    if (state & task_interruptible != 0) return .interruptible;
    if (state & task_stopped != 0) return .stopped;
    if (state & task_traced != 0) return .traced;
    if (state & exit_zombie != 0) return .zombie;
    if (state & (exit_dead | task_dead) != 0) return .dead;
    if (state & task_parked != 0) return .parked;
    if (state & task_wakekill != 0) return .wakekill;
    if (state & task_waking != 0) return .waking;
    if (state & task_new != 0) return .new;
    if (state & task_rtlock_wait != 0) return .rtlock_wait;
    if (state & task_frozen != 0) return .frozen;
    if (state & (task_freezable | task_freezable_unsafe) != 0) return .freezable;
    return .other;
}

/// Map a raw `prev_state` onto the bounded aggregation cause.
pub fn causeOf(state: u64) Cause {
    return switch (classify(state)) {
        .running => .preempted,
        .idle => .idle,
        .interruptible => .interruptible,
        .uninterruptible => .uninterruptible,
        .stopped => .stopped,
        .traced => .traced,
        .dead => .dead,
        .zombie => .zombie,
        .parked => .parked,
        .unknown => .unknown,
        else => .other,
    };
}

/// Render a bounded label into `buffer`. `unknown` includes the raw bits so a
/// reader can see exactly what the kernel reported; the buffer must hold at
/// least 24 bytes (`unknown:0x` plus 16 hex digits).
pub fn labelText(buffer: []u8, state: u64) []const u8 {
    return switch (classify(state)) {
        .unknown => std.fmt.bufPrint(buffer, "unknown:0x{x}", .{state}) catch "unknown",
        else => |label| @tagName(label),
    };
}

/// True when the value is a known primary blocked state (never running and
/// never a bare modifier). Used by the analyzer to distinguish a truthful
/// sleep attribution from `unknown`/`other` fallbacks.
pub fn isPrimarySleep(state: u64) bool {
    return switch (classify(state)) {
        .interruptible, .uninterruptible, .stopped, .traced, .dead, .zombie, .parked, .idle => true,
        else => false,
    };
}

test "primary states decode to bounded labels" {
    try std.testing.expectEqual(Label.running, classify(task_running));
    try std.testing.expectEqual(Label.interruptible, classify(task_interruptible));
    try std.testing.expectEqual(Label.uninterruptible, classify(task_uninterruptible));
    try std.testing.expectEqual(Label.stopped, classify(task_stopped));
    try std.testing.expectEqual(Label.traced, classify(task_traced));
    try std.testing.expectEqual(Label.dead, classify(exit_dead));
    try std.testing.expectEqual(Label.zombie, classify(exit_zombie));
    try std.testing.expectEqual(Label.dead, classify(task_dead));
}

test "modifiers and combinations stay honest" {
    // TASK_KILLABLE = TASK_UNINTERRUPTIBLE|TASK_WAKEKILL.
    try std.testing.expectEqual(Label.uninterruptible, classify(task_uninterruptible | task_wakekill));
    // TASK_IDLE = TASK_UNINTERRUPTIBLE|TASK_NOLOAD.
    try std.testing.expectEqual(Label.idle, classify(task_uninterruptible | task_noload));
    try std.testing.expectEqual(Label.idle, classify(task_noload));
    // EXIT_TRACE = EXIT_ZOMBIE|EXIT_DEAD: zombie is the useful label.
    try std.testing.expectEqual(Label.zombie, classify(exit_zombie | exit_dead));
    try std.testing.expectEqual(Label.wakekill, classify(task_wakekill));
    try std.testing.expectEqual(Label.waking, classify(task_waking));
    try std.testing.expectEqual(Label.parked, classify(task_parked));
    try std.testing.expectEqual(Label.rtlock_wait, classify(task_rtlock_wait));
    try std.testing.expectEqual(Label.frozen, classify(task_frozen));
    try std.testing.expectEqual(Label.freezable, classify(task_freezable));
    try std.testing.expectEqual(Label.freezable, classify(task_freezable_unsafe));
}

test "causes aggregate the task-spec set" {
    try std.testing.expectEqual(Cause.preempted, causeOf(task_running));
    try std.testing.expectEqual(Cause.interruptible, causeOf(task_interruptible));
    try std.testing.expectEqual(Cause.uninterruptible, causeOf(task_uninterruptible));
    try std.testing.expectEqual(Cause.stopped, causeOf(task_stopped));
    try std.testing.expectEqual(Cause.traced, causeOf(task_traced));
    try std.testing.expectEqual(Cause.dead, causeOf(exit_dead));
    try std.testing.expectEqual(Cause.zombie, causeOf(exit_zombie));
    try std.testing.expectEqual(Cause.idle, causeOf(task_noload));
    try std.testing.expectEqual(Cause.parked, causeOf(task_parked));
    try std.testing.expectEqual(Cause.other, causeOf(task_wakekill));
    try std.testing.expectEqual(Cause.unknown, causeOf(1 << 63));
    try std.testing.expectEqual(Cause.unknown, causeOf(0x10000));
    try std.testing.expectEqual(@as(usize, 11), cause_count);
}

test "unknown bits are never folded into a known state" {
    const state: u64 = 0x1_0000 | task_interruptible;
    try std.testing.expectEqual(Label.unknown, classify(state));
    try std.testing.expectEqual(Cause.unknown, causeOf(state));
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("unknown:0x10001", labelText(&buffer, state));
    try std.testing.expectEqualStrings("interruptible", labelText(&buffer, task_interruptible));
    try std.testing.expectEqualStrings("running", labelText(&buffer, 0));
    try std.testing.expectEqualStrings("unknown:0x8000000000000000", labelText(&buffer, 1 << 63));
}

test "primary sleep classification excludes running and modifiers" {
    try std.testing.expect(!isPrimarySleep(task_running));
    try std.testing.expect(!isPrimarySleep(task_wakekill));
    try std.testing.expect(isPrimarySleep(task_interruptible));
    try std.testing.expect(isPrimarySleep(task_uninterruptible));
    try std.testing.expect(isPrimarySleep(task_noload));
}

test "cause names are ascending for canonical writers" {
    var previous: ?[]const u8 = null;
    inline for (@typeInfo(Cause).@"enum".field_names) |name| {
        if (previous) |prior| {
            try std.testing.expect(std.mem.order(u8, prior, name) == .lt);
        }
        previous = name;
    }
}
