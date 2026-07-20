// xsprof CLI — Linux Scheduler & Memory Profiler.
// Fail-closed operator surface mirroring the archived Zig project's main.zig:
// read-only by default, unsafe verbs refused with non-zero exit, host_mutation=false.
#include <cstring>
#include <fstream>
#include <iostream>
#include <string>
#include <string_view>
#include <vector>

#include "xsprof/advisor.hpp"
#include "xsprof/chrome_trace.hpp"
#include "xsprof/json.hpp"
#include "xsprof/privacy.hpp"
#include "xsprof/proc.hpp"
#include "xsprof/safety.hpp"

namespace {

using xsprof::json::Value;

void write_help(std::ostream& os, const char* prog) {
    os << prog << " — Linux Scheduler & Memory Profiler (C++ rewrite of zig-scheduler)\n\n"
       << "USAGE:\n"
       << "  " << prog << " <command> [options]\n\n"
       << "COMMANDS (read-only, fail-closed):\n"
       << "  preflight --json        Collect read-only host facts + capability probes (host_mutation=false)\n"
       << "  capabilities --json     Probe collector capabilities (perf/tracepoint/BPF/PMU/sched_ext)\n"
       << "  advise --json|--md      Run the Performance Advisor over a read-only snapshot\n"
       << "  timeline --json         Emit a Chrome Trace timeline from a recorded JSONL journal\n"
       << "  version                 Print version\n"
       << "  help                    Print this help\n\n"
       << "REFUSED (unsafe verbs; non-zero exit on host by design):\n"
       << "  load attach enable mutate apply sched-ext-attach setaffinity setpriority bind\n\n"
       << "SAFETY:\n"
       << "  Observation is read-only. Any scheduler/memory mutation is refused on the host\n"
       << "  and is VM-lab-only with audit-id + rollback-id + lab marker. Every read-only\n"
       << "  record carries host_mutation=false. Runtime samples never expose argv/env/secrets.\n";
}

int write_refusal(std::string_view verb) {
    Value v = Value::make_object();
    v.set("schema", Value("xsprof/event/v1"));
    v.set("event", Value("refusal"));
    v.set("verb", Value(std::string(verb)));
    v.set("status", Value("refused"));
    v.set("reason", Value("unsafe verb is disabled in the host operator (fail-closed); "
                          "mutation is VM-lab-only with audit-id + rollback-id + lab marker"));
    v.set("host_mutation", Value(false));
    std::cout << v.dump() << "\n";
    return 1;
}

bool wants_json(int argc, char** argv) {
    for (int i = 0; i < argc; ++i)
        if (std::string_view(argv[i]) == "--json") return true;
    return false;
}

int cmd_preflight(int argc, char** argv) {
    if (!wants_json(argc, argv)) {
        std::cerr << "preflight expects --json and remains read-only\n";
        return 2;
    }
    auto caps = xsprof::ProcSource::probe_capabilities();
    auto facts = xsprof::ProcSource::collect_facts();

    Value doc = Value::make_object();
    doc.set("schema", Value("xsprof/preflight/v1"));
    doc.set("tool", Value("xsprof"));
    doc.set("host_mutation", Value(false));

    Value cap_arr = Value::make_array();
    for (const auto& c : caps) cap_arr.push_back(c.to_json());
    doc.set("capabilities", cap_arr);
    doc.set("facts", xsprof::ProcSource::facts_to_json(facts));

    std::cout << doc.dump() << "\n";
    return 0;
}

int cmd_capabilities(int argc, char** argv) {
    if (!wants_json(argc, argv)) {
        std::cerr << "capabilities expects --json and remains read-only\n";
        return 2;
    }
    auto caps = xsprof::ProcSource::probe_capabilities();
    Value arr = Value::make_array();
    for (const auto& c : caps) arr.push_back(c.to_json());
    std::cout << arr.dump() << "\n";
    return 0;
}

int cmd_advise(int argc, char** argv) {
    bool md = false;
    for (int i = 0; i < argc; ++i)
        if (std::string_view(argv[i]) == "--md") md = true;
    auto facts = xsprof::ProcSource::collect_facts();
    auto agg = xsprof::advisor::aggregates_from_facts(facts);
    xsprof::advisor::Advisor advisor;
    if (md) {
        std::cout << advisor.report_markdown(agg);
    } else {
        std::cout << advisor.report_json(agg).dump() << "\n";
    }
    return 0;
}

// Read a recorded JSONL journal of xsprof/event/v1 rows and emit a Chrome Trace
// timeline. Mirrors the Zig daemon's replay discipline (deterministic, fail-closed
// on gaps). Phase-1 accepts the event JSON shape produced by event_to_json.
int cmd_timeline(int argc, char** argv) {
    std::string input;
    for (int i = 0; i < argc; ++i) {
        if (std::string_view(argv[i]) == "--input" && i + 1 < argc) input = argv[++i];
    }
    if (input.empty()) {
        std::cerr << "timeline requires --input <journal.jsonl>\n";
        return 2;
    }
    std::ifstream in(input);
    if (!in) {
        std::cerr << "timeline: cannot open " << input << "\n";
        return 1;
    }
    // Phase-1: emit an empty-but-valid trace skeleton with metadata; full event
    // reconstruction from the journal is a Phase-4 milestone. The exporter is
    // exercised directly in tests via export_events().
    xsprof::viz::ChromeTraceBuilder b;
    b.add_metadata_name("CPUs", -1);
    std::string line;
    long long rows = 0;
    while (std::getline(in, line)) {
        if (!line.empty()) ++rows;
    }
    auto doc = b.build();
    doc.set("journal_rows", Value(rows));
    doc.set("note", Value("Phase-1 skeleton; full timeline reconstruction is a Phase-4 milestone"));
    std::cout << doc.dump() << "\n";
    return 0;
}

} // namespace

int main(int argc, char** argv) {
    const char* prog = argc > 0 ? argv[0] : "xsprof";
    if (argc < 2) {
        write_help(std::cout, prog);
        return 0;
    }

    std::string_view cmd = argv[1];

    if (cmd == "help" || cmd == "--help" || cmd == "-h") {
        write_help(std::cout, prog);
        return 0;
    }
    if (cmd == "version" || cmd == "--version") {
        std::cout << "xsprof 0.1.0\n";
        return 0;
    }

    // Fail-closed: refuse unsafe verbs before anything else.
    if (xsprof::is_unsafe_verb(cmd)) {
        return write_refusal(cmd);
    }

    if (cmd == "preflight") return cmd_preflight(argc - 2, argv + 2);
    if (cmd == "capabilities") return cmd_capabilities(argc - 2, argv + 2);
    if (cmd == "advise") return cmd_advise(argc - 2, argv + 2);
    if (cmd == "timeline") return cmd_timeline(argc - 2, argv + 2);

    // Unknown verb: refuse (fail-closed), like the Zig default branch.
    return write_refusal(cmd);
}
