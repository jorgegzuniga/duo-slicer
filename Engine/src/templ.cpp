#include "templ.hpp"

#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <stdexcept>
#include <vector>

namespace a1 {
using json = nlohmann::json;

std::string fmtNum(double v) {
    if (std::isnan(v) || std::isinf(v)) return "0";
    if (std::fabs(v - std::round(v)) < 1e-9 && std::fabs(v) < 1e15) {
        char b[32];
        std::snprintf(b, sizeof b, "%lld", (long long)std::llround(v));
        return b;
    }
    char b[64];
    std::snprintf(b, sizeof b, "%.4f", v);
    std::string s = b;
    while (!s.empty() && s.back() == '0') s.pop_back();
    if (!s.empty() && s.back() == '.') s.pop_back();
    if (s == "-0") s = "0";
    return s;
}

namespace {

struct Val {
    bool isStr = false;
    double num = 0;
    std::string str;
    static Val N(double d) { Val v; v.num = d; return v; }
    static Val S(std::string s) { Val v; v.isStr = true; v.str = std::move(s); return v; }
    bool numeric(double& out) const {
        if (!isStr) { out = num; return true; }
        const char* p = str.c_str();
        char* end = nullptr;
        double d = std::strtod(p, &end);
        if (end == p) return false;
        while (*end == ' ') ++end;
        if (*end == '%') ++end;
        if (*end != 0) return false;
        out = d;
        return true;
    }
    double asNum() const { double d = 0; numeric(d); return d; }
    bool truthy() const {
        if (!isStr) return num != 0;
        double d;
        if (numeric(d)) return d != 0;
        return !str.empty() && str != "false";
    }
    std::string text() const { return isStr ? str : fmtNum(num); }
};

Val fromJson(const json& j) {
    if (j.is_string()) return Val::S(j.get<std::string>());
    if (j.is_boolean()) return Val::N(j.get<bool>() ? 1 : 0);
    if (j.is_number()) return Val::N(j.get<double>());
    return Val::S("");
}

class Parser {
public:
    Parser(const std::string& s, const VarLookup& v, int di) : s_(s), vars_(v), di_(di) {}
    Val parse() {
        Val r = orExpr();
        ws();
        if (p_ < s_.size()) throw std::runtime_error("unexpected '" + s_.substr(p_) + "'");
        return r;
    }

private:
    const std::string& s_;
    const VarLookup& vars_;
    int di_;
    size_t p_ = 0;
    void ws() { while (p_ < s_.size() && std::isspace((unsigned char)s_[p_])) ++p_; }
    bool eat(const char* t) {
        ws();
        size_t n = std::char_traits<char>::length(t);
        if (s_.compare(p_, n, t) == 0) { p_ += n; return true; }
        return false;
    }
    Val orExpr() {
        Val l = andExpr();
        while (eat("||") || eat(" or ")) { Val r = andExpr(); l = Val::N(l.truthy() || r.truthy()); }
        return l;
    }
    Val andExpr() {
        Val l = cmpExpr();
        while (eat("&&") || eat(" and ")) { Val r = cmpExpr(); l = Val::N(l.truthy() && r.truthy()); }
        return l;
    }
    Val cmpExpr() {
        Val l = addExpr();
        for (;;) {
            const char* ops[] = {"==", "!=", "<=", ">=", "<", ">"};
            int op = -1;
            ws();
            for (int i = 0; i < 6; ++i)
                if (s_.compare(p_, std::char_traits<char>::length(ops[i]), ops[i]) == 0) { op = i; p_ += std::char_traits<char>::length(ops[i]); break; }
            if (op < 0) return l;
            Val r = addExpr();
            double a, b;
            bool num = l.numeric(a) && r.numeric(b);
            bool res;
            if (num) {
                switch (op) { case 0: res = std::fabs(a - b) < 1e-9; break; case 1: res = std::fabs(a - b) >= 1e-9; break;
                    case 2: res = a <= b; break; case 3: res = a >= b; break; case 4: res = a < b; break; default: res = a > b; }
            } else {
                std::string x = l.text(), y = r.text();
                switch (op) { case 0: res = x == y; break; case 1: res = x != y; break; case 2: res = x <= y; break;
                    case 3: res = x >= y; break; case 4: res = x < y; break; default: res = x > y; }
            }
            l = Val::N(res);
        }
    }
    Val addExpr() {
        Val l = mulExpr();
        for (;;) {
            ws();
            if (p_ < s_.size() && s_[p_] == '+') { ++p_; Val r = mulExpr(); l = Val::N(l.asNum() + r.asNum()); }
            else if (p_ < s_.size() && s_[p_] == '-') { ++p_; Val r = mulExpr(); l = Val::N(l.asNum() - r.asNum()); }
            else return l;
        }
    }
    Val mulExpr() {
        Val l = unary();
        for (;;) {
            ws();
            if (p_ < s_.size() && s_[p_] == '*') { ++p_; Val r = unary(); l = Val::N(l.asNum() * r.asNum()); }
            else if (p_ < s_.size() && s_[p_] == '/') { ++p_; Val r = unary(); double d = r.asNum(); l = Val::N(d == 0 ? 0 : l.asNum() / d); }
            else if (p_ < s_.size() && s_[p_] == '%') { ++p_; Val r = unary(); double d = r.asNum(); l = Val::N(d == 0 ? 0 : std::fmod(l.asNum(), d)); }
            else return l;
        }
    }
    Val unary() {
        ws();
        if (p_ < s_.size() && s_[p_] == '!') { ++p_; return Val::N(!unary().truthy()); }
        if (p_ < s_.size() && s_[p_] == '-') { ++p_; return Val::N(-unary().asNum()); }
        if (p_ < s_.size() && s_[p_] == '+') { ++p_; return unary(); }
        if (s_.compare(p_, 4, "not ") == 0) { p_ += 4; return Val::N(!unary().truthy()); }
        return primary();
    }
    Val primary() {
        ws();
        if (p_ >= s_.size()) throw std::runtime_error("unexpected end");
        char c = s_[p_];
        if (c == '(') {
            ++p_;
            Val v = orExpr();
            if (!eat(")")) throw std::runtime_error("missing )");
            return v;
        }
        if (c == '"') {
            size_t e = s_.find('"', p_ + 1);
            if (e == std::string::npos) throw std::runtime_error("unterminated string");
            Val v = Val::S(s_.substr(p_ + 1, e - p_ - 1));
            p_ = e + 1;
            return v;
        }
        if (std::isdigit((unsigned char)c) || c == '.') {
            char* end = nullptr;
            double d = std::strtod(s_.c_str() + p_, &end);
            p_ = end - s_.c_str();
            return Val::N(d);
        }
        if (std::isalpha((unsigned char)c) || c == '_') {
            size_t b = p_;
            while (p_ < s_.size() && (std::isalnum((unsigned char)s_[p_]) || s_[p_] == '_')) ++p_;
            std::string name = s_.substr(b, p_ - b);
            if (name == "true") return Val::N(1);
            if (name == "false") return Val::N(0);
            // functions
            ws();
            if (p_ < s_.size() && s_[p_] == '(' && (name == "min" || name == "max" || name == "int" || name == "round" || name == "abs")) {
                ++p_;
                Val a = orExpr();
                Val b2;
                bool two = eat(",");
                if (two) b2 = orExpr();
                if (!eat(")")) throw std::runtime_error("missing )");
                double x = a.asNum();
                if (name == "min") return Val::N(two ? std::min(x, b2.asNum()) : x);
                if (name == "max") return Val::N(two ? std::max(x, b2.asNum()) : x);
                if (name == "int") return Val::N(std::trunc(x));
                if (name == "round") return Val::N(std::round(x));
                return Val::N(std::fabs(x));
            }
            json j = vars_(name);
            if (j.is_null()) throw std::runtime_error("unknown variable " + name);
            if (p_ < s_.size() && s_[p_] == '[') {
                ++p_;
                int idx = (int)orExpr().asNum();
                if (!eat("]")) throw std::runtime_error("missing ]");
                if (j.is_array()) {
                    if (j.empty()) return Val::S("");
                    idx = std::max(0, std::min(idx, (int)j.size() - 1));
                    return fromJson(j[idx]);
                }
                return fromJson(j);
            }
            if (j.is_array()) {
                if (j.empty()) return Val::S("");
                int idx = std::max(0, std::min(di_, (int)j.size() - 1));
                return fromJson(j[idx]);
            }
            return fromJson(j);
        }
        throw std::runtime_error(std::string("unexpected '") + c + "'");
    }
};

Val evalExpr(const std::string& e, const VarLookup& v, int di) {
    Parser p(e, v, di);
    return p.parse();
}

}  // namespace

std::string renderTemplate(const std::string& t, const VarLookup& vars, int di, std::string* error) {
    std::string out;
    out.reserve(t.size() + 256);
    // condition stack: each frame = (parentActive, thisBranchActive, anyBranchTaken)
    struct Frame { bool parent, active, taken; };
    std::vector<Frame> st;
    auto active = [&]() { return st.empty() || st.back().active; };
    size_t i = 0, n = t.size();
    while (i < n) {
        char c = t[i];
        if (c == '{') {
            size_t e = t.find('}', i);
            if (e == std::string::npos) { if (active()) out += t.substr(i); break; }
            std::string body = t.substr(i + 1, e - i - 1);
            size_t b = body.find_first_not_of(" \t");
            std::string trimmed = b == std::string::npos ? "" : body.substr(b);
            try {
                if (trimmed.rfind("if ", 0) == 0 || trimmed.rfind("if(", 0) == 0) {
                    bool par = active();
                    bool cond = par && evalExpr(trimmed.substr(2), vars, di).truthy();
                    st.push_back({par, cond, cond});
                } else if (trimmed.rfind("elsif ", 0) == 0 || trimmed.rfind("elsif(", 0) == 0) {
                    if (st.empty()) throw std::runtime_error("elsif without if");
                    Frame& f = st.back();
                    bool cond = f.parent && !f.taken && evalExpr(trimmed.substr(5), vars, di).truthy();
                    f.active = cond;
                    f.taken = f.taken || cond;
                } else if (trimmed.rfind("else", 0) == 0 && trimmed.find_first_not_of(" \t", 4) == std::string::npos) {
                    if (st.empty()) throw std::runtime_error("else without if");
                    Frame& f = st.back();
                    f.active = f.parent && !f.taken;
                    f.taken = true;
                } else if (trimmed.rfind("endif", 0) == 0) {
                    if (st.empty()) throw std::runtime_error("endif without if");
                    st.pop_back();
                } else if (active()) {
                    out += evalExpr(body, vars, di).text();
                }
            } catch (const std::exception& ex) {
                if (error && error->empty()) *error = std::string(ex.what()) + " in {" + body + "}";
                if (active()) out += "0";
            }
            i = e + 1;
            continue;
        }
        if (c == '[' && active()) {
            // [name] or [name[expr]]
            size_t j = i + 1;
            while (j < n && (std::isalnum((unsigned char)t[j]) || t[j] == '_')) ++j;
            if (j > i + 1 && j < n && (t[j] == ']' || t[j] == '[')) {
                std::string name = t.substr(i + 1, j - i - 1);
                json v = vars(name);
                if (!v.is_null()) {
                    if (t[j] == ']') {
                        Val val = v.is_array() ? (v.empty() ? Val::S("") : fromJson(v[std::max(0, std::min(di, (int)v.size() - 1))])) : fromJson(v);
                        out += val.text();
                        i = j + 1;
                        continue;
                    }
                    size_t close = t.find("]]", j);
                    if (close != std::string::npos) {
                        std::string idxExpr = t.substr(j + 1, close - j - 1);
                        try {
                            int idx = (int)evalExpr(idxExpr, vars, di).asNum();
                            Val val = v.is_array() ? (v.empty() ? Val::S("") : fromJson(v[std::max(0, std::min(idx, (int)v.size() - 1))])) : fromJson(v);
                            out += val.text();
                        } catch (const std::exception& ex) {
                            if (error && error->empty()) *error = ex.what();
                            out += "0";
                        }
                        i = close + 2;
                        continue;
                    }
                }
            }
        }
        if (active()) out.push_back(c);
        ++i;
    }
    return out;
}

}  // namespace a1
