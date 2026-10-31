//! xsprof — read-only Linux scheduler and memory profiler.
//!
//! The root module intentionally contains no UI code. Capture, platform, and
//! UI layers are imported by consumers that need them.

pub const json = @import("core/json.zig");
pub const version = @import("core/version.zig");
pub const event = @import("core/event.zig");
pub const privacy = @import("core/privacy.zig");
pub const safety = @import("core/safety.zig");
pub const proc = @import("os/linux/proc.zig");
pub const pressure = @import("os/linux/pressure.zig");
pub const cgroup = @import("os/linux/cgroup.zig");
pub const overhead = @import("os/linux/overhead.zig");
pub const aggregates = @import("analyze/aggregates.zig");
pub const metrics = @import("analyze/metrics.zig");
pub const compare = @import("analyze/compare.zig");
pub const advisor = @import("analyze/advisor.zig");
pub const journal = @import("stream/journal.zig");
pub const stream_store = @import("stream/store.zig");
pub const stream_index = @import("stream/index.zig");
pub const chrome_trace = @import("viz/chrome_trace.zig");
pub const session = @import("stream/session.zig");
pub const serve = @import("serve/server.zig");
pub const live = @import("capture/live.zig");
pub const capture_lab_worker = @import("capture/lab_worker.zig");
pub const stream_live_feed = @import("stream/live_feed.zig");
pub const recording = @import("capture/recording.zig");
pub const recorder_manifest = @import("recorder/manifest.zig");
pub const recorder_segment = @import("recorder/segment.zig");
pub const recorder_daemon = @import("recorder/daemon.zig");
pub const recorder_extract = @import("recorder/extract.zig");
pub const recorder_sidecar = @import("recorder/sidecar.zig");
pub const recorder_doctor = @import("recorder/doctor.zig");
pub const bpf = @import("capture/bpf.zig");
pub const ttf = @import("ui/ttf.zig");
pub const ui_frame = @import("ui/frame.zig");
pub const ui_layout = @import("ui/layout.zig");
pub const ui_tester = @import("ui/tester.zig");
pub const ui_draw = @import("ui/draw.zig");
pub const ui_controls = @import("ui/controls.zig");
pub const ui_raster = @import("ui/raster.zig");
pub const demo = @import("app/demo.zig");
pub const gallery = @import("app/gallery.zig");
pub const app = @import("app/app.zig");
pub const app_test = @import("app/app_test.zig");
pub const lab_action = @import("app/lab/action.zig");
pub const lab_state = @import("app/lab/state.zig");
pub const lab_source = @import("app/lab/source.zig");
pub const cli = @import("cli/root.zig");

test {
    // Pull the declarations into the test compilation unit so their tests run.
    _ = json;
    _ = version;
    _ = event;
    _ = privacy;
    _ = safety;
    _ = proc;
    _ = pressure;
    _ = cgroup;
    _ = overhead;
    _ = aggregates;
    _ = metrics;
    _ = compare;
    _ = advisor;
    _ = journal;
    _ = chrome_trace;
    _ = session;
    _ = stream_store;
    _ = stream_index;
    _ = serve;
    _ = live;
    _ = capture_lab_worker;
    _ = stream_live_feed;
    _ = recording;
    _ = recorder_manifest;
    _ = recorder_segment;
    _ = recorder_daemon;
    _ = recorder_extract;
    _ = recorder_sidecar;
    _ = recorder_doctor;
    _ = ttf;
    _ = ui_frame;
    _ = ui_layout;
    _ = ui_tester;
    _ = demo;
    _ = gallery;
    _ = app;
    _ = app_test;
    _ = lab_action;
    _ = lab_state;
    _ = lab_source;
    _ = cli;
}
