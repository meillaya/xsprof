//! File exports for the platform effect executor: journal NDJSON, Chrome trace,
//! metrics report, and the UI audit log. Path policy lives in state_paths; this
//! module writes only an already-validated directory and never mutates host
//! policy. Incident bundles are explicitly not wired (stable refusal reason).

const std = @import("std");
const event_mod = @import("../core/event.zig");
const chrome_trace = @import("../viz/chrome_trace.zig");
const metrics_json = @import("../analyze/metrics_json.zig");
const audit_mod = @import("../app/design/audit.zig");
const effect = @import("../app/design/effect.zig");
const session_mod = @import("../stream/session.zig");
const state_paths = @import("state_paths.zig");

pub const Failure = struct {
    code: []const u8,
    reason: []const u8,
};

pub const ExportError = error{
    NoSession,
    IncidentUnavailable,
    UnsafeExportPath,
    CreateFailed,
    WriteFailed,
};

pub fn failFor(err: anyerror) Failure {
    return switch (err) {
        error.NoSession => .{
            .code = "export.no_session",
            .reason = "nothing is loaded to export; open a replay or recorder window first",
        },
        error.IncidentUnavailable => .{
            .code = "export.incident.unavailable",
            .reason = "incident bundle export is not wired on this surface",
        },
        error.UnsafeExportPath => .{
            .code = "export.unsafe_path",
            .reason = "export path must stay under the state/output directory",
        },
        error.CreateFailed => .{
            .code = "export.create_failed",
            .reason = "could not create the export file",
        },
        error.WriteFailed => .{
            .code = "export.write_failed",
            .reason = "could not write the export file",
        },
        else => .{
            .code = "export.failed",
            .reason = "export could not be written",
        },
    };
}

/// Writes one bounded export into `dir` and returns the created file name.
pub fn writeExport(
    io: std.Io,
    allocator: std.mem.Allocator,
    dir: []const u8,
    kind: effect.ExportKind,
    session: ?*const session_mod.Session,
) anyerror![]u8 {
    if (kind == .incident) return error.IncidentUnavailable;
    const loaded = session orelse return error.NoSession;
    const name = try allocator.dupe(u8, kind.label());
    errdefer allocator.free(name);
    const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, name });
    defer allocator.free(full);
    state_paths.ensureParentDir(io, full) catch return error.CreateFailed;
    const file = state_paths.createOutputFile(io, full) catch return error.CreateFailed;
    var buffer: [64 * 1024]u8 = undefined;
    var writer = file.writer(io, &buffer);
    errdefer file.close(io);
    writeBody(&writer.interface, allocator, kind, loaded) catch {
        file.close(io);
        return error.WriteFailed;
    };
    writer.interface.flush() catch {
        file.close(io);
        return error.WriteFailed;
    };
    file.close(io);
    return name;
}

fn writeBody(
    w: *std.Io.Writer,
    allocator: std.mem.Allocator,
    kind: effect.ExportKind,
    session: *const session_mod.Session,
) !void {
    switch (kind) {
        .journal => {
            for (session.events) |entry| {
                try event_mod.writeJson(w, entry);
                try w.writeByte('\n');
            }
        },
        .trace => try chrome_trace.writeTimeline(w, allocator, session.events, null, null),
        .report => {
            try metrics_json.writeJson(w, session.metrics, 64);
            try w.writeByte('\n');
        },
        .incident => unreachable,
    }
}

/// Writes the bounded UI audit ring as canonical NDJSON under the state dir.
pub fn writeAudit(io: std.Io, allocator: std.mem.Allocator, ring: *const audit_mod.Ring) anyerror![]u8 {
    const dir = state_paths.exportsDir(allocator) catch return error.CreateFailed;
    defer allocator.free(dir);
    std.Io.Dir.cwd().createDirPath(io, dir) catch return error.CreateFailed;
    const full = std.fmt.allocPrint(allocator, "{s}/audit.ndjson", .{dir}) catch return error.CreateFailed;
    defer allocator.free(full);
    const file = state_paths.createOutputFile(io, full) catch return error.CreateFailed;
    var buffer: [16 * 1024]u8 = undefined;
    var writer = file.writer(io, &buffer);
    errdefer file.close(io);
    var index: usize = 0;
    while (index < ring.len) : (index += 1) {
        const entry = ring.at(index) orelse continue;
        audit_mod.writeJsonLine(&writer.interface, entry) catch {
            file.close(io);
            return error.WriteFailed;
        };
    }
    writer.interface.flush() catch {
        file.close(io);
        return error.WriteFailed;
    };
    file.close(io);
    return allocator.dupe(u8, "audit.ndjson");
}

test "chart export kinds keep stable failure reasons" {
    try std.testing.expectEqualStrings("export.incident.unavailable", failFor(error.IncidentUnavailable).code);
    try std.testing.expectEqualStrings("export.unsafe_path", failFor(error.UnsafeExportPath).code);
    try std.testing.expectEqualStrings("journal.ndjson", effect.ExportKind.journal.label());
}
