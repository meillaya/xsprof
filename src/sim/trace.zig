const types = @import("types.zig");

pub const public_event_kinds = [_]types.TraceEventKind{
    .arrival,
    .dispatch,
    .tick,
    .preempt,
    .block,
    .wakeup,
    .complete,
    .idle,
};

pub fn eventLabel(kind: types.TraceEventKind) []const u8 {
    return switch (kind) {
        .arrival => "arrival",
        .dispatch => "dispatch",
        .tick => "tick",
        .preempt => "preempt",
        .block => "block",
        .wakeup => "wakeup",
        .complete => "complete",
        .idle => "idle",
    };
}
