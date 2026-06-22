const std = @import("std");
const args = @import("args.zig");
const live_controller = @import("live_controller.zig");
const real_lab_evidence = @import("real_lab_evidence.zig");

const Options = args.Options;

pub fn write(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, out: *std.Io.Writer, options: Options, method: []const u8) !bool {
    if (std.mem.eql(u8, method, "real-lab-preflight")) {
        try writePreflight(allocator, io, environ, out, options);
        return true;
    }
    if (std.mem.eql(u8, method, "real-lab-run")) {
        try writeRun(allocator, io, environ, out, options);
        return true;
    }
    return false;
}

fn writePreflight(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, out: *std.Io.Writer, options: Options) !void {
    var preflight = try real_lab_evidence.Preflight.collect(allocator, io, environ, options.force_qemu_missing);
    defer preflight.deinit(allocator);
    const evidence_dir = preflight.artifactDir();
    try preflight.writeArtifact(allocator, io, evidence_dir);
    try out.print(
        "{s} bridge_test=real-lab-preflight outcome={s} qemu={s} kvm={s} btf={s} kernel={s} nix={s} host_mutation=false artifact={s}/{s}\n",
        .{
            if (preflight.capable) "PASS" else "SKIP",
            if (preflight.capable) "capable_lab_tuple" else "fail_closed_missing_lab_tuple",
            preflight.qemu_bin orelse "missing",
            if (preflight.kvm) "present" else "missing",
            if (preflight.btf) "present" else "missing",
            preflight.kernel_image orelse "missing",
            preflight.nix_bin orelse "missing",
            evidence_dir,
            preflight.artifactName(),
        },
    );
}

fn writeRun(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, out: *std.Io.Writer, options: Options) !void {
    if (options.fake_daemon or !std.mem.eql(u8, options.daemon_bin, "zig-out/bin/zig-scheduler-daemon")) {
        try out.writeAll("REFUSE bridge_test=real-lab-run reason=actual_zig_scheduler_daemon_required host_mutation=false\n");
        return;
    }
    var preflight = try real_lab_evidence.Preflight.collect(allocator, io, environ, options.force_qemu_missing);
    defer preflight.deinit(allocator);
    const evidence_dir = preflight.artifactDir();
    try preflight.writeArtifact(allocator, io, evidence_dir);
    if (!preflight.capable) {
        try out.print("SKIP bridge_test=real-lab-run reason=fail_closed_missing_lab_tuple artifact={s}/skip.json host_mutation=false\n", .{evidence_dir});
        return;
    }
    var controller = live_controller.Controller.init(allocator, .{
        .daemon_path = "zig-out/bin/zig-scheduler-daemon",
        .state_dir = options.state_dir,
        .stream_timeout_ms = 180_000,
    });
    defer controller.deinit();
    const run_status = try controller.run(io);
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, real_lab_evidence.real_vm_evidence_dir, .{});
    defer dir.close(io);
    try real_lab_evidence.writeHistoryFile(io, &dir, "events.jsonl", &controller);
    const real_pass = real_lab_evidence.realRunPassed(&controller);
    const rollback_status: []const u8 = if (real_lab_evidence.hasEventStatus(&controller, "rollback", "PASS")) "PASS" else "missing";
    try real_lab_evidence.writeRunReceipt(allocator, io, &dir, if (real_pass) "PASS" else @tagName(run_status), rollback_status, &controller);
    try out.print("bridge_test=real-lab-run controller_status={s} real_status={s} rollback_status={s} artifact={s}/run.json events={s}/events.jsonl host_mutation=false\n", .{
        @tagName(run_status),
        if (real_pass) "PASS" else "not_pass",
        rollback_status,
        real_lab_evidence.real_vm_evidence_dir,
        real_lab_evidence.real_vm_evidence_dir,
    });
    if (!real_pass) {
        try out.flush();
        std.process.exit(1);
    }
}
