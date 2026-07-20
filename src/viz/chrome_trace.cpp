#include "xsprof/chrome_trace.hpp"

namespace xsprof::viz {

void ChromeTraceBuilder::add_metadata_name(const std::string& group_name, long long pid) {
    TraceEvent e;
    e.name = group_name;
    e.ph = "M";
    e.cat = "__metadata";
    e.pid = pid;
    e.tid = 0;
    e.args.set("name", json::Value(group_name));
    // process_name metadata key
    e.name = "process_name";
    e.args = json::Value::make_object();
    e.args.set("name", json::Value(group_name));
    events_.push_back(std::move(e));
}

void ChromeTraceBuilder::add_thread_name(const std::string& comm, long long pid, long long tid) {
    TraceEvent e;
    e.name = "thread_name";
    e.ph = "M";
    e.cat = "__metadata";
    e.pid = pid;
    e.tid = tid;
    e.args.set("name", json::Value(comm));
    events_.push_back(std::move(e));
}

void ChromeTraceBuilder::add_complete(const std::string& name, const std::string& cat,
                                      std::uint64_t ts_us, std::uint64_t dur_us, long long pid,
                                      long long tid, json::Value args) {
    TraceEvent e;
    e.name = name;
    e.ph = "X";
    e.cat = cat;
    e.ts_us = ts_us;
    e.dur_us = dur_us;
    e.pid = pid;
    e.tid = tid;
    e.args = std::move(args);
    events_.push_back(std::move(e));
}

void ChromeTraceBuilder::add_instant(const std::string& name, const std::string& cat,
                                     std::uint64_t ts_us, long long pid, long long tid,
                                     json::Value args) {
    TraceEvent e;
    e.name = name;
    e.ph = "i";
    e.cat = cat;
    e.ts_us = ts_us;
    e.pid = pid;
    e.tid = tid;
    e.args.set("scope", json::Value("thread"));
    for (const auto& [k, val] : args.as_object()) e.args.set(k, val);
    events_.push_back(std::move(e));
}

void ChromeTraceBuilder::add_flow(const std::string& name, const std::string& cat,
                                  std::uint64_t ts_us, long long pid, long long tid,
                                  std::uint64_t id, bool end) {
    TraceEvent e;
    e.name = name;
    e.ph = end ? "f" : "s";
    e.cat = cat;
    e.ts_us = ts_us;
    e.pid = pid;
    e.tid = tid;
    e.id = id;
    if (end) e.args.set("bp", json::Value("e")); // binding point: enclosing slice
    events_.push_back(std::move(e));
}

void ChromeTraceBuilder::add_sample_loss(std::uint64_t ts_us, long long pid, long long tid,
                                         const std::string& reason) {
    json::Value args = json::Value::make_object();
    args.set("unsafe", json::Value(true));
    args.set("reason", json::Value(reason));
    add_instant("SAMPLE_LOSS", "unsafe", ts_us, pid, tid, std::move(args));
}

json::Value ChromeTraceBuilder::build() const {
    json::Value doc = json::Value::make_object();
    json::Value arr = json::Value::make_array();
    for (const auto& e : events_) {
        json::Value ev = json::Value::make_object();
        ev.set("name", json::Value(e.name));
        ev.set("ph", json::Value(e.ph));
        ev.set("cat", json::Value(e.cat));
        ev.set("ts", json::Value(static_cast<unsigned long long>(e.ts_us)));
        if (e.ph == "X") ev.set("dur", json::Value(static_cast<unsigned long long>(e.dur_us)));
        ev.set("pid", json::Value(e.pid));
        ev.set("tid", json::Value(e.tid));
        if (e.ph == "s" || e.ph == "f" || e.ph == "t")
            ev.set("id", json::Value(static_cast<unsigned long long>(e.id)));
        if (!e.args.as_object().empty()) ev.set("args", e.args);
        arr.push_back(std::move(ev));
    }
    doc.set("traceEvents", arr);
    doc.set("displayTimeUnit", json::Value("ns"));
    return doc;
}

std::string ChromeTraceBuilder::dump(bool pretty) const { return build().dump(pretty); }

json::Value export_events(const std::vector<RawEvent>& events) {
    ChromeTraceBuilder b;
    b.add_metadata_name("CPUs", -1);

    for (const auto& e : events) {
        const std::uint64_t ts_us = e.ts_ns / 1000;
        switch (e.kind) {
            case EventKind::SchedSwitch: {
                // A switch ends the previous task's run slice and starts the next.
                json::Value args = json::Value::make_object();
                args.set("cpu", json::Value(e.cpu));
                args.set("next_pid", json::Value(e.pid));
                if (!e.comm.empty()) args.set("comm", json::Value(e.comm));
                b.add_complete(e.comm.empty() ? "run" : e.comm, "sched", ts_us,
                               e.a / 1000 /*dur us*/, -1, e.cpu, std::move(args));
                break;
            }
            case EventKind::SchedWakeup: {
                json::Value args = json::Value::make_object();
                args.set("target_cpu", json::Value(e.cpu));
                b.add_flow("wakeup", "sched", ts_us, e.pid, e.tid, e.a, /*end=*/false);
                break;
            }
            case EventKind::SchedMigrate: {
                json::Value args = json::Value::make_object();
                args.set("orig_cpu", json::Value(static_cast<long long>(e.a)));
                args.set("dest_cpu", json::Value(static_cast<long long>(e.b)));
                b.add_instant("migrate", "sched", ts_us, e.pid, e.tid, std::move(args));
                break;
            }
            case EventKind::PageFault:
            case EventKind::TlbMiss:
            case EventKind::CacheMiss: {
                json::Value args = json::Value::make_object();
                args.set("count", json::Value(static_cast<unsigned long long>(e.a)));
                b.add_instant(std::string(event_kind_name(e.kind)), "memory", ts_us, e.pid, e.tid,
                              std::move(args));
                break;
            }
            case EventKind::MallocHotspot:
            case EventKind::AllocSample: {
                json::Value args = json::Value::make_object();
                args.set("bytes", json::Value(static_cast<unsigned long long>(e.a)));
                b.add_instant("alloc", "memory", ts_us, e.pid, e.tid, std::move(args));
                break;
            }
            default: {
                json::Value args = json::Value::make_object();
                b.add_instant(std::string(event_kind_name(e.kind)), "control", ts_us, e.pid, e.tid,
                              std::move(args));
                break;
            }
        }
    }
    return b.build();
}

} // namespace xsprof::viz
