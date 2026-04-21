const types = @import("types.zig");

pub const public_event_kinds = [_]types.TraceEventKind{
    .arrival,
    .dispatch,
    .tick,
    .preempt,
    .complete,
    .idle,
};

pub fn eventLabel(kind: types.TraceEventKind) []const u8 {
    return switch (kind) {
        .arrival => "arrival",
        .dispatch => "dispatch",
        .tick => "tick",
        .preempt => "preempt",
        .complete => "complete",
        .idle => "idle",
    };
}
