const std = @import("std");
const action = @import("action.zig");
const state = @import("state.zig");
const session_mod = @import("../../stream/session.zig");

const LabState = state.LabState;
const SourcePhase = state.SourcePhase;
const CapturePhase = state.CapturePhase;
const ToastKind = state.ToastKind;
const max_path = state.max_path;

test "lab reducer opens sources and tracks capture lifecycle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const session = try session_mod.Session.load(
        std.testing.io,
        arena.allocator(),
        "fixtures/ui/healthy.ndjson",
    );
    var lab = try LabState.init(std.testing.allocator);
    defer lab.deinit();

    var batch = try lab.apply(.{ .intent = .{ .open_source = .{
        .kind = .replay,
        .path = "fixtures/ui/healthy.ndjson",
    } } });
    try std.testing.expectEqual(@as(u8, 1), batch.len);
    try std.testing.expectEqual(SourcePhase.loading, lab.source.phase);

    _ = try lab.apply(.{ .completion = .{ .source_ready = .{ .session = &session } } });
    try std.testing.expectEqual(SourcePhase.ready, lab.source.phase);
    try std.testing.expect(lab.view.session == &session);

    batch = try lab.apply(.{ .intent = .{ .start_capture = .{
        .duration_ms = 500,
        .preset = .scheduler,
    } } });
    try std.testing.expectEqual(CapturePhase.starting, lab.capture.phase);
    try std.testing.expectEqual(@as(u8, 1), batch.len);
    _ = try lab.apply(.{ .completion = .capture_started });
    _ = try lab.apply(.{ .completion = .{ .capture_progress = .{
        .events = 10,
        .lost = 2,
        .cpu_bp = 100,
        .rss_kb = 2048,
    } } });
    try std.testing.expectEqual(@as(u64, 10), lab.capture.events);
    _ = try lab.apply(.{ .completion = .{ .capture_finished = .{
        .outcome = .stopped,
        .events = 10,
        .lost = 2,
        .reason = "recording stopped",
    } } });
    try std.testing.expectEqual(CapturePhase.idle, lab.capture.phase);

    _ = try lab.apply(.{ .intent = .close_source });
    try std.testing.expect(lab.view.session == lab.empty_session);
}

test "lab reducer refuses a second capture and long paths" {
    var lab = try LabState.init(std.testing.allocator);
    defer lab.deinit();
    _ = try lab.apply(.{ .intent = .{ .start_capture = .{
        .duration_ms = 100,
        .preset = .deep,
    } } });
    _ = try lab.apply(.{ .completion = .capture_started });
    const batch = try lab.apply(.{ .intent = .{ .start_capture = .{
        .duration_ms = 100,
        .preset = .scheduler,
    } } });
    try std.testing.expectEqual(@as(u8, 0), batch.len);
    try std.testing.expectEqual(ToastKind.toast_error, lab.toast_kind);

    var long_path: [max_path + 1]u8 = @splat('x');
    const failed = try lab.apply(.{ .intent = .{ .open_source = .{
        .kind = .replay,
        .path = &long_path,
    } } });
    try std.testing.expectEqual(@as(u8, 0), failed.len);
    try std.testing.expectEqual(SourcePhase.failed, lab.source.phase);
}

test "transport advances and fits the timeline window" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const session = try session_mod.Session.load(
        std.testing.io,
        arena.allocator(),
        "fixtures/ui/healthy.ndjson",
    );
    var lab = try LabState.init(std.testing.allocator);
    defer lab.deinit();
    _ = try lab.apply(.{ .completion = .{ .source_ready = .{ .session = &session } } });
    _ = try lab.apply(.{ .intent = .{ .transport = .play } });
    lab.advance(50_000);
    try std.testing.expect(lab.view.window != null);
    try std.testing.expect(lab.transport.cursor_us > session.first_us);
    _ = try lab.apply(.{ .intent = .{ .transport = .fit } });
    try std.testing.expect(lab.view.window == null);
}

test "filter intent selects a real switch comm" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const session = try session_mod.Session.load(
        std.testing.io,
        arena.allocator(),
        "fixtures/ui/healthy.ndjson",
    );
    var lab = try LabState.init(std.testing.allocator);
    defer lab.deinit();
    _ = try lab.apply(.{ .completion = .{ .source_ready = .{ .session = &session } } });
    _ = try lab.apply(.{ .intent = .{ .filter_comm = "worker-c" } });
    try std.testing.expect(lab.view.filter.comm != null);
    var matches: usize = 0;
    for (session.slices) |slice| {
        if (lab.view.filter.matchesSlice(slice)) matches += 1;
    }
    try std.testing.expect(matches > 0);
}

test "path editing submits a source intent" {
    var lab = try LabState.init(std.testing.allocator);
    defer lab.deinit();
    _ = try lab.apply(.{ .intent = .{ .focus_input = .source_path } });
    try std.testing.expectEqual(action.InputField.source_path, lab.input_focus);
    _ = try lab.apply(.{ .intent = .{ .text_input = .{
        .field = .source_path,
        .text = "fixtures/ui/empty.ndjson",
    } } });
    try std.testing.expectEqualStrings("fixtures/ui/empty.ndjson", lab.sourceInputSlice());
    _ = try lab.apply(.{ .intent = .{ .backspace_input = .source_path } });
    try std.testing.expectEqualStrings("fixtures/ui/empty.ndjso", lab.sourceInputSlice());
    const batch = try lab.apply(.{ .intent = .{ .submit_input = .source_path } });
    try std.testing.expectEqual(@as(u8, 1), batch.len);
    try std.testing.expectEqual(SourcePhase.loading, lab.source.phase);
}

test "compare A tracks a completion and clears" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const session = try session_mod.Session.load(
        std.testing.io,
        arena.allocator(),
        "fixtures/ui/healthy.ndjson",
    );
    var lab = try LabState.init(std.testing.allocator);
    defer lab.deinit();
    _ = try lab.apply(.{ .intent = .{ .open_source = .{
        .kind = .replay,
        .path = "fixtures/ui/healthy.ndjson",
    } } });
    _ = try lab.apply(.{ .completion = .{ .source_ready = .{ .session = &session } } });
    const batch = try lab.apply(.{ .intent = .set_compare });
    try std.testing.expectEqual(@as(u8, 1), batch.len);
    try std.testing.expectEqual(action.ComparePhase.loading, lab.compare.phase);
    _ = try lab.apply(.{ .completion = .{ .compare_ready = .{ .session = &session } } });
    try std.testing.expect(lab.compare.session == &session);
    _ = try lab.apply(.{ .intent = .clear_compare });
    try std.testing.expect(lab.compare.session == null);
}
