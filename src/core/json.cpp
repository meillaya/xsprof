#include "xsprof/json.hpp"

#include <cmath>
#include <cstdio>

namespace xsprof::json {

std::string escape(std::string_view s) {
    std::string out;
    out.reserve(s.size() + 2);
    for (unsigned char c : s) {
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\b': out += "\\b"; break;
            case '\f': out += "\\f"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
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
        case Type::Null: out += "null"; break;
        case Type::Bool: out += bool_ ? "true" : "false"; break;
        case Type::Int: out += std::to_string(int_); break;
        case Type::Double: {
            if (std::isnan(double_) || std::isinf(double_)) { out += "null"; break; }
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
                if (!first) out += ',';
                first = false;
                if (pretty) { out += '\n'; append_indent(out, indent + 1); }
                v.dump_to(out, pretty, indent + 1);
            }
            if (pretty && !arr_.empty()) { out += '\n'; append_indent(out, indent); }
            out += ']';
            break;
        }
        case Type::Object: {
            out += '{';
            bool first = true;
            for (const auto& [k, v] : obj_) {
                if (!first) out += ',';
                first = false;
                if (pretty) { out += '\n'; append_indent(out, indent + 1); }
                out += '"';
                out += escape(k);
                out += '"';
                out += ':';
                if (pretty) out += ' ';
                v.dump_to(out, pretty, indent + 1);
            }
            if (pretty && !obj_.empty()) { out += '\n'; append_indent(out, indent); }
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
