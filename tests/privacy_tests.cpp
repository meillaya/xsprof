#include <catch2/catch_test_macros.hpp>
#include <string>

#include "xsprof/event.hpp"
#include "xsprof/privacy.hpp"

using xsprof::PrivacyFilter;

TEST_CASE("privacy filter detects sensitive keys", "[privacy]") {
    PrivacyFilter pf;
    REQUIRE(pf.sensitive_key("api_key"));
    REQUIRE(pf.sensitive_key("DB_PASSWORD"));
    REQUIRE(pf.sensitive_key("auth_token"));
    REQUIRE(pf.sensitive_key("AWS_SECRET_ACCESS"));
    REQUIRE_FALSE(pf.sensitive_key("cpu_usage"));
    REQUIRE_FALSE(pf.sensitive_key("run_queue"));
}

TEST_CASE("privacy filter redacts secret key=value pairs", "[privacy]") {
    PrivacyFilter pf;
    const std::string red = pf.redact("user=alice password=hunter2 cpu=10 token=abc");
    REQUIRE(red.find("password=[REDACTED]") != std::string::npos);
    REQUIRE(red.find("token=[REDACTED]") != std::string::npos);
    REQUIRE(red.find("user=alice") != std::string::npos);
    REQUIRE(red.find("hunter2") == std::string::npos);
}

TEST_CASE("privacy filter flags secret-looking values", "[privacy]") {
    PrivacyFilter pf;
    REQUIRE(pf.sensitive_value("Bearer xyz"));
    REQUIRE(pf.sensitive_value("-----BEGIN PRIVATE KEY-----"));
}

TEST_CASE("comm is bounded to the kernel limit", "[privacy]") {
    REQUIRE(PrivacyFilter::bound_comm("a-very-long-command-name").size() <= 15);
    REQUIRE(PrivacyFilter::bound_comm("short").size() == 5);
}

TEST_CASE("sanitize_event bounds comm and redacts detail", "[privacy]") {
    xsprof::PrivacyFilter pf;

    SECTION("comm is bounded to 15 chars") {
        xsprof::RawEvent e;
        e.kind = xsprof::EventKind::RuntimeSample;
        e.comm = "a-very-long-process-name-that-exceeds-limit";
        xsprof::sanitize_event(e, pf);
        REQUIRE(e.comm.size() <= 15);
    }

    SECTION("sensitive key=value pairs are redacted") {
        xsprof::RawEvent e;
        e.kind = xsprof::EventKind::RuntimeSample;
        e.comm = "worker";
        e.detail = "api_key=sk-secret123 cpu=99 password=hunter2";
        xsprof::sanitize_event(e, pf);
        REQUIRE(e.detail.find("sk-secret123") == std::string::npos);
        REQUIRE(e.detail.find("hunter2") == std::string::npos);
        REQUIRE(e.detail.find("api_key=[REDACTED]") != std::string::npos);
        REQUIRE(e.detail.find("password=[REDACTED]") != std::string::npos);
        REQUIRE(e.detail.find("cpu=99") != std::string::npos);
    }

    SECTION("secret-looking values are redacted via sensitive keys") {
        xsprof::RawEvent e;
        e.kind = xsprof::EventKind::RuntimeSample;
        e.detail = "auth=Bearer_eyJhbGciOiJIUzI1NiJ9 cpu=5";
        xsprof::sanitize_event(e, pf);
        REQUIRE(e.detail.find("eyJhbGciOiJIUzI1NiJ9") == std::string::npos);
        REQUIRE(e.detail.find("auth=[REDACTED]") != std::string::npos);
        REQUIRE(e.detail.find("cpu=5") != std::string::npos);
    }

    SECTION("empty comm/detail are safe no-ops") {
        xsprof::RawEvent e;
        e.kind = xsprof::EventKind::Marker;
        xsprof::sanitize_event(e, pf);
        REQUIRE(e.comm.empty());
        REQUIRE(e.detail.empty());
    }
}

TEST_CASE("event_to_json applies privacy sanitization", "[privacy]") {
    xsprof::RawEvent e;
    e.kind = xsprof::EventKind::RuntimeSample;
    e.ts_ns = 1000;
    e.cpu = 0;
    e.pid = 1;
    e.tid = 1;
    e.comm = "a-very-long-process-name-that-exceeds-limit";
    e.detail = "token=ghp_secret123 run_queue=5";
    auto j = xsprof::event_to_json(e);
    std::string s = j.dump();
    // comm must be bounded.
    REQUIRE(s.find("a-very-long-process-name") == std::string::npos);
    // secret must be redacted.
    REQUIRE(s.find("ghp_secret123") == std::string::npos);
    REQUIRE(s.find("token=[REDACTED]") != std::string::npos);
    // non-sensitive data preserved.
    REQUIRE(s.find("run_queue=5") != std::string::npos);
    // host_mutation invariant.
    REQUIRE(s.find("\"host_mutation\":false") != std::string::npos);
}
