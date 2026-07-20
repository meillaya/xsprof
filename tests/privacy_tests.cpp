#include <catch2/catch_test_macros.hpp>
#include <string>

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
