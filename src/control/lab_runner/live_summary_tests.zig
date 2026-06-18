const std = @import("std");
const live_summary = @import("live_summary.zig");

const appendLiveSummaryEvents = live_summary.appendLiveSummaryEvents;
const runnerFailureReason = live_summary.runnerFailureReason;

test "live microvm summary emits UI lifecycle events from accepted bundle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    const root = try testingTmpRelPath(std.testing.allocator, tmp, ".");
    defer std.testing.allocator.free(root);
    const summary_path = try writeTestingLiveBundle(std.testing.allocator, &tmp.dir, root, .{});
    defer std.testing.allocator.free(summary_path);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    var seq: usize = 1;
    try appendLiveSummaryEvents(std.testing.allocator, io, &output, &seq, summary_path, "git-ok");

    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"event\":\"microvm_boot\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"event\":\"vm_marker\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"event\":\"bpf_register\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"event\":\"runtime_sample\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"event\":\"rollback\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"event\":\"cleanup\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"event\":\"validation\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"host_mutation\":false") != null);
}

test "live microvm summary rejects stale and malformed bundles" {
    var stale_tmp = std.testing.tmpDir(.{});
    defer stale_tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    const stale_root = try testingTmpRelPath(std.testing.allocator, stale_tmp, ".");
    defer std.testing.allocator.free(stale_root);
    const stale_summary_path = try writeTestingLiveBundle(std.testing.allocator, &stale_tmp.dir, stale_root, .{ .git_sha = "old-git" });
    defer std.testing.allocator.free(stale_summary_path);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    var seq: usize = 1;
    try std.testing.expectError(error.InvalidSummary, appendLiveSummaryEvents(std.testing.allocator, io, &output, &seq, stale_summary_path, "git-ok"));

    var malformed_tmp = std.testing.tmpDir(.{});
    defer malformed_tmp.cleanup();
    try malformed_tmp.dir.writeFile(io, .{ .sub_path = "summary.json", .data = "{not-json" });
    const malformed_path = try testingTmpRelPath(std.testing.allocator, malformed_tmp, "summary.json");
    defer std.testing.allocator.free(malformed_path);
    try std.testing.expectError(error.InvalidSummary, appendLiveSummaryEvents(std.testing.allocator, io, &output, &seq, malformed_path, "git-ok"));
}

test "live microvm malformed stage emits no PASS lifecycle events" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    const root = try testingTmpRelPath(std.testing.allocator, tmp, ".");
    defer std.testing.allocator.free(root);
    const summary_path = try writeTestingLiveBundle(std.testing.allocator, &tmp.dir, root, .{ .stage_status = "completed" });
    defer std.testing.allocator.free(summary_path);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    var seq: usize = 1;
    try std.testing.expectError(error.InvalidSummary, appendLiveSummaryEvents(std.testing.allocator, io, &output, &seq, summary_path, "git-ok"));
    try std.testing.expectEqual(@as(usize, 0), output.items.len);
    try std.testing.expectEqual(@as(usize, 1), seq);
}

test "live microvm runner failure classification is explicit" {
    try std.testing.expectEqualStrings("qemu_not_found", runnerFailureReason("FAIL: qemu-system-x86_64 not found; install qemu"));
    try std.testing.expectEqualStrings("kvm_unavailable", runnerFailureReason("FAIL: /dev/kvm is required for the microVM live lab"));
    try std.testing.expectEqualStrings("kernel_unavailable", runnerFailureReason("FAIL: readable kernel image not found"));
    try std.testing.expectEqualStrings("nix_busybox_unavailable", runnerFailureReason("FAIL: could not build/fetch pkgsStatic.busybox through nix"));
    try std.testing.expectEqualStrings("microvm_runner_refused", runnerFailureReason("FAIL: unexpected"));
}

const TestingBundleOptions = struct {
    git_sha: []const u8 = "git-ok",
    stage_status: []const u8 = "PASS",
};

fn writeTestingLiveBundle(
    allocator: std.mem.Allocator,
    dir: *std.Io.Dir,
    root: []const u8,
    options: TestingBundleOptions,
) ![]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const runtime_path = try std.fmt.allocPrint(allocator, "{s}/runtime-samples.jsonl", .{root});
    defer allocator.free(runtime_path);
    const daemon_path = try std.fmt.allocPrint(allocator, "{s}/daemon-runtime-events.jsonl", .{root});
    defer allocator.free(daemon_path);
    const partial_path = try std.fmt.allocPrint(allocator, "{s}/partial-attach-evidence.json", .{root});
    defer allocator.free(partial_path);
    try dir.writeFile(io, .{ .sub_path = "runtime-samples.jsonl", .data =
        \\{"schema":"zig-scheduler/runtime-sample/v1","sequence":0,"ops":{"status":"present","value":"none"},"private_command_lines_sampled":false,"workload_alive":true}
        \\{"schema":"zig-scheduler/runtime-sample/v1","sequence":1,"ops":{"status":"present","value":"zigsched_minimal"},"private_command_lines_sampled":false,"workload_alive":true}
        \\{"schema":"zig-scheduler/runtime-sample/v1","sequence":2,"ops":{"status":"present","value":"none"},"private_command_lines_sampled":false,"workload_alive":true}
        \\
    });
    try dir.writeFile(io, .{ .sub_path = "daemon-runtime-events.jsonl", .data =
        \\{"schema":"zig-scheduler/daemon-event/v1","event":"runtime_sample","ops":"zigsched_minimal","host_mutation":false}
        \\
    });
    try dir.writeFile(io, .{ .sub_path = "partial-attach-evidence.json", .data = "{}\n" });

    const summary = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "schema": "zig-scheduler/run-all-lab/v1",
        \\  "status": "PASS",
        \\  "evidence_mode": "vm-live",
        \\  "git_sha": "{s}",
        \\  "git_dirty": false,
        \\  "bpf_object_sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        \\  "output_dir": "{s}",
        \\  "output_dir_created_fresh": true,
        \\  "host_mutation": false,
        \\  "vm_kind": "qemu-vm",
        \\  "vm_marker_present": true,
        \\  "vm_marker_path": "/run/zig-scheduler-vm-lab.marker",
        \\  "rollback_result": "PASS",
        \\  "artifact_paths": ["{s}", "{s}", "{s}"],
        \\  "cleanup": {{
        \\    "qemu_leftovers": false,
        \\    "tmux_leftovers": false,
        \\    "process_group_reaped": true,
        \\    "temp_dirs_removed": true
        \\  }},
        \\  "stages": [
        \\    {{"stage":"partial_attach","status":"{s}","reason":"attached in VM guest","artifact":"{s}"}}
        \\  ]
        \\}}
        \\
    , .{ options.git_sha, root, runtime_path, daemon_path, partial_path, options.stage_status, partial_path });
    defer allocator.free(summary);
    try dir.writeFile(io, .{ .sub_path = "summary.json", .data = summary });
    return std.fmt.allocPrint(allocator, "{s}/summary.json", .{root});
}

fn testingTmpRelPath(allocator: std.mem.Allocator, tmp: std.testing.TmpDir, sub_path: []const u8) ![]u8 {
    if (std.mem.eql(u8, sub_path, "."))
        return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/{s}", .{ &tmp.sub_path, sub_path });
}
