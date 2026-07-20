// Chrome Trace Event Format exporter — the interactive-timeline artifact
// (openable in chrome://tracing and the Perfetto UI). See docs/rewrite/VISUALIZATION.md.
#pragma once

#include <optional>
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
    std::uint64_t ts_us = 0;  // microseconds (Chrome convention)
    std::uint64_t dur_us = 0; // for ph == "X"
    long long pid = 0;        // process id (or CPU group id for cpu lanes)
    long long tid = 0;        // thread id (or cpu index for cpu lanes)
    std::uint64_t id = 0;     // for flow events
    json::Value args = json::Value::make_object();
};

// Time window for focused inspection (--window start_us:end_us).
struct TimeWindow {
    std::uint64_t start_us = 0;
    std::uint64_t end_us = 0; // 0 means unbounded

    bool contains(std::uint64_t ts_us) const {
        if (ts_us < start_us)
            return false;
        if (end_us > 0 && ts_us > end_us)
            return false;
        return true;
    }
};

// Parse a "start:end" window string (microseconds). Returns nullopt on error.
std::optional<TimeWindow> parse_window(const std::string& s);

class ChromeTraceBuilder {
  public:
    void add_metadata_name(const std::string& group_name, long long pid);
    void add_thread_name(const std::string& comm, long long pid, long long tid);
    void add_complete(const std::string& name, const std::string& cat, std::uint64_t ts_us,
                      std::uint64_t dur_us, long long pid, long long tid,
                      json::Value args = json::Value::make_object());
    void add_instant(const std::string& name, const std::string& cat, std::uint64_t ts_us,
                     long long pid, long long tid, json::Value args = json::Value::make_object());
    void add_flow(const std::string& name, const std::string& cat, std::uint64_t ts_us,
                  long long pid, long long tid, std::uint64_t id, bool end);
    // Mark sample loss / gapped stream as an explicit unsafe signal (never interpolated).
    void add_sample_loss(std::uint64_t ts_us, long long pid, long long tid,
                         const std::string& reason);

    std::size_t size() const { return events_.size(); }
    json::Value build() const;
    std::string dump(bool pretty = false) const;

    // Build with a time window filter: only events within the window are included.
    json::Value build_windowed(const TimeWindow& w) const;

    // Build chunked output: splits traceEvents into arrays of at most chunk_size
    // events each. Returns a JSON object with "chunks" array, each element being
    // a {"traceEvents":[...]} object. Metadata events are replicated in each chunk.
    json::Value build_chunked(std::size_t chunk_size) const;

  private:
    std::vector<TraceEvent> events_;
};

// Convert a stream of RawEvents into a Chrome Trace document. CPU lanes use
// pid = -1 (rendered as a "CPUs" group); thread lanes use the real pid/tid.
json::Value export_events(const std::vector<RawEvent>& events);

// Convert a stream of RawEvents with a time window filter.
json::Value export_events_windowed(const std::vector<RawEvent>& events, const TimeWindow& w);

// Replay from a JSONL journal: parse each line as an xsprof/event/v1 record,
// convert to RawEvents, and export as a Chrome Trace document. Lost/gapped
// streams render as explicit unsafe markers. Returns the trace JSON and sets
// `rows_parsed` to the number of successfully parsed journal lines.
json::Value replay_from_journal(std::istream& in, long long& rows_parsed);

// Replay with a time window filter.
json::Value replay_from_journal_windowed(std::istream& in, const TimeWindow& w,
                                         long long& rows_parsed);

// Stream a journal to an ostream as chunked Chrome Trace with BOUNDED memory:
// holds at most chunk_size events at a time instead of the whole journal.
// Output format: {"chunks":[{"traceEvents":[...],"displayTimeUnit":"ns"}, ...]}.
// Lost/gapped streams still render as explicit unsafe markers (per chunk).
void stream_timeline_chunked(std::istream& in, std::ostream& out, std::size_t chunk_size,
                             long long& rows_parsed);


} // namespace xsprof::viz
