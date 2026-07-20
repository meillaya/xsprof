// Daemon implementation — foreground stdio JSONL + replay.
// Mirrors the archived Zig daemon contract. Every record: host_mutation=false.

#include "xsprof/daemon.hpp"
#include "xsprof/safety.hpp"

#include <sstream>

namespace xsprof::daemon {

// --- EventKind name mapping ---

std::string_view event_kind_name(EventKind k) {
    switch (k) {
        case EventKind::Boot: return "boot";
        case EventKind::Marker: return "marker";
        case EventKind::Verifier: return "verifier";
        case EventKind::Attach: return "attach";
        case EventKind::StateChanged: return "state_changed";
        case EventKind::StageStarted: return "stage_started";
        case EventKind::LabRunActive: return "lab_run_active";
        case EventKind::StageFinished: return "stage_finished";
        case EventKind::JournalRecord: return "journal_record";
        case EventKind::MicrovmBoot: return "microvm_boot";
        case EventKind::VmMarker: return "vm_marker";
        case EventKind::BpfRegister: return "bpf_register";
        case EventKind::RuntimeSample: return "runtime_sample";
        case EventKind::Rollback: return "rollback";
        case EventKind::RollbackCompleted: return "rollback_completed";
        case EventKind::Cleanup: return "cleanup";
        case EventKind::Validation: return "validation";
        case EventKind::Incident: return "incident";
        case EventKind::Refusal: return "refusal";
    }
    return "unknown";
}

std::optional<EventKind> event_kind_from_name(std::string_view name) {
    if (name == "boot") return EventKind::Boot;
    if (name == "marker") return EventKind::Marker;
    if (name == "verifier") return EventKind::Verifier;
    if (name == "attach") return EventKind::Attach;
    if (name == "state_changed") return EventKind::StateChanged;
    if (name == "stage_started") return EventKind::StageStarted;
    if (name == "lab_run_active") return EventKind::LabRunActive;
    if (name == "stage_finished") return EventKind::StageFinished;
    if (name == "journal_record") return EventKind::JournalRecord;
    if (name == "microvm_boot") return EventKind::MicrovmBoot;
    if (name == "vm_marker") return EventKind::VmMarker;
    if (name == "bpf_register") return EventKind::BpfRegister;
    if (name == "runtime_sample") return EventKind::RuntimeSample;
    if (name == "rollback") return EventKind::Rollback;
    if (name == "rollback_completed") return EventKind::RollbackCompleted;
    if (name == "cleanup") return EventKind::Cleanup;
    if (name == "validation") return EventKind::Validation;
    if (name == "incident") return EventKind::Incident;
    if (name == "refusal") return EventKind::Refusal;
    return std::nullopt;
}

// --- ActionKind name mapping ---

std::string_view action_kind_name(ActionKind k) {
    switch (k) {
        case ActionKind::Preflight: return "preflight";
        case ActionKind::RunLabHostSafe: return "run_lab_host_safe";
        case ActionKind::RunLabVm: return "run_lab_vm";
        case ActionKind::RunLabMicrovmLive: return "run_lab_microvm_live";
        case ActionKind::VerifierOnly: return "verifier_only";
        case ActionKind::PartialAttach: return "partial_attach";
        case ActionKind::Observe: return "observe";
        case ActionKind::Stop: return "stop";
        case ActionKind::Rollback: return "rollback";
        case ActionKind::StopLabRun: return "stop_lab_run";
        case ActionKind::RollbackLabRun: return "rollback_lab_run";
        case ActionKind::IncidentDrill: return "incident_drill";
    }
    return "unknown";
}

std::optional<ActionKind> action_kind_from_name(std::string_view name) {
    if (name == "preflight") return ActionKind::Preflight;
    if (name == "run_lab_host_safe") return ActionKind::RunLabHostSafe;
    if (name == "run_lab_vm") return ActionKind::RunLabVm;
    if (name == "run_lab_microvm_live") return ActionKind::RunLabMicrovmLive;
    if (name == "verifier_only") return ActionKind::VerifierOnly;
    if (name == "partial_attach") return ActionKind::PartialAttach;
    if (name == "observe") return ActionKind::Observe;
    if (name == "stop") return ActionKind::Stop;
    if (name == "rollback") return ActionKind::Rollback;
    if (name == "stop_lab_run") return ActionKind::StopLabRun;
    if (name == "rollback_lab_run") return ActionKind::RollbackLabRun;
    if (name == "incident_drill") return ActionKind::IncidentDrill;
    return std::nullopt;
}

// --- DaemonEvent ---

json::Value DaemonEvent::to_json() const {
    json::Value v = json::Value::make_object();
    v.set("schema", json::Value(std::string(kEventSchema)));
    v.set("event", json::Value(std::string(event_kind_name(kind))));
    v.set("action_id", json::Value(action_id));
    v.set("status", json::Value(status));
    v.set("host_mutation", json::Value(false));
    v.set("seq", json::Value(seq));
    if (!run_id.empty()) v.set("run_id", json::Value(run_id));
    if (!target_id.empty()) v.set("target_id", json::Value(target_id));
    if (!audit_id.empty()) v.set("audit_id", json::Value(audit_id));
    if (!rollback_id.empty()) v.set("rollback_id", json::Value(rollback_id));
    if (!reason.empty()) v.set("reason", json::Value(reason));
    return v;
}

bool event_from_json(const json::Value& v, DaemonEvent& out) {
    if (!v.is_object()) return false;
    auto* schema = v.find("schema");
    if (!schema || schema->as_string() != kEventSchema) return false;
    auto* event = v.find("event");
    if (!event) return false;
    auto kind = event_kind_from_name(event->as_string());
    if (!kind) return false;
    out.kind = *kind;
    auto* aid = v.find("action_id");
    if (aid) out.action_id = aid->as_string();
    auto* st = v.find("status");
    if (st) out.status = st->as_string();
    auto* hm = v.find("host_mutation");
    if (hm && hm->as_bool()) return false; // must be false
    auto* sq = v.find("seq");
    if (sq) out.seq = static_cast<std::uint64_t>(sq->as_int());
    auto* rid = v.find("run_id");
    if (rid) out.run_id = rid->as_string();
    auto* tid = v.find("target_id");
    if (tid) out.target_id = tid->as_string();
    auto* aud = v.find("audit_id");
    if (aud) out.audit_id = aud->as_string();
    auto* rb = v.find("rollback_id");
    if (rb) out.rollback_id = rb->as_string();
    auto* rsn = v.find("reason");
    if (rsn) out.reason = rsn->as_string();
    return true;
}

// --- OperatorAction ---

json::Value OperatorAction::to_json() const {
    json::Value v = json::Value::make_object();
    v.set("schema", json::Value(std::string(kActionSchema)));
    v.set("action", json::Value(std::string(action_kind_name(kind))));
    if (!action_id.empty()) v.set("action_id", json::Value(action_id));
    if (!run_id.empty()) v.set("run_id", json::Value(run_id));
    if (!target_id.empty()) v.set("target_id", json::Value(target_id));
    if (!target_cgroup.empty()) v.set("target_cgroup", json::Value(target_cgroup));
    if (!audit_id.empty()) v.set("audit_id", json::Value(audit_id));
    if (!rollback_id.empty()) v.set("rollback_id", json::Value(rollback_id));
    if (!target_action_id.empty()) v.set("target_action_id", json::Value(target_action_id));
    return v;
}

bool action_from_json(const json::Value& v, OperatorAction& out) {
    if (!v.is_object()) return false;
    auto* schema = v.find("schema");
    if (!schema || schema->as_string() != kActionSchema) return false;
    auto* action = v.find("action");
    if (!action) return false;
    auto kind = action_kind_from_name(action->as_string());
    if (!kind) return false;
    out.kind = *kind;
    auto* aid = v.find("action_id");
    if (aid) out.action_id = aid->as_string();
    auto* rid = v.find("run_id");
    if (rid) out.run_id = rid->as_string();
    auto* tid = v.find("target_id");
    if (tid) out.target_id = tid->as_string();
    auto* tc = v.find("target_cgroup");
    if (tc) out.target_cgroup = tc->as_string();
    auto* aud = v.find("audit_id");
    if (aud) out.audit_id = aud->as_string();
    auto* rb = v.find("rollback_id");
    if (rb) out.rollback_id = rb->as_string();
    auto* ta = v.find("target_action_id");
    if (ta) out.target_action_id = ta->as_string();
    return true;
}

// --- JSON-RPC helpers ---

json::Value rpc_result(const json::Value& id, const json::Value& result) {
    json::Value v = json::Value::make_object();
    v.set("jsonrpc", json::Value("2.0"));
    v.set("id", id);
    v.set("result", result);
    return v;
}

json::Value rpc_error(const json::Value& id, int code, std::string_view message,
                      std::string_view incident_code) {
    json::Value v = json::Value::make_object();
    v.set("jsonrpc", json::Value("2.0"));
    v.set("id", id);
    json::Value err = json::Value::make_object();
    err.set("code", json::Value(code));
    err.set("message", json::Value(std::string(message)));
    json::Value data = json::Value::make_object();
    data.set("incident_code", json::Value(std::string(incident_code)));
    data.set("reason", json::Value(std::string(incident_code)));
    data.set("state", json::Value("refused_host"));
    data.set("status", json::Value("REFUSE"));
    data.set("host_mutation", json::Value(false));
    err.set("data", data);
    v.set("error", err);
    return v;
}

// --- Replay ---

ReplayResult replay_transcript(std::string_view jsonl_input, std::uint64_t from_seq) {
    ReplayResult result;
    std::string input_str(jsonl_input);
    std::istringstream stream(input_str);
    std::string line;
    std::uint64_t prev_seq = 0;

    while (std::getline(stream, line)) {
        // Trim whitespace.
        auto start = line.find_first_not_of(" \t\r\n");
        if (start == std::string::npos) continue;
        auto end = line.find_last_not_of(" \t\r\n");
        std::string trimmed = line.substr(start, end - start + 1);
        if (trimmed.empty()) continue;

        auto parsed = json::parse(trimmed);
        if (parsed.is_null()) {
            result.ok = false;
            result.error = "invalid JSON at row " + std::to_string(result.rows + 1);
            return result;
        }

        DaemonEvent evt;
        if (!event_from_json(parsed, evt)) {
            result.ok = false;
            result.error = "invalid daemon-event at row " + std::to_string(result.rows + 1);
            return result;
        }

        // Validate monotonically increasing seq.
        if (evt.seq > 0 && evt.seq <= prev_seq) {
            result.ok = false;
            result.error = "non-monotonic seq at row " + std::to_string(result.rows + 1);
            return result;
        }
        prev_seq = evt.seq;

        if (evt.seq < from_seq) continue;

        result.output += parsed.dump() + "\n";
        result.rows++;
    }

    return result;
}

// --- Action processing (stdio mode) ---

std::string process_action_line(std::string_view line, std::uint64_t& seq) {
    auto parsed = json::parse(line);
    if (parsed.is_null()) {
        DaemonEvent evt;
        evt.kind = EventKind::Incident;
        evt.action_id = "";
        evt.status = "REFUSE";
        evt.reason = "invalid_json";
        evt.seq = seq++;
        return evt.to_json().dump();
    }

    OperatorAction action;
    if (!action_from_json(parsed, action)) {
        DaemonEvent evt;
        evt.kind = EventKind::Refusal;
        evt.action_id = "";
        evt.status = "REFUSE";
        evt.reason = "unknown_action";
        evt.seq = seq++;
        return evt.to_json().dump();
    }

    // Process based on action kind.
    DaemonEvent evt;
    evt.action_id = action.action_id;
    evt.run_id = action.run_id;
    evt.target_id = action.target_id;
    evt.audit_id = action.audit_id;
    evt.rollback_id = action.rollback_id;
    evt.seq = seq++;

    switch (action.kind) {
        case ActionKind::Preflight:
            evt.kind = EventKind::Marker;
            evt.status = "PASS";
            evt.reason = "preflight_complete";
            break;
        case ActionKind::Observe:
            evt.kind = EventKind::RuntimeSample;
            evt.status = "PASS";
            evt.reason = "observing";
            break;
        case ActionKind::Stop:
            evt.kind = EventKind::Cleanup;
            evt.status = "PASS";
            evt.reason = "stopped";
            break;
        case ActionKind::RunLabHostSafe:
        case ActionKind::RunLabVm:
        case ActionKind::RunLabMicrovmLive:
        case ActionKind::VerifierOnly:
        case ActionKind::PartialAttach:
        case ActionKind::Rollback:
        case ActionKind::StopLabRun:
        case ActionKind::RollbackLabRun:
        case ActionKind::IncidentDrill:
            // These require VM-lab context; on host they refuse.
            evt.kind = EventKind::Refusal;
            evt.status = "REFUSE";
            evt.reason = "refused_host";
            break;
    }

    return evt.to_json().dump();
}

// --- Foreground stdio mode ---

void run_foreground_stdio(std::istream& in, std::ostream& out) {
    std::uint64_t seq = 1;

    // Emit boot event.
    DaemonEvent boot;
    boot.kind = EventKind::Boot;
    boot.action_id = "";
    boot.status = "PASS";
    boot.reason = "daemon_ready";
    boot.seq = seq++;
    out << boot.to_json().dump() << "\n";

    std::string line;
    while (std::getline(in, line)) {
        auto start = line.find_first_not_of(" \t\r\n");
        if (start == std::string::npos) continue;
        auto end = line.find_last_not_of(" \t\r\n");
        std::string trimmed = line.substr(start, end - start + 1);
        if (trimmed.empty()) continue;

        std::string response = process_action_line(trimmed, seq);
        out << response << "\n";
    }
}

} // namespace xsprof::daemon
