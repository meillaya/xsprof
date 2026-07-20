// Catch2 v3 entry point (provided by Catch2WithMain). This file exists so the
// test target has a stable translation unit; the main() comes from the library.
#include <catch2/catch_test_macros.hpp>

// Sanity: the framework is linked and runs.
TEST_CASE("test framework is alive", "[meta]") {
    REQUIRE(1 + 1 == 2);
}
