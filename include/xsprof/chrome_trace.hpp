// Chrome Trace Event Format exporter — the interactive-timeline artifact
// (openable in chrome://tracing and the Perfetto UI). See docs/rewrite/VISUALIZATION.md.
#pragma once

#include <string>
#include <vector>

#include "xsprof/event.hpp"
#include "xsprof/json.hpp"

namespace xsprof::viz {

// One trace event. `ph` follows the Chrome Trace phase convention:
//   X = complete (duration), i = instant, s/f = flow start/end, M = metadata.
struct TraceEvent {
    std::string name;
    std::string ph = "X";
    std::string cat = "sched";
    std::uint64_t ts_us = 0;   // microseconds (Chrome convention)
    std::uint64_t dur_us = 0;  // for ph == "X"
    long long pid = 0;         // process id (or CPU group id for cpu lanes)
    long long tid = 0;         // thread id (or cpu index for cpu lanes)
    std::uint64_t id = 0;      // for flow events
    json::Value args = json::Value::make_object();
};

class ChromeTraceBuilder {
public:
    void add_metadata_name(const std::string& group_name, long long pid);
    void add_thread_name(const std::string& comm, long long pid, long long tid);
    void add_complete(const std::string& name, const std::string& cat, std::uint64_t ts_us,
                      std::uint64_t dur_us, long long pid, long long tid,
                      json::Value args = json::Value::make_object());
    void add_instant(const std::string& name, const std::string& cat, std::uint64_t ts_us,
                     long long pid, long long tid,
                     json::Value args = json::Value::make_object());
    void add_flow(const std::string& name, const std::string& cat, std::uint64_t ts_us,
                  long long pid, long long tid, std::uint64_t id, bool end);
    // Mark sample loss / gapped stream as an explicit unsafe signal (never interpolated).
    void add_sample_loss(std::uint64_t ts_us, long long pid, long long tid,
                         const std::string& reason);

    std::size_t size() const { return events_.size(); }
    json::Value build() const;
    std::string dump(bool pretty = false) const;

private:
    std::vector<TraceEvent> events_;
};

// Convert a stream of RawEvents into a Chrome Trace document. CPU lanes use
// pid = -1 (rendered as a "CPUs" group); thread lanes use the real pid/tid.
json::Value export_events(const std::vector<RawEvent>& events);

} // namespace xsprof::viz
