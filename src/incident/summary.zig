//! Incident summary and offline HTML report. Both are generated from the same
//! extracted window, rule reports, and findings; the HTML has no scripts,
//! external assets, or network requests.

const std = @import("std");
const json = @import("../core/json.zig");
const loss = @import("../core/loss.zig");
const sched_state = @import("../core/sched_state.zig");
const session_mod = @import("../stream/session.zig");
const advisor = @import("../analyze/advisor.zig");
const latency = @import("../analyze/latency.zig");
const report = @import("../analyze/report.zig");
const rules = @import("../analyze/rules.zig");

const Writer = std.Io.Writer;
const Session = session_mod.Session;

pub const Artifacts = struct {
    report: []const u8,
    summary: []const u8,
    trace: []const u8,
    window: []const u8,
};

pub const Context = struct {
    source_dir: []const u8,
    requested_ms: u64,
    retained_ms: u64,
    events: usize,
    trace_events: usize,
    trace_truncated: bool,
    retention_trimmed: bool,
    artifacts: Artifacts,
};

fn durationText(buf: []u8, ms: u64) []const u8 {
    if (ms >= 60_000) {
        return std.fmt.bufPrint(buf, "{d:.1} m", .{@as(f64, @floatFromInt(ms)) / 60_000.0}) catch "?";
    }
    if (ms >= 1_000) {
        return std.fmt.bufPrint(buf, "{d:.2} s", .{@as(f64, @floatFromInt(ms)) / 1000.0}) catch "?";
    }
    return std.fmt.bufPrint(buf, "{d} ms", .{ms}) catch "?";
}

fn actualWindowMs(session: *const Session) u64 {
    return session.durationUs() / 1000;
}

fn counts(report_list: []const rules.Report, status: rules.Status) usize {
    var total: usize = 0;
    for (report_list) |item| {
        if (item.status == status) total += 1;
    }
    return total;
}

pub fn writeJson(
    w: *Writer,
    session: *const Session,
    findings: []const advisor.Finding,
    report_list: []const rules.Report,
    ctx: Context,
) Writer.Error!void {
    const duration_ms = actualWindowMs(session);
    const trimmed = ctx.requested_ms > ctx.retained_ms + 2_000 or ctx.retention_trimmed;
    const self_share: f64 = if (session.switches == 0)
        0
    else
        @as(f64, @floatFromInt(session.self_switches)) * 100.0 /
            @as(f64, @floatFromInt(session.switches));
    const agg = session.aggregate();

    try w.writeAll("{\"artifacts\":{\"report\":");
    try json.write(w, .{ .string = ctx.artifacts.report });
    try w.writeAll(",\"summary\":");
    try json.write(w, .{ .string = ctx.artifacts.summary });
    try w.writeAll(",\"trace\":");
    try json.write(w, .{ .string = ctx.artifacts.trace });
    try w.writeAll(",\"window\":");
    try json.write(w, .{ .string = ctx.artifacts.window });
    try w.writeAll("},\"capabilities\":[");
    for (session.capabilities, 0..) |cap, index| {
        if (index != 0) try w.writeByte(',');
        try w.writeAll("{\"name\":");
        try json.write(w, .{ .string = cap.name });
        try w.writeAll(",\"reason\":");
        try json.write(w, .{ .string = cap.reason });
        try w.writeAll(",\"state\":");
        try json.write(w, .{ .string = cap.state });
        try w.writeByte('}');
    }
    try w.print("],\"events\":{d},\"findings\":[", .{ctx.events});
    for (findings, 0..) |finding, index| {
        if (index != 0) try w.writeByte(',');
        try report.writeFinding(w, finding);
    }
    try w.writeAll("],\"host_mutation\":false,\"latency\":");
    try latency.writeJson(w, &session.metrics);
    try w.writeAll(",\"loss\":{\"lost\":");
    try json.write(w, .{ .unsigned = session.lost });
    try w.writeAll(",\"retention_trimmed\":");
    try json.write(w, .{ .boolean = trimmed });
    try w.writeAll("},\"loss_by_kind\":");
    try loss.writeJson(w, session.loss_by_kind);
    try w.print(",\"requested_ms\":{d},\"rules\":[", .{ctx.requested_ms});
    for (report_list, 0..) |item, index| {
        if (index != 0) try w.writeByte(',');
        try report.writeRule(w, item);
    }
    try w.writeAll("],\"schema\":\"xsprof/incident-summary/v1\",\"self\":{\"share\":");
    try json.write(w, .{ .float = self_share });
    try w.writeAll(",\"switches\":");
    try json.write(w, .{ .unsigned = session.self_switches });
    try w.writeAll("},\"signals\":{\"allocator\":");
    try json.write(w, .{ .boolean = agg.signals.allocator });
    try w.writeAll(",\"cpu_topology\":");
    try json.write(w, .{ .boolean = agg.signals.cpu_topology });
    try w.writeAll(",\"lock_contention\":");
    try json.write(w, .{ .boolean = agg.signals.lock_contention });
    try w.writeAll(",\"numa_fault\":");
    try json.write(w, .{ .boolean = agg.signals.numa_fault });
    try w.writeAll(",\"page_fault\":");
    try json.write(w, .{ .boolean = agg.signals.page_fault });
    try w.writeAll(",\"pmu_hitm\":");
    try json.write(w, .{ .boolean = agg.signals.pmu_hitm });
    try w.writeAll(",\"priority_inversion\":");
    try json.write(w, .{ .boolean = agg.signals.priority_inversion });
    try w.writeAll(",\"sched_migrate\":");
    try json.write(w, .{ .boolean = agg.signals.sched_migrate });
    try w.writeAll(",\"sched_switch\":");
    try json.write(w, .{ .boolean = agg.signals.sched_switch });
    try w.writeAll(",\"sched_wakeup\":");
    try json.write(w, .{ .boolean = agg.signals.sched_wakeup });
    try w.writeAll("},\"source\":{\"dir\":");
    try json.write(w, .{ .string = ctx.source_dir });
    try w.writeAll(",\"window\":");
    try json.write(w, .{ .string = ctx.artifacts.window });
    try w.writeAll("},\"tasks\":[");
    var task_index: usize = 0;
    for (session.metrics.tasks) |task| {
        if (task.is_self) continue;
        if (task_index == 8) break;
        if (task_index != 0) try w.writeByte(',');
        task_index += 1;
        try w.writeAll("{\"comm\":");
        try json.write(w, .{ .string = task.comm });
        try w.print(",\"migrations\":{d},\"pid\":{d},\"switches\":{d},\"wait_p95_us\":{d}", .{
            task.migrations,
            task.pid,
            task.switches,
            task.wait_p95_us,
        });
        try w.writeByte('}');
    }
    try w.print("],\"trace\":{{\"events\":{d},\"truncated\":", .{ctx.trace_events});
    try json.write(w, .{ .boolean = ctx.trace_truncated });
    try w.print("}},\"window\":{{\"duration_ms\":{d},\"first_us\":{d},\"last_us\":{d},\"retained_ms\":{d},\"trimmed\":", .{
        duration_ms,
        session.first_us,
        session.last_us,
        ctx.retained_ms,
    });
    try json.write(w, .{ .boolean = trimmed });
    try w.writeAll("}}\n");
}

fn escape(w: *Writer, text: []const u8) Writer.Error!void {
    for (text) |byte| {
        switch (byte) {
            '&' => try w.writeAll("&amp;"),
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            '"' => try w.writeAll("&quot;"),
            '\'' => try w.writeAll("&#39;"),
            else => try w.writeByte(byte),
        }
    }
}

fn statusClass(status: rules.Status) []const u8 {
    return switch (status) {
        .finding => "finding",
        .clear => "clear",
        .skip => "skip",
    };
}

fn statusLabel(status: rules.Status) []const u8 {
    return switch (status) {
        .finding => "FINDING",
        .clear => "CLEAR",
        .skip => "SKIP",
    };
}

fn sessionTaskComm(session: *const Session, pid: i32) []const u8 {
    for (session.metrics.tasks) |task| {
        if (task.pid == pid) return task.comm;
    }
    return "?";
}

/// Offline latency-attribution section: bounded tables, escaped names, and
/// explicit unresolved counters. No scripts, links, or external assets.
fn writeLatencyHtml(w: *Writer, session: *const Session) !void {
    const metrics = &session.metrics;
    try w.writeAll("<h2>Latency attribution</h2><p class=\"muted\">Why tasks were off-CPU (switch-out prev_state), involuntary preemptions, and the critical wakeup chains. Unknown and other are explicit categories, never zeroed.</p>");
    try w.writeAll("<table><thead><tr><th>Off-CPU cause</th><th>Samples</th><th>Total</th></tr></thead><tbody>");
    const cause_names = @typeInfo(sched_state.Cause).@"enum".field_names;
    var cause_rows: usize = 0;
    for (metrics.causes, 0..) |stat, index| {
        if (stat.count == 0) continue;
        cause_rows += 1;
        try w.writeAll("<tr><td>");
        try escape(w, cause_names[index]);
        try w.print("</td><td>{d}</td><td>{d} ms</td></tr>", .{ stat.count, stat.total_us / 1000 });
    }
    if (cause_rows == 0) {
        try w.writeAll("<tr><td colspan=\"3\" class=\"muted\">No blocked off-CPU samples in this window.</td></tr>");
    }
    try w.writeAll("</tbody></table>");

    try w.writeAll("<h3>Preemption</h3><p class=\"muted\">A preemption is a switch-out with prev_state=running whose next switch-in had no intervening wakeup. ");
    try w.print("preemptions={d} · p95={d} ms · unresolved={d}</p>", .{
        metrics.preemptions,
        metrics.preempt.quantileUpper(950) / 1000,
        metrics.preempt_unresolved,
    });

    try w.writeAll("<h3>Critical chains</h3>");
    const chain_count: usize = metrics.chain_count;
    if (chain_count == 0) {
        try w.writeAll("<p class=\"muted\">No wakeup chains in this window.</p>");
    } else {
        try w.writeAll("<table><thead><tr><th>Root</th><th>Leaf</th><th>Depth</th><th>Edges</th><th>Total wait</th><th>p95</th></tr></thead><tbody>");
        for (metrics.chains[0..chain_count]) |chain| {
            try w.writeAll("<tr><td>");
            try escape(w, sessionTaskComm(session, chain.root_pid));
            try w.print(":{d}</td><td>", .{chain.root_pid});
            try escape(w, chain.leaf_comm);
            try w.print(":{d}</td><td>{d}</td><td>{d}</td><td>{d} ms</td><td>{d} ms</td></tr>", .{
                chain.leaf_pid,
                chain.depth,
                chain.count,
                chain.total_wait_us / 1000,
                chain.p95_wait_us / 1000,
            });
        }
        try w.writeAll("</tbody></table>");
    }
    try w.print("<p class=\"muted\">offcpu_samples={d} · offcpu_unresolved={d} · chain_edges={d} · chain_roots={d} · cycles_cut={d} · depth_cut={d}{s}</p>", .{
        metrics.offcpu_samples,
        metrics.offcpu_unresolved,
        metrics.chain_edges,
        metrics.chain_roots,
        metrics.chain_cycles_cut,
        metrics.chain_depth_cut,
        if (metrics.chain_truncated) " · chain table truncated" else "",
    });
}

pub fn writeHtml(
    w: *Writer,
    session: *const Session,
    findings: []const advisor.Finding,
    report_list: []const rules.Report,
    ctx: Context,
) !void {
    const duration_ms = actualWindowMs(session);
    const trimmed = ctx.requested_ms > ctx.retained_ms + 2_000 or ctx.retention_trimmed;
    const self_share: f64 = if (session.switches == 0)
        0
    else
        @as(f64, @floatFromInt(session.self_switches)) * 100.0 /
            @as(f64, @floatFromInt(session.switches));
    var requested_buf: [32]u8 = undefined;
    var actual_buf: [32]u8 = undefined;
    var span_buf: [32]u8 = undefined;
    const requested_text = durationText(&requested_buf, ctx.requested_ms);
    const actual_text = durationText(&actual_buf, ctx.retained_ms);
    const span_text = durationText(&span_buf, duration_ms);
    const finding_count = counts(report_list, .finding);
    const clear_count = counts(report_list, .clear);
    const skip_count = counts(report_list, .skip);

    try w.writeAll("<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">" ++
        "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" ++
        "<title>xsprof incident</title><style>" ++
        ":root{color-scheme:dark}body{margin:0;background:#0b0b0a;color:#f5efe4;" ++
        "font:14px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace;padding:28px}" ++
        "main{max-width:1100px;margin:0 auto}h1{font-size:26px;margin:4px 0 2px}" ++
        "h2{font-size:16px;margin:30px 0 10px;border-bottom:1px solid #3a332b;padding-bottom:6px}" ++
        "h3{font-size:14px;margin:18px 0 4px}.sub{color:#a99f90}.muted{color:#8d8478}" ++
        ".grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:10px;margin:18px 0}" ++
        ".card{border:1px solid #3a332b;border-radius:6px;padding:12px;background:#151412}" ++
        ".k{color:#8d8478;font-size:11px;text-transform:uppercase;letter-spacing:.08em}" ++
        ".v{font-size:20px;font-weight:700;margin-top:3px}.bad{color:#ff87a8}" ++
        ".good{color:#9fe8b6}table{border-collapse:collapse;width:100%;margin:8px 0}" ++
        "td,th{border-bottom:1px solid #2c2822;padding:7px 8px;text-align:left;vertical-align:top}" ++
        "th{color:#8d8478;font-weight:500;font-size:11px;text-transform:uppercase;letter-spacing:.06em}" ++
        ".finding{color:#ffd18a;font-weight:700}.clear{color:#9fe8b6;font-weight:700}" ++
        ".skip{color:#8d8478;font-weight:700}code{background:#1f1d19;padding:1px 4px;border-radius:3px}" ++
        "a{color:#8fd3ff}.caveat{border-left:3px solid #ffd18a;background:#1a1713;padding:10px 12px;margin:12px 0}" ++
        "footer{margin-top:36px;border-top:1px solid #2c2822;padding-top:12px}</style></head><body><main>");

    try w.writeAll("<p class=\"muted\">xsprof incident · offline report · host_mutation=false</p>");
    try w.writeAll("<h1>Why was it slow?</h1><p class=\"sub\">Source <code>");
    try escape(w, ctx.source_dir);
    try w.writeAll("</code></p>");

    try w.writeAll("<div class=\"grid\"><div class=\"card\"><div class=\"k\">Requested window</div><div class=\"v\">");
    try escape(w, requested_text);
    try w.writeAll("</div></div><div class=\"card\"><div class=\"k\">Retained window</div><div class=\"v");
    if (trimmed) try w.writeAll(" bad");
    try w.writeAll("\">");
    try escape(w, actual_text);
    try w.writeAll("</div><div class=\"muted\">event span ");
    try escape(w, span_text);
    try w.writeAll("</div></div><div class=\"card\"><div class=\"k\">Findings</div><div class=\"v");
    if (finding_count > 0) try w.writeAll(" finding");
    try w.print("\">{d}</div></div><div class=\"card\"><div class=\"k\">Rules clear / skip</div><div class=\"v\">{d} / {d}</div></div></div>", .{
        finding_count,
        clear_count,
        skip_count,
    });

    if (trimmed) {
        try w.writeAll("<div class=\"caveat\"><strong>Window caveat.</strong> The requested window is longer than the retained data. The report covers only the retained window and the loss section says so; it is never zero-filled.</div>");
    }
    if (ctx.trace_truncated) {
        try w.print("<div class=\"caveat\"><strong>Trace caveat.</strong> trace.json contains a sampled prefix of {d} events; summary/report cover all {d} events.</div>", .{ ctx.trace_events, ctx.events });
    }

    try w.writeAll("<div class=\"grid\"><div class=\"card\"><div class=\"k\">Loss</div><div class=\"v");
    if (session.lost > 0) try w.writeAll(" bad");
    try w.print("\">{d}</div><div class=\"muted\">explicit loss events</div></div><div class=\"card\"><div class=\"k\">Recorder self</div><div class=\"v\">{d:.0}%</div><div class=\"muted\">{d} switches excluded from rankings</div></div><div class=\"card\"><div class=\"k\">Events in window</div><div class=\"v\">{d}</div></div></div>", .{
        session.lost,
        self_share,
        session.self_switches,
        ctx.events,
    });

    try w.writeAll("<h2>Rules</h2><table><thead><tr><th>Rule</th><th>Status</th><th>Why</th></tr></thead><tbody>");
    for (report_list) |item| {
        try w.writeAll("<tr><td>");
        try escape(w, item.id);
        try w.writeAll("</td><td class=\"");
        try w.writeAll(statusClass(item.status));
        try w.writeAll("\">");
        try w.writeAll(statusLabel(item.status));
        try w.writeAll("</td><td>");
        try escape(w, item.reason);
        try w.writeAll("</td></tr>");
    }
    try w.writeAll("</tbody></table>");

    try w.writeAll("<h2>Findings</h2>");
    if (findings.len == 0) {
        try w.writeAll("<p class=\"muted\">No rule fired. This is only meaningful for the rules marked CLEAR above; skipped rules need signals that were not captured.</p>");
    }
    for (findings) |finding| {
        try w.writeAll("<article><h3>");
        try escape(w, finding.id);
        try w.writeAll(" <span class=\"muted\">");
        try escape(w, advisor.severityName(finding.severity));
        try w.writeAll(" · ");
        try escape(w, advisor.confidenceName(finding.confidence));
        try w.writeAll("</span></h3><p>");
        try escape(w, finding.summary);
        try w.writeAll("</p><ul>");
        for (finding.evidence) |line| {
            try w.writeAll("<li><code>");
            try escape(w, line);
            try w.writeAll("</code></li>");
        }
        try w.writeAll("</ul>");
        if (finding.recommendations.len != 0) {
            try w.writeAll("<p class=\"muted\">Suggested next checks (never applied):</p><ul>");
            for (finding.recommendations) |rec| {
                try w.writeAll("<li><code>");
                try escape(w, rec.detail);
                try w.writeAll("</code> — ");
                try escape(w, rec.rationale);
                try w.writeAll("</li>");
            }
            try w.writeAll("</ul>");
        }
        try w.writeAll("</article>");
    }

    try w.writeAll("<h2>Top tasks by p95 wake→run</h2><table><thead><tr><th>Task</th><th>PID</th><th>Switches</th><th>Migrations</th><th>p95 wait</th></tr></thead><tbody>");
    var task_count: usize = 0;
    for (session.metrics.tasks) |task| {
        if (task.is_self) continue;
        if (task_count == 8) break;
        task_count += 1;
        try w.writeAll("<tr><td>");
        try escape(w, task.comm);
        try w.print("</td><td>{d}</td><td>{d}</td><td>{d}</td><td>{d} ms</td></tr>", .{
            task.pid,
            task.switches,
            task.migrations,
            task.wait_p95_us / 1000,
        });
    }
    try w.writeAll("</tbody></table>");

    try writeLatencyHtml(w, session);

    try w.writeAll("<h2>Captured signals</h2><table><thead><tr><th>Signal</th><th>Collected</th></tr></thead><tbody>");
    const agg = session.aggregate();
    const signal_rows = [_]struct { []const u8, bool }{
        .{ "sched_switch", agg.signals.sched_switch },
        .{ "sched_wakeup", agg.signals.sched_wakeup },
        .{ "sched_migrate", agg.signals.sched_migrate },
        .{ "CPU LLC topology", agg.signals.cpu_topology },
        .{ "buddyinfo/allocator", agg.signals.allocator },
        .{ "PMU HITM", agg.signals.pmu_hitm },
        .{ "lock contention", agg.signals.lock_contention },
        .{ "NUMA fault placement", agg.signals.numa_fault },
        .{ "priority/lock-owner chain", agg.signals.priority_inversion },
    };
    for (signal_rows) |row| {
        try w.writeAll("<tr><td>");
        try escape(w, row[0]);
        try w.writeAll("</td><td>");
        try w.writeAll(if (row[1]) "yes" else "no");
        try w.writeAll("</td></tr>");
    }
    try w.writeAll("</tbody></table>");

    try w.writeAll("<h2>Capabilities</h2><table><thead><tr><th>Name</th><th>State</th><th>Reason</th></tr></thead><tbody>");
    if (session.capabilities.len == 0) {
        try w.writeAll("<tr><td colspan=\"3\" class=\"muted\">No capability rows in this window.</td></tr>");
    }
    for (session.capabilities) |cap| {
        try w.writeAll("<tr><td>");
        try escape(w, cap.name);
        try w.writeAll("</td><td>");
        try escape(w, cap.state);
        try w.writeAll("</td><td>");
        try escape(w, cap.reason);
        try w.writeAll("</td></tr>");
    }
    try w.writeAll("</tbody></table>");

    try w.writeAll("<h2>Artifacts</h2><ul><li><a href=\"");
    try escape(w, ctx.artifacts.window);
    try w.writeAll("\">window.ndjson</a> — sanitized raw window</li><li><a href=\"");
    try escape(w, ctx.artifacts.summary);
    try w.writeAll("\">summary.json</a> — canonical machine summary</li><li><a href=\"");
    try escape(w, ctx.artifacts.trace);
    try w.writeAll("\">trace.json</a> — Chrome Trace export</li></ul>");
    try w.writeAll("<footer class=\"muted\">Generated offline by xsprof. No server, no telemetry, no network request. Suggestions are never applied.</footer></main></body></html>\n");
}

test "incident summary reports the retained window and stays offline" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const session: Session = .{
        .allocator = allocator,
        .source = "test",
        .events = &.{},
        .slices = &.{},
        .capabilities = &.{},
        .top_comms = &.{},
        .switches = 10,
        .wakeups = 4,
        .first_us = 100,
        .last_us = 200,
    };
    const report_list = try rules.reports(allocator, session.aggregate(), &.{});
    const ctx: Context = .{
        .source_dir = "/tmp/state",
        .requested_ms = 120_000,
        .retained_ms = 60_000,
        .events = 3,
        .trace_events = 2,
        .trace_truncated = true,
        .retention_trimmed = false,
        .artifacts = .{
            .report = "report.html",
            .summary = "summary.json",
            .trace = "trace.json",
            .window = "window.ndjson",
        },
    };
    var json_buf: [16 * 1024]u8 = undefined;
    var json_writer = Writer.fixed(&json_buf);
    try writeJson(&json_writer, &session, &.{}, report_list, ctx);
    const json_text = json_writer.buffered();
    try std.testing.expect(std.mem.startsWith(u8, json_text, "{\"artifacts\":{"));
    try std.testing.expect(std.mem.indexOf(u8, json_text, "\"retained_ms\":60000") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_text, "\"trimmed\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_text, "\"schema\":\"xsprof/incident-summary/v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_text, "\"host_mutation\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_text, "\"events\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_text, "\"truncated\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_text, "\"latency\":{\"causes\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_text, "\"preemptions\":0") != null);

    var html_buf: [32 * 1024]u8 = undefined;
    var html_writer = Writer.fixed(&html_buf);
    try writeHtml(&html_writer, &session, &.{}, report_list, ctx);
    const html_text = html_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, html_text, "Retained window") != null);
    try std.testing.expect(std.mem.indexOf(u8, html_text, "event span") != null);
    try std.testing.expect(std.mem.indexOf(u8, html_text, "Capabilities") != null);
    try std.testing.expect(std.mem.indexOf(u8, html_text, "Latency attribution") != null);
    try std.testing.expect(std.mem.indexOf(u8, html_text, "Critical chains") != null);
    try std.testing.expect(std.mem.indexOf(u8, html_text, "https://") == null);
}
