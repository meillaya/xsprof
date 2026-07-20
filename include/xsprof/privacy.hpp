// Privacy filter: runtime samples must never expose argv, environment, or
// secrets. Mirrors src/control/stream.zig + qa/runtime_sample_* checks from
// the archived Zig project.
#pragma once

#include <string>
#include <string_view>

namespace xsprof {

class PrivacyFilter {
public:
    // Default pattern: secret|api[_-]?key|token|password|passwd|credential|auth|private[_-]?key
    PrivacyFilter();
    explicit PrivacyFilter(std::string redaction_pattern);

    bool sensitive_key(std::string_view key) const;
    bool sensitive_value(std::string_view value) const;

    // Redact a free-form detail string: any key=value whose key is sensitive,
    // or whose value looks like a secret, becomes key=[REDACTED].
    std::string redact(std::string_view detail) const;

    // Bound a comm to the kernel 16-byte limit and optionally pseudonymize.
    static std::string bound_comm(std::string_view comm, bool pseudonymize = false);

    static constexpr std::string_view kRedacted = "[REDACTED]";

private:
    std::string pattern_;
};

} // namespace xsprof
