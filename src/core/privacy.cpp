#include "xsprof/privacy.hpp"

#include <array>
#include <cctype>

namespace xsprof {

namespace {

bool contains_ci(std::string_view hay, std::string_view needle) {
    if (needle.empty() || hay.size() < needle.size())
        return false;
    for (std::size_t i = 0; i + needle.size() <= hay.size(); ++i) {
        bool match = true;
        for (std::size_t j = 0; j < needle.size(); ++j) {
            if (std::tolower(static_cast<unsigned char>(hay[i + j])) !=
                std::tolower(static_cast<unsigned char>(needle[j]))) {
                match = false;
                break;
            }
        }
        if (match)
            return true;
    }
    return false;
}

constexpr std::array<std::string_view, 12> kSensitiveKeys = {
    "secret", "api_key",    "apikey", "api-key",     "token",      "password",
    "passwd", "credential", "auth",   "private_key", "access_key", "session_id",
};

// High-entropy-ish secret value markers.
constexpr std::array<std::string_view, 6> kSecretValueMarkers = {
    "-----begin", "bearer", "sk-", "ghp_", "xox", "aws_secret",
};

} // namespace

PrivacyFilter::PrivacyFilter()
    : pattern_("secret|api[_-]?key|token|password|passwd|credential|auth|private[_-]?key") {}

PrivacyFilter::PrivacyFilter(std::string redaction_pattern)
    : pattern_(std::move(redaction_pattern)) {}

bool PrivacyFilter::sensitive_key(std::string_view key) const {
    for (auto k : kSensitiveKeys) {
        if (contains_ci(key, k))
            return true;
    }
    return false;
}

bool PrivacyFilter::sensitive_value(std::string_view value) const {
    for (auto m : kSecretValueMarkers) {
        if (contains_ci(value, m))
            return true;
    }
    return false;
}

std::string PrivacyFilter::redact(std::string_view detail) const {
    std::string out;
    out.reserve(detail.size());
    std::size_t i = 0;
    while (i < detail.size()) {
        // Find a key=value or key: value token boundary.
        std::size_t start = i;
        while (i < detail.size() && detail[i] != ' ' && detail[i] != ',' && detail[i] != ';')
            ++i;
        std::string_view tok = detail.substr(start, i - start);
        auto eq = tok.find_first_of("=:");
        if (eq != std::string_view::npos) {
            std::string_view key = tok.substr(0, eq);
            std::string_view val = tok.substr(eq + 1);
            if (sensitive_key(key) || sensitive_value(val)) {
                out.append(key);
                out += "=";
                out.append(kRedacted);
            } else {
                out.append(tok);
            }
        } else {
            if (sensitive_value(tok)) {
                out.append(kRedacted);
            } else {
                out.append(tok);
            }
        }
        if (i < detail.size()) {
            out += detail[i];
            ++i;
        }
    }
    return out;
}

std::string PrivacyFilter::bound_comm(std::string_view comm, bool pseudonymize) {
    std::string c(comm.substr(0, 15)); // TASK_COMM_LEN is 16 incl. NUL
    if (pseudonymize) {
        // Stable, non-reversible label.
        std::size_t h = 1469598103934665603ULL;
        for (unsigned char ch : c) {
            h ^= ch;
            h *= 1099511628211ULL;
        }
        char buf[24];
        std::snprintf(buf, sizeof(buf), "task_%08llx",
                      static_cast<unsigned long long>(h & 0xffffffffULL));
        return buf;
    }
    return c;
}

void sanitize_event(RawEvent& e, const PrivacyFilter& pf) {
    // Bound comm to the kernel TASK_COMM_LEN (16 bytes incl. NUL -> 15 chars).
    if (!e.comm.empty()) {
        e.comm = PrivacyFilter::bound_comm(e.comm);
    }
    // Redact sensitive material from the detail string.
    if (!e.detail.empty()) {
        e.detail = pf.redact(e.detail);
    }
}

} // namespace xsprof
