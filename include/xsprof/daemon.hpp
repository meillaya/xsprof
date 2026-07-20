// xsprof daemon — foreground stdio JSONL + local UDS JSON-RPC + replay.
// Mirrors the archived Zig daemon contract (daemon-event/v1, operator-action/v1).
// Every record carries host_mutation=false. Replay reproduces a golden transcript.
#pragma once

#include <cstdint>
#include <functional>
#include <iostream>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "xsprof/json.hpp"

namespace xsprof::daemon {

// Schema identifiers matching the Zig protocol.
inline constexpr std::string_view kEventSchema = "xsprof/daemon-event/v1";
inline constexpr std::string_view kActionSchema = "xsprof/operator-action/v1";

// Event kinds mirroring the Zig EventKind enum.
enum class EventKind {
    Boot,
    Marker,
    Verifier,
    Attach,
    StateChanged,
    StageStarted,
    LabRunActive,
    StageFinished,
    JournalRecord,
    MicrovmBoot,
    VmMarker,
    BpfRegister,
    RuntimeSample,
    Rollback,
    RollbackCompleted,
    Cleanup,
    Validation,
    Incident,
    Refusal,
};

std::string_view event_kind_name(EventKind k);
std::optional<EventKind> event_kind_from_name(std::string_view name);

// Action kinds mirroring the Zig ActionKind enum.
enum class ActionKind {
    Preflight,
    RunLabHostSafe,
    RunLabVm,
    RunLabMicrovmLive,
    VerifierOnly,
    PartialAttach,
    Observe,
    Stop,
    Rollback,
    StopLabRun,
    RollbackLabRun,
    IncidentDrill,
};

std::string_view action_kind_name(ActionKind k);
std::optional<ActionKind> action_kind_from_name(std::string_view name);

// A daemon event record. Always host_mutation=false.
struct DaemonEvent {
    EventKind kind = EventKind::Marker;
    std::string action_id;
    std::string status;
    std::string run_id;
    std::string target_id;
    std::string audit_id;
    std::string rollback_id;
    std::string reason;
    std::uint64_t seq = 0;

    json::Value to_json() const;
};

// Parse a daemon event from a JSON value. Returns false on invalid input.
bool event_from_json(const json::Value& v, DaemonEvent& out);

// An operator action request.
struct OperatorAction {
    ActionKind kind = ActionKind::Preflight;
    std::string action_id;
    std::string run_id;
    std::string target_id;
    std::string target_cgroup;
    std::string audit_id;
    std::string rollback_id;
    std::string target_action_id;

    json::Value to_json() const;
};

// Parse an operator action from a JSON value. Returns false on invalid input.
bool action_from_json(const json::Value& v, OperatorAction& out);

// JSON-RPC 2.0 response helpers.
json::Value rpc_result(const json::Value& id, const json::Value& result);
json::Value rpc_error(const json::Value& id, int code, std::string_view message,
                      std::string_view incident_code);

// Replay a JSONL transcript (one JSON object per line).
// Validates each row is a valid daemon-event with host_mutation=false.
// Returns the concatenated output and the number of rows replayed.
struct ReplayResult {
    std::string output;
    std::size_t rows = 0;
    bool ok = true;
    std::string error;
};

ReplayResult replay_transcript(std::string_view jsonl_input,
                               std::uint64_t from_seq = 0);

// Process a single operator action line (stdio mode).
// Returns the daemon event JSON line to emit.
std::string process_action_line(std::string_view line, std::uint64_t& seq);

// Foreground stdio JSONL mode: reads actions from input, writes events to output.
void run_foreground_stdio(std::istream& in, std::ostream& out);

} // namespace xsprof::daemon
