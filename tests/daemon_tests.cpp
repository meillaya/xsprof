// Tests for the daemon module — event/action serialization, replay, stdio mode.
#include <catch2/catch_test_macros.hpp>

#include <fstream>
#include <sstream>

#include "xsprof/daemon.hpp"

using namespace xsprof::daemon;

static std::string read_fixture(const std::string& name) {
#ifdef XSPROF_TEST_FIXTURE_DIR
    std::string path = std::string(XSPROF_TEST_FIXTURE_DIR) + "/" + name;
#else
    std::string path = "tests/fixtures/" + name;
#endif
    std::ifstream f(path);
    if (!f)
        return {};
    std::ostringstream ss;
    ss << f.rdbuf();
    return ss.str();
}

TEST_CASE("DaemonEvent serializes with host_mutation=false", "[daemon]") {
    DaemonEvent evt;
    evt.kind = EventKind::Boot;
    evt.action_id = "act-1";
    evt.status = "PASS";
    evt.seq = 1;
    evt.reason = "daemon_ready";

    auto j = evt.to_json();
    std::string s = j.dump();
    REQUIRE(s.find("\"host_mutation\":false") != std::string::npos);
    REQUIRE(s.find("\"schema\":\"xsprof/daemon-event/v1\"") != std::string::npos);
    REQUIRE(s.find("\"event\":\"boot\"") != std::string::npos);
    REQUIRE(s.find("\"seq\":1") != std::string::npos);
}

TEST_CASE("DaemonEvent round-trips through JSON", "[daemon]") {
    DaemonEvent evt;
    evt.kind = EventKind::Refusal;
    evt.action_id = "act-99";
    evt.status = "REFUSE";
    evt.seq = 42;
    evt.reason = "refused_host";
    evt.run_id = "run-1";
    evt.target_id = "tgt-1";

    auto j = evt.to_json();
    DaemonEvent parsed;
    REQUIRE(event_from_json(j, parsed));
    REQUIRE(parsed.kind == EventKind::Refusal);
    REQUIRE(parsed.action_id == "act-99");
    REQUIRE(parsed.status == "REFUSE");
    REQUIRE(parsed.seq == 42);
    REQUIRE(parsed.reason == "refused_host");
    REQUIRE(parsed.run_id == "run-1");
    REQUIRE(parsed.target_id == "tgt-1");
}

TEST_CASE("event_from_json rejects host_mutation=true", "[daemon]") {
    auto j = xsprof::json::parse(
        R"({"schema":"xsprof/daemon-event/v1","event":"boot","action_id":"","status":"PASS","host_mutation":true,"seq":1})");
    DaemonEvent evt;
    REQUIRE_FALSE(event_from_json(j, evt));
}

TEST_CASE("event_from_json rejects wrong schema", "[daemon]") {
    auto j = xsprof::json::parse(
        R"({"schema":"wrong/v1","event":"boot","action_id":"","status":"PASS","host_mutation":false,"seq":1})");
    DaemonEvent evt;
    REQUIRE_FALSE(event_from_json(j, evt));
}

TEST_CASE("OperatorAction serializes correctly", "[daemon]") {
    OperatorAction act;
    act.kind = ActionKind::Preflight;
    act.action_id = "act-1";

    auto j = act.to_json();
    std::string s = j.dump();
    REQUIRE(s.find("\"schema\":\"xsprof/operator-action/v1\"") != std::string::npos);
    REQUIRE(s.find("\"action\":\"preflight\"") != std::string::npos);
}

TEST_CASE("action_from_json round-trips", "[daemon]") {
    OperatorAction act;
    act.kind = ActionKind::RunLabVm;
    act.action_id = "act-vm";
    act.audit_id = "audit-1";
    act.rollback_id = "rb-1";

    auto j = act.to_json();
    OperatorAction parsed;
    REQUIRE(action_from_json(j, parsed));
    REQUIRE(parsed.kind == ActionKind::RunLabVm);
    REQUIRE(parsed.action_id == "act-vm");
    REQUIRE(parsed.audit_id == "audit-1");
    REQUIRE(parsed.rollback_id == "rb-1");
}

TEST_CASE("action_from_json rejects unknown action", "[daemon]") {
    auto j =
        xsprof::json::parse(R"({"schema":"xsprof/operator-action/v1","action":"nonexistent"})");
    OperatorAction act;
    REQUIRE_FALSE(action_from_json(j, act));
}

TEST_CASE("Replay golden transcript succeeds with host_mutation=false", "[daemon]") {
    std::string golden = read_fixture("daemon_replay_golden.jsonl");
    REQUIRE(!golden.empty());

    auto result = replay_transcript(golden);
    REQUIRE(result.ok);
    REQUIRE(result.rows == 5);
    // Every line in output must have host_mutation:false.
    REQUIRE(result.output.find("\"host_mutation\":false") != std::string::npos);
    // Must NOT contain host_mutation:true.
    REQUIRE(result.output.find("\"host_mutation\":true") == std::string::npos);
}

TEST_CASE("Replay rejects non-monotonic seq", "[daemon]") {
    std::string bad =
        R"({"schema":"xsprof/daemon-event/v1","event":"boot","action_id":"","status":"PASS","host_mutation":false,"seq":5})"
        "\n"
        R"({"schema":"xsprof/daemon-event/v1","event":"marker","action_id":"","status":"PASS","host_mutation":false,"seq":3})"
        "\n";
    auto result = replay_transcript(bad);
    REQUIRE_FALSE(result.ok);
    REQUIRE(result.error.find("non-monotonic") != std::string::npos);
}

TEST_CASE("Replay rejects invalid JSON", "[daemon]") {
    std::string bad = "{not json}\n";
    auto result = replay_transcript(bad);
    REQUIRE_FALSE(result.ok);
    REQUIRE(result.error.find("invalid JSON") != std::string::npos);
}

TEST_CASE("Replay from_seq filters earlier events", "[daemon]") {
    std::string golden = read_fixture("daemon_replay_golden.jsonl");
    auto result = replay_transcript(golden, 3);
    REQUIRE(result.ok);
    REQUIRE(result.rows == 3); // seq 3, 4, 5
}

TEST_CASE("process_action_line handles preflight", "[daemon]") {
    std::uint64_t seq = 1;
    std::string line =
        R"({"schema":"xsprof/operator-action/v1","action":"preflight","action_id":"a1"})";
    std::string out = process_action_line(line, seq);
    REQUIRE(out.find("\"event\":\"marker\"") != std::string::npos);
    REQUIRE(out.find("\"status\":\"PASS\"") != std::string::npos);
    REQUIRE(out.find("\"host_mutation\":false") != std::string::npos);
    REQUIRE(seq == 2);
}

TEST_CASE("process_action_line refuses VM-lab actions on host", "[daemon]") {
    std::uint64_t seq = 1;
    std::string line =
        R"({"schema":"xsprof/operator-action/v1","action":"run_lab_vm","action_id":"a2"})";
    std::string out = process_action_line(line, seq);
    REQUIRE(out.find("\"event\":\"refusal\"") != std::string::npos);
    REQUIRE(out.find("\"status\":\"REFUSE\"") != std::string::npos);
    REQUIRE(out.find("\"host_mutation\":false") != std::string::npos);
}

TEST_CASE("process_action_line handles invalid JSON", "[daemon]") {
    std::uint64_t seq = 1;
    std::string out = process_action_line("{bad}", seq);
    REQUIRE(out.find("\"event\":\"incident\"") != std::string::npos);
    REQUIRE(out.find("\"host_mutation\":false") != std::string::npos);
}

TEST_CASE("run_foreground_stdio produces boot + action events", "[daemon]") {
    std::istringstream in(
        R"({"schema":"xsprof/operator-action/v1","action":"preflight","action_id":"a1"})"
        "\n"
        R"({"schema":"xsprof/operator-action/v1","action":"observe","action_id":"a2"})"
        "\n");
    std::ostringstream out;
    run_foreground_stdio(in, out);

    std::string output = out.str();
    // First line is boot event.
    REQUIRE(output.find("\"event\":\"boot\"") != std::string::npos);
    // Then preflight -> marker.
    REQUIRE(output.find("\"event\":\"marker\"") != std::string::npos);
    // Then observe -> runtime_sample.
    REQUIRE(output.find("\"event\":\"runtime_sample\"") != std::string::npos);
    // All have host_mutation:false.
    REQUIRE(output.find("\"host_mutation\":true") == std::string::npos);
}

TEST_CASE("JSON-RPC result format", "[daemon]") {
    xsprof::json::Value id("req-1");
    xsprof::json::Value result = xsprof::json::Value::make_object();
    result.set("host_mutation", xsprof::json::Value(false));
    auto rpc = rpc_result(id, result);
    std::string s = rpc.dump();
    REQUIRE(s.find("\"jsonrpc\":\"2.0\"") != std::string::npos);
    REQUIRE(s.find("\"id\":\"req-1\"") != std::string::npos);
    REQUIRE(s.find("\"result\"") != std::string::npos);
}

TEST_CASE("JSON-RPC error format with host_mutation=false", "[daemon]") {
    xsprof::json::Value id("req-2");
    auto rpc = rpc_error(id, -32600, "refused", "unsafe_verb_on_host");
    std::string s = rpc.dump();
    REQUIRE(s.find("\"jsonrpc\":\"2.0\"") != std::string::npos);
    REQUIRE(s.find("\"error\"") != std::string::npos);
    REQUIRE(s.find("\"host_mutation\":false") != std::string::npos);
    REQUIRE(s.find("\"status\":\"REFUSE\"") != std::string::npos);
}

TEST_CASE("All EventKind names are non-empty and unique", "[daemon]") {
    const EventKind all[] = {
        EventKind::Boot,          EventKind::Marker,        EventKind::Verifier,
        EventKind::Attach,        EventKind::StateChanged,  EventKind::StageStarted,
        EventKind::LabRunActive,  EventKind::StageFinished, EventKind::JournalRecord,
        EventKind::MicrovmBoot,   EventKind::VmMarker,      EventKind::BpfRegister,
        EventKind::RuntimeSample, EventKind::Rollback,      EventKind::RollbackCompleted,
        EventKind::Cleanup,       EventKind::Validation,    EventKind::Incident,
        EventKind::Refusal,
    };
    for (auto k : all) {
        auto name = event_kind_name(k);
        REQUIRE(!name.empty());
        REQUIRE(name != "unknown");
        // Round-trip.
        auto back = event_kind_from_name(name);
        REQUIRE(back.has_value());
        REQUIRE(*back == k);
    }
}

TEST_CASE("All ActionKind names are non-empty and unique", "[daemon]") {
    const ActionKind all[] = {
        ActionKind::Preflight,         ActionKind::RunLabHostSafe, ActionKind::RunLabVm,
        ActionKind::RunLabMicrovmLive, ActionKind::VerifierOnly,   ActionKind::PartialAttach,
        ActionKind::Observe,           ActionKind::Stop,           ActionKind::Rollback,
        ActionKind::StopLabRun,        ActionKind::RollbackLabRun, ActionKind::IncidentDrill,
    };
    for (auto k : all) {
        auto name = action_kind_name(k);
        REQUIRE(!name.empty());
        REQUIRE(name != "unknown");
        auto back = action_kind_from_name(name);
        REQUIRE(back.has_value());
        REQUIRE(*back == k);
    }
}
