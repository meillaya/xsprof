// xsprof::json — a small, dependency-free JSON value + serializer.
// Used for the preflight report, evidence journal, advisor report, and the
// Chrome Trace export. Kept minimal and deterministic so golden tests are
// byte-stable. No parsing is required for output; a tiny parser exists for
// fixture/replay ingestion.
#pragma once

#include <cstdint>
#include <map>
#include <memory>
#include <string>
#include <string_view>
#include <variant>
#include <vector>

namespace xsprof::json {

class Value;
using Array = std::vector<Value>;
// Ordered map keeps golden output deterministic (std::map sorts keys).
using Object = std::map<std::string, Value>;

class Value {
  public:
    enum class Type { Null, Bool, Int, Double, String, Array, Object };

    Value() : type_(Type::Null) {}
    Value(std::nullptr_t) : type_(Type::Null) {}
    Value(bool b) : type_(Type::Bool), bool_(b) {}
    Value(int i) : type_(Type::Int), int_(i) {}
    Value(long i) : type_(Type::Int), int_(i) {}
    Value(long long i) : type_(Type::Int), int_(i) {}
    Value(unsigned u) : type_(Type::Int), int_(static_cast<long long>(u)) {}
    Value(unsigned long u) : type_(Type::Int), int_(static_cast<long long>(u)) {}
    Value(unsigned long long u) : type_(Type::Int), int_(static_cast<long long>(u)) {}
    Value(double d) : type_(Type::Double), double_(d) {}
    Value(const char* s) : type_(Type::String), str_(s) {}
    Value(std::string s) : type_(Type::String), str_(std::move(s)) {}
    Value(std::string_view s) : type_(Type::String), str_(s) {}
    Value(Array a) : type_(Type::Array), arr_(std::move(a)) {}
    Value(Object o) : type_(Type::Object), obj_(std::move(o)) {}

    static Value make_array() {
        Value v;
        v.type_ = Type::Array;
        return v;
    }
    static Value make_object() {
        Value v;
        v.type_ = Type::Object;
        return v;
    }

    Type type() const { return type_; }
    bool is_null() const { return type_ == Type::Null; }
    bool is_object() const { return type_ == Type::Object; }
    bool is_array() const { return type_ == Type::Array; }

    // Object accessors.
    Value& operator[](const std::string& key) {
        if (type_ != Type::Object) {
            type_ = Type::Object;
            obj_.clear();
        }
        return obj_[key];
    }
    void set(const std::string& key, Value v) {
        if (type_ != Type::Object) {
            type_ = Type::Object;
            obj_.clear();
        }
        obj_[key] = std::move(v);
    }
    bool contains(const std::string& key) const {
        return type_ == Type::Object && obj_.count(key) != 0;
    }
    const Value* find(const std::string& key) const {
        if (type_ != Type::Object)
            return nullptr;
        auto it = obj_.find(key);
        return it == obj_.end() ? nullptr : &it->second;
    }
    const Object& as_object() const { return obj_; }

    // Array accessors.
    void push_back(Value v) {
        if (type_ != Type::Array) {
            type_ = Type::Array;
            arr_.clear();
        }
        arr_.push_back(std::move(v));
    }
    const Array& as_array() const { return arr_; }
    std::size_t size() const {
        if (type_ == Type::Array)
            return arr_.size();
        if (type_ == Type::Object)
            return obj_.size();
        return 0;
    }

    // Scalar accessors.
    bool as_bool() const { return type_ == Type::Bool ? bool_ : false; }
    long long as_int() const { return type_ == Type::Int ? int_ : 0; }
    double as_double() const {
        if (type_ == Type::Double)
            return double_;
        if (type_ == Type::Int)
            return static_cast<double>(int_);
        return 0.0;
    }
    const std::string& as_string() const {
        static const std::string empty;
        return type_ == Type::String ? str_ : empty;
    }

    std::string dump(bool pretty = false) const;

  private:
    void dump_to(std::string& out, bool pretty, int indent) const;

    Type type_;
    bool bool_ = false;
    long long int_ = 0;
    double double_ = 0.0;
    std::string str_;
    Array arr_;
    Object obj_;
};

// Escape a string for JSON (quotes, control chars, backslash).
std::string escape(std::string_view s);

// Minimal recursive-descent JSON parser for fixture/replay ingestion.
// Returns a Null value on parse error; check is_null() to detect failure.
Value parse(std::string_view input);

} // namespace xsprof::json
