#include <catch2/catch_test_macros.hpp>
#include <string>

#include "xsprof/json.hpp"

using xsprof::json::Value;

TEST_CASE("json object serialization is deterministic and typed", "[json]") {
    Value v = Value::make_object();
    v.set("schema", Value("xsprof/event/v1"));
    v.set("count", Value(42));
    v.set("ratio", Value(0.5));
    v.set("ok", Value(true));
    v.set("host_mutation", Value(false));
    Value arr = Value::make_array();
    arr.push_back(Value(1));
    arr.push_back(Value(2));
    v.set("xs", arr);

    const std::string s = v.dump();
    REQUIRE(s.find("\"schema\":\"xsprof/event/v1\"") != std::string::npos);
    REQUIRE(s.find("\"count\":42") != std::string::npos);
    REQUIRE(s.find("\"ok\":true") != std::string::npos);
    REQUIRE(s.find("\"host_mutation\":false") != std::string::npos);
    REQUIRE(s.find("\"xs\":[1,2]") != std::string::npos);
}

TEST_CASE("json string escaping", "[json]") {
    REQUIRE(Value(std::string("a\"b\\c\n")).dump() == "\"a\\\"b\\\\c\\n\"");
    REQUIRE(Value(std::string("tab\there")).dump().find("\\t") != std::string::npos);
}

TEST_CASE("json accessors", "[json]") {
    Value v = Value::make_object();
    v.set("a", Value(7));
    REQUIRE(v.contains("a"));
    REQUIRE(v.find("a")->as_int() == 7);
    REQUIRE(v.find("missing") == nullptr);
}
