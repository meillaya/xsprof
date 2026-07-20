#include "xsprof/json.hpp"

#include <cmath>
#include <cstdio>

namespace xsprof::json {

std::string escape(std::string_view s) {
    std::string out;
    out.reserve(s.size() + 2);
    for (unsigned char c : s) {
        switch (c) {
        case '"':
            out += "\\\"";
            break;
        case '\\':
            out += "\\\\";
            break;
        case '\b':
            out += "\\b";
            break;
        case '\f':
            out += "\\f";
            break;
        case '\n':
            out += "\\n";
            break;
        case '\r':
            out += "\\r";
            break;
        case '\t':
            out += "\\t";
            break;
        default:
            if (c < 0x20) {
                char buf[8];
                std::snprintf(buf, sizeof(buf), "\\u%04x", c);
                out += buf;
            } else {
                out += static_cast<char>(c);
            }
        }
    }
    return out;
}

static void append_indent(std::string& out, int indent) {
    out.append(static_cast<std::size_t>(indent) * 2, ' ');
}

void Value::dump_to(std::string& out, bool pretty, int indent) const {
    switch (type_) {
    case Type::Null:
        out += "null";
        break;
    case Type::Bool:
        out += bool_ ? "true" : "false";
        break;
    case Type::Int:
        out += std::to_string(int_);
        break;
    case Type::Double: {
        if (std::isnan(double_) || std::isinf(double_)) {
            out += "null";
            break;
        }
        char buf[32];
        std::snprintf(buf, sizeof(buf), "%.17g", double_);
        out += buf;
        break;
    }
    case Type::String:
        out += '"';
        out += escape(str_);
        out += '"';
        break;
    case Type::Array: {
        out += '[';
        bool first = true;
        for (const auto& v : arr_) {
            if (!first)
                out += ',';
            first = false;
            if (pretty) {
                out += '\n';
                append_indent(out, indent + 1);
            }
            v.dump_to(out, pretty, indent + 1);
        }
        if (pretty && !arr_.empty()) {
            out += '\n';
            append_indent(out, indent);
        }
        out += ']';
        break;
    }
    case Type::Object: {
        out += '{';
        bool first = true;
        for (const auto& [k, v] : obj_) {
            if (!first)
                out += ',';
            first = false;
            if (pretty) {
                out += '\n';
                append_indent(out, indent + 1);
            }
            out += '"';
            out += escape(k);
            out += '"';
            out += ':';
            if (pretty)
                out += ' ';
            v.dump_to(out, pretty, indent + 1);
        }
        if (pretty && !obj_.empty()) {
            out += '\n';
            append_indent(out, indent);
        }
        out += '}';
        break;
    }
    }
}

std::string Value::dump(bool pretty) const {
    std::string out;
    dump_to(out, pretty, 0);
    return out;
}

} // namespace xsprof::json

// --- Minimal JSON parser (fixture/replay ingestion) -------------------------

namespace {

struct Parser {
    std::string_view s;
    std::size_t pos = 0;

    void skip_ws() {
        while (pos < s.size() &&
               (s[pos] == ' ' || s[pos] == '\t' || s[pos] == '\n' || s[pos] == '\r'))
            ++pos;
    }

    bool at_end() const { return pos >= s.size(); }
    char peek() const { return pos < s.size() ? s[pos] : '\0'; }
    char next() { return pos < s.size() ? s[pos++] : '\0'; }

    bool expect(char c) {
        skip_ws();
        if (peek() == c) {
            ++pos;
            return true;
        }
        return false;
    }

    xsprof::json::Value parse_value() {
        skip_ws();
        if (at_end())
            return {};
        char c = peek();
        if (c == '{')
            return parse_object();
        if (c == '[')
            return parse_array();
        if (c == '"')
            return parse_string_value();
        if (c == 't' || c == 'f')
            return parse_bool();
        if (c == 'n')
            return parse_null();
        if (c == '-' || (c >= '0' && c <= '9'))
            return parse_number();
        return {}; // parse error
    }

    xsprof::json::Value parse_object() {
        next(); // consume '{'
        xsprof::json::Value obj = xsprof::json::Value::make_object();
        skip_ws();
        if (peek() == '}') {
            next();
            return obj;
        }
        while (true) {
            skip_ws();
            if (peek() != '"')
                return {}; // error
            auto key = parse_string();
            if (!expect(':'))
                return {};
            auto val = parse_value();
            obj.set(key, std::move(val));
            skip_ws();
            if (peek() == ',') {
                next();
                continue;
            }
            if (peek() == '}') {
                next();
                break;
            }
            return {}; // error
        }
        return obj;
    }

    xsprof::json::Value parse_array() {
        next(); // consume '['
        xsprof::json::Value arr = xsprof::json::Value::make_array();
        skip_ws();
        if (peek() == ']') {
            next();
            return arr;
        }
        while (true) {
            arr.push_back(parse_value());
            skip_ws();
            if (peek() == ',') {
                next();
                continue;
            }
            if (peek() == ']') {
                next();
                break;
            }
            return {}; // error
        }
        return arr;
    }

    std::string parse_string() {
        next(); // consume opening '"'
        std::string out;
        while (!at_end()) {
            char c = next();
            if (c == '"')
                break;
            if (c == '\\') {
                char esc = next();
                switch (esc) {
                case '"':
                    out += '"';
                    break;
                case '\\':
                    out += '\\';
                    break;
                case '/':
                    out += '/';
                    break;
                case 'b':
                    out += '\b';
                    break;
                case 'f':
                    out += '\f';
                    break;
                case 'n':
                    out += '\n';
                    break;
                case 'r':
                    out += '\r';
                    break;
                case 't':
                    out += '\t';
                    break;
                case 'u': {
                    // Parse 4 hex digits (basic BMP only; surrogates passed through).
                    std::string hex;
                    for (int i = 0; i < 4 && !at_end(); ++i)
                        hex += next();
                    unsigned long cp = std::strtoul(hex.c_str(), nullptr, 16);
                    if (cp < 0x80) {
                        out += static_cast<char>(cp);
                    } else if (cp < 0x800) {
                        out += static_cast<char>(0xC0 | (cp >> 6));
                        out += static_cast<char>(0x80 | (cp & 0x3F));
                    } else {
                        out += static_cast<char>(0xE0 | (cp >> 12));
                        out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
                        out += static_cast<char>(0x80 | (cp & 0x3F));
                    }
                    break;
                }
                default:
                    out += esc;
                    break;
                }
            } else {
                out += c;
            }
        }
        return out;
    }

    xsprof::json::Value parse_string_value() { return xsprof::json::Value(parse_string()); }

    xsprof::json::Value parse_number() {
        std::size_t start = pos;
        bool is_double = false;
        if (peek() == '-')
            next();
        while (!at_end() && peek() >= '0' && peek() <= '9')
            next();
        if (peek() == '.') {
            is_double = true;
            next();
            while (!at_end() && peek() >= '0' && peek() <= '9')
                next();
        }
        if (peek() == 'e' || peek() == 'E') {
            is_double = true;
            next();
            if (peek() == '+' || peek() == '-')
                next();
            while (!at_end() && peek() >= '0' && peek() <= '9')
                next();
        }
        std::string num_str(s.substr(start, pos - start));
        if (is_double)
            return xsprof::json::Value(std::stod(num_str));
        return xsprof::json::Value(static_cast<long long>(std::stoll(num_str)));
    }

    xsprof::json::Value parse_bool() {
        if (s.substr(pos, 4) == "true") {
            pos += 4;
            return xsprof::json::Value(true);
        }
        if (s.substr(pos, 5) == "false") {
            pos += 5;
            return xsprof::json::Value(false);
        }
        return {};
    }

    xsprof::json::Value parse_null() {
        if (s.substr(pos, 4) == "null") {
            pos += 4;
            return xsprof::json::Value(nullptr);
        }
        return {};
    }
};

} // namespace

namespace xsprof::json {

Value parse(std::string_view input) {
    Parser p{input};
    auto v = p.parse_value();
    p.skip_ws();
    if (!p.at_end())
        return {}; // trailing garbage
    return v;
}

} // namespace xsprof::json
