//! Standalone test root for the experimental sampling-stack lane.
//!
//! `qa/stack_smoke.sh` runs this file directly (`./tools/zig test
//! src/stacks_test.zig`) in its deterministic analysis mode, before the Lead
//! wires the `export` verb into the command registry. The same modules are
//! also imported from `src/root.zig`, so their tests run under
//! `./tools/zig build test` as well.

const event = @import("core/event.zig");
const loss = @import("core/loss.zig");
const metrics = @import("analyze/metrics.zig");
const metrics_json = @import("analyze/metrics_json.zig");
const maps = @import("os/linux/maps.zig");
const journal = @import("stream/journal.zig");
const folded = @import("viz/folded.zig");
const perf_script = @import("viz/perf_script.zig");
const sample = @import("capture/sample.zig");
const symbols = @import("analyze/symbols.zig");
const export_cmd = @import("cli/export_cmd.zig");

test {
    _ = event;
    _ = loss;
    _ = metrics;
    _ = metrics_json;
    _ = maps;
    _ = journal;
    _ = folded;
    _ = perf_script;
    _ = sample;
    _ = symbols;
    _ = export_cmd;
}
