// Self-contained verification suite for xsprof (no external test framework).
// Mirrors the Catch2 tests so the project can be verified Nix-independently:
//   g++ -std=c++20 -Iinclude -Isrc <sources> tests/selftest.cpp -o selftest && ./selftest
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <string>

#include "xsprof/advisor.hpp"
#include "xsprof/chrome_trace.hpp"
#include "xsprof/event.hpp"
#include "xsprof/json.hpp"
#include "xsprof/pipeline.hpp"
#include "xsprof/privacy.hpp"
#include "xsprof/proc.hpp"
#include "xsprof/ring_buffer.hpp"
#include "xsprof/safety.hpp"
#include "xsprof/sched_collector.hpp"
#include "xsprof/memory_collector.hpp"

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond)                                                            \
    do {                                                                       \
        ++g_checks;                                                            \
        if (!(cond)) {                                                         \
            ++g_failures;                                                      \
            std::printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);        \
        }                                                                      \
    } while (0)

using namespace xsprof;
using namespace xsprof::advisor;
using xsprof::viz::ChromeTraceBuilder;

static std::string read_fixture(const std::string& name) {
#ifdef XSPROF_TEST_FIXTURE_DIR
    std::string path = std::string(XSPROF_TEST_FIXTURE_DIR) + "/" + name;
#else
    std::string path = "tests/fixtures/" + name;
#endif
    std::ifstream f(path);
    if (!f) return {};
    std::ostringstream ss;
    ss << f.rdbuf();
    return ss.str();
}

static void test_json() {
    json::Value v = json::Value::make_object();
    v.set("schema", json::Value("xsprof/event/v1"));
    v.set("count", json::Value(42));
    v.set("ratio", json::Value(0.5));
    v.set("ok", json::Value(true));
    v.set("host_mutation", json::Value(false));
    json::Value arr = json::Value::make_array();
    arr.push_back(json::Value(1));
    arr.push_back(json::Value(2));
    v.set("xs", arr);
    std::string s = v.dump();
    CHECK(s.find("\"schema\":\"xsprof/event/v1\"") != std::string::npos);
    CHECK(s.find("\"count\":42") != std::string::npos);
    CHECK(s.find("\"ok\":true") != std::string::npos);
    CHECK(s.find("\"host_mutation\":false") != std::string::npos);
    CHECK(s.find("\"xs\":[1,2]") != std::string::npos);
    // Escaping.
    json::Value esc = json::Value(std::string("a\"b\\c\n"));
    CHECK(esc.dump() == "\"a\\\"b\\\\c\\n\"");
}

static void test_event() {
    RawEvent e;
    e.kind = EventKind::SchedSwitch;
    e.ts_ns = 1000000;
    e.cpu = 3;
    e.pid = 100;
    e.tid = 101;
    e.comm = "worker";
    auto j = event_to_json(e);
    std::string s = j.dump();
    CHECK(s.find("\"event\":\"sched_switch\"") != std::string::npos);
    CHECK(s.find("\"host_mutation\":false") != std::string::npos);
    CHECK(s.find("\"cpu\":3") != std::string::npos);
    CHECK(std::string(event_kind_name(EventKind::PageFault)) == "page_fault");

    // All 18 event kinds have non-empty, non-unknown names.
    const EventKind all[] = {
        EventKind::SchedSwitch, EventKind::SchedWakeup, EventKind::SchedMigrate,
        EventKind::RunqueueSample, EventKind::PriorityInversion, EventKind::LockContention,
        EventKind::PageFault, EventKind::TlbMiss, EventKind::CacheMiss,
        EventKind::HugePage, EventKind::NumaBalance, EventKind::AllocSample,
        EventKind::MallocHotspot,
        EventKind::Marker, EventKind::Capability, EventKind::Refusal,
        EventKind::Incident, EventKind::RuntimeSample,
    };
    for (auto k : all) {
        auto name = event_kind_name(k);
        CHECK(!name.empty());
        CHECK(name != "unknown");
    }
}

static void test_privacy() {
    PrivacyFilter pf;
    CHECK(pf.sensitive_key("api_key"));
    CHECK(pf.sensitive_key("DB_PASSWORD"));
    CHECK(pf.sensitive_key("auth_token"));
    CHECK(!pf.sensitive_key("cpu_usage"));
    std::string red = pf.redact("user=alice password=hunter2 cpu=10 token=abc");
    CHECK(red.find("password=[REDACTED]") != std::string::npos);
    CHECK(red.find("token=[REDACTED]") != std::string::npos);
    CHECK(red.find("user=alice") != std::string::npos);
    CHECK(red.find("hunter2") == std::string::npos);
    CHECK(pf.sensitive_value("Bearer xyz"));
    CHECK(PrivacyFilter::bound_comm("a-very-long-command-name").size() <= 15);
}

static void test_safety() {
    SafetyGate gate;
    AuditContext none;
    auto d0 = gate.decide(Mutation::SchedAffinity, none);
    CHECK(!d0.allowed);
    CHECK(d0.reason.find("refused") != std::string::npos);

    AuditContext partial;
    partial.allow_mutate = true; // but no lab marker / ids
    auto d1 = gate.decide(Mutation::NumaBind, partial);
    CHECK(!d1.allowed);

    AuditContext full;
    full.allow_mutate = true;
    full.vm_lab_marker = true;
    full.audit_id = "audit-1";
    full.rollback_id = "rollback-1";
    auto d2 = gate.decide(Mutation::SchedExtLoad, full);
    CHECK(d2.allowed);
    CHECK(d2.reason.find("planned only") != std::string::npos);

    CHECK(is_unsafe_verb("load"));
    CHECK(is_unsafe_verb("attach"));
    CHECK(is_unsafe_verb("mutate"));
    CHECK(is_unsafe_verb("apply"));
    CHECK(is_unsafe_verb("enable"));
    CHECK(!is_unsafe_verb("preflight"));
    CHECK(!is_unsafe_verb("advise"));

    auto ok = SafePath::under("/var/lib/xsprof", "runs/42/events.jsonl");
    CHECK(ok.ok);
    CHECK(ok.resolved == "/var/lib/xsprof/runs/42/events.jsonl");
    auto bad_abs = SafePath::under("/var/lib/xsprof", "/etc/passwd");
    CHECK(!bad_abs.ok);
    auto bad_trav = SafePath::under("/var/lib/xsprof", "../../etc/passwd");
    CHECK(!bad_trav.ok);
}

static void test_ring_buffer() {
    RingBuffer<int> rb(3);
    CHECK(rb.push(1));
    CHECK(rb.push(2));
    CHECK(rb.push(3));
    CHECK(!rb.push(4)); // full -> signals loss
    int out = 0;
    CHECK(rb.pop(out) && out == 1);
    CHECK(rb.pop(out) && out == 2);
    CHECK(rb.push(4));
    CHECK(rb.pop(out) && out == 3);
    CHECK(rb.pop(out) && out == 4);
    CHECK(!rb.pop(out)); // empty
}

static void test_proc() {
    auto caps = ProcSource::probe_capabilities();
    CHECK(!caps.empty());
    bool have_perf = false, have_btf = false;
    for (const auto& c : caps) {
        if (c.name == "perf_event") have_perf = true;
        if (c.name == "btf") have_btf = true;
        // Every capability record must carry host_mutation=false.
        CHECK(c.to_json().dump().find("\"host_mutation\":false") != std::string::npos);
    }
    CHECK(have_perf);
    CHECK(have_btf);

    auto facts = ProcSource::collect_facts();
    CHECK(facts.online_cpus > 0);
    CHECK(facts.mem.mem_total_kb > 0);
    CHECK(!facts.kernel_release.empty());
    auto fj = ProcSource::facts_to_json(facts);
    CHECK(fj.dump().find("\"host_mutation\":false") != std::string::npos);
}

static void test_advisor() {
    Advisor advisor;
    // Healthy / uncollected baseline -> no false findings from uncollected signals.
    Aggregates healthy;
    CHECK(advisor.analyze(healthy).empty());

    // Poor NUMA placement.
    Aggregates numa;
    numa.remote_fault_ratio = 0.6;
    numa.dominant_node = 1;
    numa.task_cpu_node = 0;
    auto fn = advisor.analyze(numa);
    bool found_numa = false;
    for (const auto& f : fn)
        if (f.id == "poor-numa-placement") {
            found_numa = true;
            CHECK(!f.recs.empty());
            CHECK(f.recs[0].kind == "numa_bind");
        }
    CHECK(found_numa);

    // False sharing needs PMU; without it, heuristic only if llc_misses>0.
    Aggregates fs;
    fs.pmu_collected = true;
    fs.remote_hitm = 0.4;
    auto fsf = advisor.analyze(fs);
    bool found_fs = false;
    for (const auto& f : fsf)
        if (f.id == "false-sharing" && f.sev == Severity::Critical) found_fs = true;
    CHECK(found_fs);

    auto rj = advisor.report_json(numa);
    CHECK(rj.dump().find("\"host_mutation\":false") != std::string::npos);
    CHECK(!advisor.report_markdown(numa).empty());
}

static void test_viz() {
    std::vector<RawEvent> events;
    RawEvent sw;
    sw.kind = EventKind::SchedSwitch;
    sw.ts_ns = 5000000;
    sw.cpu = 2;
    sw.pid = 7;
    sw.tid = 7;
    sw.comm = "kworker";
    sw.a = 2000000; // dur ns
    events.push_back(sw);
    RawEvent wf;
    wf.kind = EventKind::PageFault;
    wf.ts_ns = 6000000;
    wf.pid = 7;
    wf.tid = 7;
    wf.a = 3;
    events.push_back(wf);

    auto doc = viz::export_events(events);
    std::string s = doc.dump();
    CHECK(s.find("\"traceEvents\"") != std::string::npos);
    CHECK(s.find("\"ph\":\"X\"") != std::string::npos);   // complete event
    CHECK(s.find("\"ph\":\"i\"") != std::string::npos);   // instant event
    CHECK(s.find("kworker") != std::string::npos);

    viz::ChromeTraceBuilder b;
    b.add_sample_loss(1000, 1, 1, "ring buffer full");
    auto loss = b.build().dump();
    CHECK(loss.find("SAMPLE_LOSS") != std::string::npos);
    CHECK(loss.find("\"unsafe\":true") != std::string::npos);
}

static void test_pipeline() {
    // Aggregates defaults are fail-closed (zero / uncollected).
    pipeline::Aggregates agg;
    CHECK(agg.remote_fault_ratio == 0.0);
    CHECK(agg.dominant_node == -1);
    CHECK(agg.task_cpu_node == -1);
    CHECK(agg.migrations == 0);
    CHECK(!agg.pmu_collected);
    CHECK(!agg.sched_collected);

    // to_json carries the schema and host_mutation=false.
    auto j = agg.to_json();
    std::string s = j.dump();
    CHECK(s.find("\"schema\":\"xsprof/aggregates/v1\"") != std::string::npos);
    CHECK(s.find("\"host_mutation\":false") != std::string::npos);
    CHECK(s.find("\"pmu_collected\":false") != std::string::npos);

    // CountingSink basic contract.
    pipeline::CountingSink sink;
    RawEvent e;
    e.kind = EventKind::SchedSwitch;
    CHECK(sink.on_event(e));
    CHECK(sink.events() == 1);
    sink.on_aggregates(agg);
    CHECK(sink.snapshots() == 1);
    CHECK(!sink.complete());
    sink.on_complete();
    CHECK(sink.complete());
}

static void test_schema_golden() {
    // event-v1 golden fixture byte-stability.
    {
        RawEvent e;
        e.kind = EventKind::SchedSwitch;
        e.ts_ns = 1000000;
        e.cpu = 3;
        e.pid = 100;
        e.tid = 101;
        e.comm = "worker";
        std::string actual = event_to_json(e).dump();
        std::string golden = read_fixture("event_v1_golden.json");
        if (!golden.empty()) {
            if (!golden.empty() && golden.back() == '\n') golden.pop_back();
            CHECK(actual == golden);
        } else {
            std::printf("WARN: fixture event_v1_golden.json not found (skipping byte-stable check)\n");
        }
    }
    // aggregates-v1 golden fixture byte-stability.
    {
        pipeline::Aggregates agg;
        std::string actual = agg.to_json().dump();
        std::string golden = read_fixture("aggregates_v1_golden.json");
        if (!golden.empty()) {
            if (!golden.empty() && golden.back() == '\n') golden.pop_back();
            CHECK(actual == golden);
        } else {
            std::printf("WARN: fixture aggregates_v1_golden.json not found (skipping byte-stable check)\n");
        }
    }
    // journal-v1 golden fixture invariants.
    {
        std::string golden = read_fixture("journal_v1_golden.json");
        if (!golden.empty()) {
            CHECK(golden.find("\"host_mutation\":false") != std::string::npos);
            CHECK(golden.find("\"schema\":\"xsprof/journal/v1\"") != std::string::npos);
            CHECK(golden.find("\"host_mutation\":true") == std::string::npos);
        }
    }
}

static void test_sched_collector() {
    using namespace xsprof::sched;
    SchedCollector collector;
    auto cap = collector.probe();
    CHECK(cap.name == "sched_collector");
    // On this host perf_event_paranoid=2, probe must return SKIP (fail-closed).
    CHECK(cap.state == CapState::Skip || cap.state == CapState::Refuse);
    CHECK(cap.reason.find("fail-closed") != std::string::npos);
    CHECK(cap.reason.find("never auto-elevate") != std::string::npos);
    CHECK(cap.to_json().dump().find("\"host_mutation\":false") != std::string::npos);

    // Schedstat parsing.
    RunqueueSample s;
    bool ok = SchedCollector::parse_schedstat_cpu_line(
        "cpu0 0 12345 67890 54321 9876543210 123456789 11111 0 0", s);
    CHECK(ok);
    CHECK(s.cpu == 0);
    CHECK(s.nr_switches == 12345);
    CHECK(s.run_delay_ns == 123456789);

    // Wakeup-to-switch correlation.
    SchedCollector corr;
    corr.set_correlation_window_ns(1000000);
    corr.record_wakeup(0, 42, 1);
    corr.record_switch(500000, 1, 42);
    CHECK(corr.correlated_wakeups() == 1);
    CHECK(corr.unnecessary_wakeups() == 0);

    // fill_aggregates sets sched_collected.
    pipeline::Aggregates agg;
    CHECK(!agg.sched_collected);
    collector.fill_aggregates(agg);
    CHECK(agg.sched_collected);
}

static void test_memory_collector() {
    using namespace xsprof::memory;
    MemoryCollector collector;
    auto cap = collector.probe();
    CHECK(cap.name == "memory_collector");
    // On this host perf_event_paranoid=2, probe must return SKIP (fail-closed).
    CHECK(cap.state == CapState::Skip || cap.state == CapState::Refuse);
    CHECK(cap.reason.find("fail-closed") != std::string::npos);
    CHECK(cap.reason.find("never auto-elevate") != std::string::npos);
    CHECK(cap.to_json().dump().find("\"host_mutation\":false") != std::string::npos);

    // Buddyinfo parsing.
    BuddyInfo bi;
    bool ok = MemoryCollector::parse_buddyinfo_line(
        "Node 0, zone      DMA      1      1      1      0      2      1      1      0      1      1      3", bi);
    CHECK(ok);
    CHECK(bi.node == 0);
    CHECK(bi.zone_name == "DMA");
    CHECK(bi.free_per_order.size() == 11);

    // Fragmentation estimation.
    std::vector<BuddyInfo> fragmented;
    BuddyInfo fbi;
    fbi.node = 0;
    fbi.zone_name = "Normal";
    fbi.free_per_order = {100, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0};
    fragmented.push_back(fbi);
    CHECK(MemoryCollector::estimate_fragmentation(fragmented) > 0.9);
    CHECK(MemoryCollector::estimate_fragmentation({}) == 0.0);

    // Numa_maps parsing.
    NumaMapEntry entry;
    ok = MemoryCollector::parse_numa_maps_line(
        "00400000 default file=/usr/bin/foo mapped=10 N0=10", entry);
    CHECK(ok);
    CHECK(entry.vaddr == 0x00400000);
    CHECK(entry.node == 0);
    CHECK(entry.pages == 10);

    // IBS probe is read-only and safe.
    auto ibs = MemoryCollector::probe_ibs();
    CHECK(!ibs.reason.empty());

    // fill_aggregates sets pmu_collected.
    pipeline::Aggregates agg;
    CHECK(!agg.pmu_collected);
    collector.set_pmu_collected(true);
    collector.add_page_faults(42);
    collector.fill_aggregates(agg);
    CHECK(agg.pmu_collected);
    CHECK(agg.page_faults == 42);
}

int main() {
    test_json();
    test_event();
    test_privacy();
    test_safety();
    test_ring_buffer();
    test_proc();
    test_advisor();
    test_viz();
    test_pipeline();
    test_schema_golden();
    test_sched_collector();
    test_memory_collector();
    std::printf("\n[xsprof selftest] %d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
