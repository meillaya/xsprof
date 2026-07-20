// CLI integration tests — verify the xsprof binary refuses unsafe verbs with
// non-zero exit and that read-only commands succeed (QA-gate: unsafe_cli_matrix).
#include <catch2/catch_test_macros.hpp>

#include <cstdio>
#include <string>

namespace {

#ifndef XSPROF_CLI_BINARY_PATH
#define XSPROF_CLI_BINARY_PATH "./xsprof"
#endif

// Run the xsprof binary with the given arguments via popen, capturing stdout.
// Returns the exit code.
int run_xsprof(const std::string& args, std::string* out = nullptr) {
    std::string cmd = std::string(XSPROF_CLI_BINARY_PATH) + " " + args + " 2>/dev/null";
    std::FILE* pipe = popen(cmd.c_str(), "r");
    if (!pipe)
        return -1;
    if (out) {
        out->clear();
        char buf[4096];
        while (std::fgets(buf, sizeof(buf), pipe))
            *out += buf;
    } else {
        // Drain stdout to avoid SIGPIPE.
        char buf[4096];
        while (std::fgets(buf, sizeof(buf), pipe)) {
        }
    }
    int status = pclose(pipe);
    return WEXITSTATUS(status);
}

} // namespace

// ---------------------------------------------------------------------------
// QA-gate: unsafe_cli_matrix — every unsafe verb refuses with non-zero exit.
// ---------------------------------------------------------------------------

TEST_CASE("CLI refuses all unsafe verbs with non-zero exit", "[cli][unsafe_cli_matrix]") {
    const char* unsafe_verbs[] = {
        "load",        "attach",      "enable", "mutate", "apply", "sched-ext-attach",
        "setaffinity", "setpriority", "bind",
    };
    for (const char* verb : unsafe_verbs) {
        std::string out;
        int rc = run_xsprof(verb, &out);
        REQUIRE(rc != 0);
        // The refusal JSON must carry host_mutation=false.
        REQUIRE(out.find("\"host_mutation\":false") != std::string::npos);
        REQUIRE(out.find("\"event\":\"refusal\"") != std::string::npos);
    }
}

TEST_CASE("CLI refuses unknown verbs with non-zero exit (fail-closed)",
          "[cli][unsafe_cli_matrix]") {
    std::string out;
    int rc = run_xsprof("nonexistent-verb", &out);
    REQUIRE(rc != 0);
    REQUIRE(out.find("\"host_mutation\":false") != std::string::npos);
}

// ---------------------------------------------------------------------------
// QA-gate: read-only commands succeed with zero exit.
// ---------------------------------------------------------------------------

TEST_CASE("CLI help exits zero", "[cli][read_only]") {
    std::string out;
    int rc = run_xsprof("help", &out);
    REQUIRE(rc == 0);
    REQUIRE(out.find("xsprof") != std::string::npos);
}

TEST_CASE("CLI version exits zero", "[cli][read_only]") {
    std::string out;
    int rc = run_xsprof("version", &out);
    REQUIRE(rc == 0);
    REQUIRE(out.find("xsprof") != std::string::npos);
}

TEST_CASE("CLI preflight --json exits zero with host_mutation=false", "[cli][read_only]") {
    std::string out;
    int rc = run_xsprof("preflight --json", &out);
    REQUIRE(rc == 0);
    REQUIRE(out.find("\"host_mutation\":false") != std::string::npos);
    REQUIRE(out.find("\"schema\":\"xsprof/preflight/v1\"") != std::string::npos);
}

TEST_CASE("CLI capabilities --json exits zero", "[cli][read_only]") {
    std::string out;
    int rc = run_xsprof("capabilities --json", &out);
    REQUIRE(rc == 0);
    // Capability probes carry host_mutation=false.
    REQUIRE(out.find("\"host_mutation\":false") != std::string::npos);
}

TEST_CASE("CLI advise --json exits zero with host_mutation=false", "[cli][read_only]") {
    std::string out;
    int rc = run_xsprof("advise --json", &out);
    REQUIRE(rc == 0);
    REQUIRE(out.find("\"host_mutation\":false") != std::string::npos);
}

TEST_CASE("CLI advise --md exits zero and produces advisor report", "[cli][read_only]") {
    std::string out;
    int rc = run_xsprof("advise --md", &out);
    REQUIRE(rc == 0);
    // The markdown report always contains the advisor header.
    REQUIRE(out.find("Performance Advisor") != std::string::npos);
}
