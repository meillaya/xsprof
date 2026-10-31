//! Bounded user intents, async completions, and effects for the GUI lab.
//! The reducer that consumes these lives in `state.zig`.

const std = @import("std");
const app_state = @import("../app_state.zig");
const session_mod = @import("../../stream/session.zig");

pub const SourceKind = enum { replay, recorder, scenario, live };

pub const CapturePreset = enum { scheduler, memory, deep };

pub const LabPanel = enum { source, capture, transport, scenarios, inspector, exports };

pub const Focus = enum { screen, rail, palette, text_field };

pub const InputField = enum { none, source_path, export_path };

pub const ExportKind = enum { trace, report, snapshot, run_json };

pub const TransportIntent = enum {
    play,
    pause,
    step_forward,
    step_back,
    fit,
    follow_on,
    follow_off,
};

pub const CaptureOutcome = enum { stopped, failed, refused, skipped };

pub const ComparePhase = enum { none, loading, ready, failed };

pub const Intent = union(enum) {
    screen: app_state.Screen,
    toggle_rail,
    panel: LabPanel,
    palette_open,
    palette_close,
    open_source: struct { kind: SourceKind, path: []const u8 },
    close_source,
    start_capture: struct { duration_ms: u32, preset: CapturePreset },
    stop_capture,
    transport: TransportIntent,
    filter_comm: []const u8,
    select_pid: i32,
    set_compare,
    clear_compare,
    focus_input: InputField,
    text_input: struct { field: InputField, text: []const u8 },
    backspace_input: InputField,
    submit_input: InputField,
    cancel_input,
    exports: struct { kind: ExportKind, path: []const u8 },
    quit,
    dismiss_error,
};

pub const Completion = union(enum) {
    source_ready: struct { session: *const session_mod.Session },
    source_failed: struct { reason: []const u8 },
    compare_ready: struct { session: *const session_mod.Session },
    compare_failed: struct { reason: []const u8 },
    capture_started,
    capture_progress: struct {
        events: u64,
        lost: u64,
        cpu_bp: u32,
        rss_kb: u64,
    },
    capture_finished: struct {
        outcome: CaptureOutcome,
        events: u64,
        lost: u64,
        reason: []const u8,
    },
    export_done: struct { kind: ExportKind, path: []const u8 },
    export_failed: struct { kind: ExportKind, reason: []const u8 },
    capture_worker_missing,
};

pub const Msg = union(enum) {
    intent: Intent,
    completion: Completion,
};

pub const Effect = union(enum) {
    none,
    load_source: struct { kind: SourceKind, path: []const u8 },
    load_compare: struct { kind: SourceKind, path: []const u8 },
    clear_compare,
    start_capture: struct { duration_ms: u32, preset: CapturePreset },
    stop_capture,
    exports: struct { kind: ExportKind, path: []const u8 },
    open_loopback,
};

pub const max_effects = 8;

pub const EffectBatch = struct {
    items: [max_effects]Effect = @splat(.none),
    len: u8 = 0,
    overflow: bool = false,

    pub fn add(self: *EffectBatch, effect: Effect) void {
        if (self.len >= max_effects) {
            self.overflow = true;
            return;
        }
        self.items[self.len] = effect;
        self.len += 1;
    }

    pub fn slice(self: *const EffectBatch) []const Effect {
        return self.items[0..self.len];
    }
};

test "effect batches are bounded" {
    var batch = EffectBatch{};
    var index: usize = 0;
    while (index < max_effects + 2) : (index += 1) batch.add(.open_loopback);
    try std.testing.expectEqual(@as(u8, max_effects), batch.len);
    try std.testing.expect(batch.overflow);
}
