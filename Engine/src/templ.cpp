#include "templ.hpp"

#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <regex>
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

// ---------------------------------------------------------------- values
struct Val {
    enum K { Nil, Num, Str, Bool, Vec } k = Nil;
    double n = 0;
    std::string s;
    bool b = false;
    std::vector<Val> v;

    static Val num(double d) { Val x; x.k = Num; x.n = d; return x; }
    static Val str(std::string t) { Val x; x.k = Str; x.s = std::move(t); return x; }
    static Val boolean(bool t) { Val x; x.k = Bool; x.b = t; return x; }

    bool numeric(double& out) const {
        if (k == Num) { out = n; return true; }
        if (k == Bool) { out = b ? 1 : 0; return true; }
        if (k == Str) {
            const char* p = s.c_str();
            while (*p == ' ') ++p;
            char* end = nullptr;
            double d = std::strtod(p, &end);
            if (end == p) return false;
            while (*end == ' ') ++end;
            if (*end == '%') ++end;
            if (*end) return false;
            out = d;
            return true;
        }
        return false;
    }
    double asNum() const { double d = 0; numeric(d); return d; }
    bool truthy() const {
        switch (k) {
            case Nil: return false;
            case Num: return n != 0;
            case Bool: return b;
            case Vec: return !v.empty();
            case Str: {
                double d;
                if (numeric(d)) return d != 0;
                return !s.empty() && s != "false";
            }
        }
        return false;
    }
    std::string text() const {
        switch (k) {
            case Nil: return "";
            case Num: return fmtNum(n);
            case Bool: return b ? "true" : "false";
            case Str: return s;
            case Vec: {
                std::string o;
                for (size_t i = 0; i < v.size(); ++i) o += (i ? "," : "") + v[i].text();
                return o;
            }
        }
        return "";
    }
};

bool looksNumeric(const std::string& s) {
    if (s.empty()) return false;
    const char* p = s.c_str();
    char* end = nullptr;
    std::strtod(p, &end);
    return end != p && *end == 0 && !std::isspace((unsigned char)s[0]);
}

Val fromJson(const json& j) {
    if (j.is_string()) {
        const std::string& s = j.get_ref<const std::string&>();
        if (looksNumeric(s)) return Val::num(std::strtod(s.c_str(), nullptr));
        return Val::str(s);
    }
    if (j.is_boolean()) return Val::boolean(j.get<bool>());
    if (j.is_number()) return Val::num(j.get<double>());
    if (j.is_array()) {
        Val x;
        x.k = Val::Vec;
        for (auto& e : j) x.v.push_back(fromJson(e));
        return x;
    }
    return Val();
}

json toJson(const Val& v) {
    switch (v.k) {
        case Val::Nil: return json();
        case Val::Num: return v.n;
        case Val::Bool: return v.b;
        case Val::Str: return v.s;
        case Val::Vec: {
            json a = json::array();
            for (auto& e : v.v) a.push_back(toJson(e));
            return a;
        }
    }
    return json();
}

// ---------------------------------------------------------------- tokens
enum class T { End, Ident, Number, String, Regex, Op };
struct Tok {
    T t = T::End;
    std::string s;
    double n = 0;
};

std::vector<Tok> tokenize(const std::string& src) {
    std::vector<Tok> out;
    size_t i = 0, n = src.size();
    while (i < n) {
        char c = src[i];
        if (std::isspace((unsigned char)c)) { ++i; continue; }
        if (std::isalpha((unsigned char)c) || c == '_') {
            size_t b = i;
            while (i < n && (std::isalnum((unsigned char)src[i]) || src[i] == '_')) ++i;
            out.push_back({T::Ident, src.substr(b, i - b), 0});
            continue;
        }
        if (std::isdigit((unsigned char)c) || (c == '.' && i + 1 < n && std::isdigit((unsigned char)src[i + 1]))) {
            char* end = nullptr;
            double d = std::strtod(src.c_str() + i, &end);
            size_t len = (size_t)(end - (src.c_str() + i));
            out.push_back({T::Number, src.substr(i, len), d});
            i += len;
            continue;
        }
        if (c == '"') {
            std::string s;
            ++i;
            bool closed = false;
            while (i < n) {
                char d = src[i++];
                if (d == '"') { closed = true; break; }
                if (d == '\\' && i < n) {
                    char e = src[i++];
                    if (e == 'n') s.push_back('\n');
                    else if (e == 't') s.push_back('\t');
                    else if (e == 'r') s.push_back('\r');
                    else s.push_back(e);
                    continue;
                }
                s.push_back(d);
            }
            if (!closed) throw std::runtime_error("unterminated string");
            out.push_back({T::String, s, 0});
            continue;
        }
        if (c == '/' && !out.empty() && out.back().t == T::Op && (out.back().s == "=~" || out.back().s == "!~")) {
            size_t e = src.find('/', i + 1);
            if (e == std::string::npos) throw std::runtime_error("unterminated regex");
            out.push_back({T::Regex, src.substr(i + 1, e - i - 1), 0});
            i = e + 1;
            continue;
        }
        static const char* two[] = {"==", "!=", "<>", "<=", ">=", "&&", "||", "=~", "!~"};
        bool matched = false;
        for (const char* t : two)
            if (src.compare(i, 2, t) == 0) { out.push_back({T::Op, t, 0}); i += 2; matched = true; break; }
        if (matched) continue;
        if (std::string("+-*/%()[],;?:=<>!").find(c) != std::string::npos) {
            out.push_back({T::Op, std::string(1, c), 0});
            ++i;
            continue;
        }
        throw std::runtime_error(std::string("unexpected character '") + c + "'");
    }
    out.push_back({T::End, "", 0});
    return out;
}

// ---------------------------------------------------------------- AST
struct Expr {
    enum K { Lit, Var, Index, Unary, Binary, Ternary, Call } k = Lit;
    Val lit;
    std::string name;  // var / op / function
    std::vector<std::unique_ptr<Expr>> a;
};
using EP = std::unique_ptr<Expr>;

struct Stmt {
    enum K { Local, Global, Assign, If, ExprS } k = ExprS;
    std::string name;
    EP index, value;
    std::vector<std::pair<EP, std::vector<Stmt>>> branches;
    std::vector<Stmt> elseBody;
    bool hasElse = false;
};

class Parser {
public:
    explicit Parser(std::vector<Tok> t) : t_(std::move(t)) {}
    std::vector<Stmt> program() {
        auto s = stmts({});
        if (peek().t != T::End) throw std::runtime_error("unexpected '" + peek().s + "'");
        return s;
    }
    EP exprOnly() {
        EP e = expr();
        if (peek().t != T::End) throw std::runtime_error("unexpected '" + peek().s + "'");
        return e;
    }
    bool hasThen() const {
        for (auto& k : t_) if (k.t == T::Ident && k.s == "then") return true;
        return false;
    }

private:
    std::vector<Tok> t_;
    size_t p_ = 0;
    const Tok& peek(size_t o = 0) const { return t_[std::min(p_ + o, t_.size() - 1)]; }
    Tok next() { return t_[std::min(p_++, t_.size() - 1)]; }
    bool isOp(const char* s, size_t o = 0) const { return peek(o).t == T::Op && peek(o).s == s; }
    bool isKw(const char* s, size_t o = 0) const { return peek(o).t == T::Ident && peek(o).s == s; }
    void expectOp(const char* s) {
        if (!isOp(s)) throw std::runtime_error(std::string("expected '") + s + "' near '" + peek().s + "'");
        ++p_;
    }
    void expectKw(const char* s) {
        if (!isKw(s)) throw std::runtime_error(std::string("expected '") + s + "' near '" + peek().s + "'");
        ++p_;
    }

    std::vector<Stmt> stmts(std::initializer_list<const char*> stop) {
        std::vector<Stmt> out;
        for (;;) {
            while (isOp(";")) ++p_;
            if (peek().t == T::End) return out;
            for (const char* s : stop) if (isKw(s)) return out;
            out.push_back(stmt());
        }
    }

    // index of the token after a bracketed group starting at offset o ('[')
    size_t afterBracket(size_t o) const {
        int depth = 0;
        for (size_t i = p_ + o; i < t_.size(); ++i) {
            if (t_[i].t == T::Op && t_[i].s == "[") ++depth;
            if (t_[i].t == T::Op && t_[i].s == "]") { if (--depth == 0) return i + 1; }
        }
        return t_.size() - 1;
    }

    Stmt stmt() {
        Stmt s;
        if (isKw("local") || isKw("global")) {
            s.k = isKw("local") ? Stmt::Local : Stmt::Global;
            ++p_;
            if (peek().t != T::Ident) throw std::runtime_error("expected a variable name");
            s.name = next().s;
            expectOp("=");
            s.value = expr();
            return s;
        }
        if (isKw("if")) {
            ++p_;
            s.k = Stmt::If;
            EP c = expr();
            expectKw("then");
            auto body = stmts({"elsif", "else", "endif"});
            s.branches.emplace_back(std::move(c), std::move(body));
            while (isKw("elsif")) {
                ++p_;
                EP c2 = expr();
                expectKw("then");
                auto b2 = stmts({"elsif", "else", "endif"});
                s.branches.emplace_back(std::move(c2), std::move(b2));
            }
            if (isKw("else")) {
                ++p_;
                s.hasElse = true;
                s.elseBody = stmts({"endif"});
            }
            expectKw("endif");
            return s;
        }
        if (peek().t == T::Ident) {
            if (isOp("=", 1)) {
                s.k = Stmt::Assign;
                s.name = next().s;
                ++p_;
                s.value = expr();
                return s;
            }
            if (isOp("[", 1)) {
                size_t after = afterBracket(1);
                if (after < t_.size() && t_[after].t == T::Op && t_[after].s == "=") {
                    s.k = Stmt::Assign;
                    s.name = next().s;
                    ++p_;  // [
                    s.index = expr();
                    expectOp("]");
                    expectOp("=");
                    s.value = expr();
                    return s;
                }
            }
        }
        s.k = Stmt::ExprS;
        s.value = expr();
        return s;
    }

public:
    EP expr() { return ternary(); }

private:
    EP mk(Expr::K k, std::string name = "") { EP e(new Expr()); e->k = k; e->name = std::move(name); return e; }
    EP bin(const std::string& op, EP l, EP r) {
        EP e = mk(Expr::Binary, op);
        e->a.push_back(std::move(l));
        e->a.push_back(std::move(r));
        return e;
    }
    EP ternary() {
        EP c = orE();
        if (isOp("?")) {
            ++p_;
            EP a = ternary();
            expectOp(":");
            EP b = ternary();
            EP e = mk(Expr::Ternary);
            e->a.push_back(std::move(c));
            e->a.push_back(std::move(a));
            e->a.push_back(std::move(b));
            return e;
        }
        return c;
    }
    EP orE() {
        EP l = andE();
        while (isOp("||") || isKw("or")) { ++p_; l = bin("||", std::move(l), andE()); }
        return l;
    }
    EP andE() {
        EP l = cmpE();
        while (isOp("&&") || isKw("and")) { ++p_; l = bin("&&", std::move(l), cmpE()); }
        return l;
    }
    EP cmpE() {
        EP l = addE();
        for (;;) {
            const Tok& k = peek();
            if (k.t == T::Op && (k.s == "==" || k.s == "!=" || k.s == "<>" || k.s == "<" || k.s == ">" || k.s == "<=" || k.s == ">=")) {
                std::string op = next().s;
                l = bin(op == "<>" ? "!=" : op, std::move(l), addE());
            } else if (k.t == T::Op && (k.s == "=~" || k.s == "!~")) {
                std::string op = next().s;
                if (peek().t != T::Regex) throw std::runtime_error("expected /regex/");
                EP r = mk(Expr::Lit);
                r->lit = Val::str(next().s);
                l = bin(op, std::move(l), std::move(r));
            } else {
                return l;
            }
        }
    }
    EP addE() {
        EP l = mulE();
        while (isOp("+") || isOp("-")) {
            std::string op = next().s;
            l = bin(op, std::move(l), mulE());
        }
        return l;
    }
    EP mulE() {
        EP l = unary();
        while (isOp("*") || isOp("/") || isOp("%")) {
            std::string op = next().s;
            l = bin(op, std::move(l), unary());
        }
        return l;
    }
    EP unary() {
        if (isOp("!") || isKw("not")) {
            ++p_;
            EP e = mk(Expr::Unary, "!");
            e->a.push_back(unary());
            return e;
        }
        if (isOp("-")) {
            ++p_;
            EP e = mk(Expr::Unary, "-");
            e->a.push_back(unary());
            return e;
        }
        if (isOp("+")) { ++p_; return unary(); }
        return postfix();
    }
    EP postfix() {
        EP e = primary();
        while (isOp("[")) {
            ++p_;
            EP idx = expr();
            expectOp("]");
            EP ix = mk(Expr::Index);
            ix->a.push_back(std::move(e));
            ix->a.push_back(std::move(idx));
            e = std::move(ix);
        }
        return e;
    }
    EP primary() {
        Tok k = next();
        if (k.t == T::Number) { EP e = mk(Expr::Lit); e->lit = Val::num(k.n); return e; }
        if (k.t == T::String) { EP e = mk(Expr::Lit); e->lit = Val::str(k.s); return e; }
        if (k.t == T::Op && k.s == "(") {
            EP e = expr();
            expectOp(")");
            return e;
        }
        if (k.t == T::Ident) {
            if (k.s == "true") { EP e = mk(Expr::Lit); e->lit = Val::boolean(true); return e; }
            if (k.s == "false") { EP e = mk(Expr::Lit); e->lit = Val::boolean(false); return e; }
            if (isOp("(")) {
                ++p_;
                EP c = mk(Expr::Call, k.s);
                if (!isOp(")")) {
                    c->a.push_back(expr());
                    while (isOp(",")) { ++p_; c->a.push_back(expr()); }
                }
                expectOp(")");
                return c;
            }
            return mk(Expr::Var, k.s);
        }
        throw std::runtime_error("unexpected '" + k.s + "'");
    }
};

// ---------------------------------------------------------------- evaluation
class Interp {
public:
    Interp(const VarLookup& v, int di, std::map<std::string, json>* g) : vars_(v), di_(di), globals_(g) {}

    // raw: vectors are returned whole (no implicit current-extruder indexing)
    Val lookup(const std::string& name, bool raw) {
        Val v;
        auto it = locals_.find(name);
        if (it != locals_.end()) v = it->second;
        else if (globals_ && globals_->count(name)) v = fromJson((*globals_)[name]);
        else {
            json j = vars_(name);
            if (j.is_null()) throw std::runtime_error("unknown variable " + name);
            v = fromJson(j);
        }
        if (!raw && v.k == Val::Vec) {
            if (v.v.empty()) return Val::str("");
            return v.v[std::max(0, std::min(di_, (int)v.v.size() - 1))];
        }
        return v;
    }

    Val eval(const Expr& e, bool raw = false) {
        switch (e.k) {
            case Expr::Lit: return e.lit;
            case Expr::Var: return lookup(e.name, raw);
            case Expr::Index: {
                Val base = (e.a[0]->k == Expr::Var) ? lookup(e.a[0]->name, true) : eval(*e.a[0], true);
                int i = (int)std::floor(eval(*e.a[1]).asNum() + 1e-9);
                if (base.k != Val::Vec) return base;
                if (base.v.empty()) return Val::str("");
                if (i < 0 || i >= (int)base.v.size()) i = std::max(0, std::min(i, (int)base.v.size() - 1));
                return base.v[i];
            }
            case Expr::Unary: {
                Val x = eval(*e.a[0]);
                if (e.name == "!") return Val::boolean(!x.truthy());
                return Val::num(-x.asNum());
            }
            case Expr::Ternary: return eval(*e.a[0]).truthy() ? eval(*e.a[1], raw) : eval(*e.a[2], raw);
            case Expr::Binary: return binary(e);
            case Expr::Call: return call(e);
        }
        return Val();
    }

    void exec(const std::vector<Stmt>& ss, std::string& out) {
        for (auto& s : ss) exec(s, out);
    }

private:
    const VarLookup& vars_;
    int di_;
    std::map<std::string, json>* globals_;
    std::map<std::string, Val> locals_;

    Val binary(const Expr& e) {
        const std::string& op = e.name;
        if (op == "&&") return Val::boolean(eval(*e.a[0]).truthy() && eval(*e.a[1]).truthy());
        if (op == "||") return Val::boolean(eval(*e.a[0]).truthy() || eval(*e.a[1]).truthy());
        Val l = eval(*e.a[0]), r = eval(*e.a[1]);
        if (op == "=~" || op == "!~") {
            bool m = false;
            try { m = std::regex_search(l.text(), std::regex(r.s)); } catch (...) { m = false; }
            return Val::boolean(op == "=~" ? m : !m);
        }
        if (op == "+") {
            if (l.k == Val::Str || r.k == Val::Str) return Val::str(l.text() + r.text());
            return Val::num(l.asNum() + r.asNum());
        }
        if (op == "-") return Val::num(l.asNum() - r.asNum());
        if (op == "*") return Val::num(l.asNum() * r.asNum());
        if (op == "/") { double d = r.asNum(); return Val::num(d == 0 ? 0 : l.asNum() / d); }
        if (op == "%") { double d = r.asNum(); return Val::num(d == 0 ? 0 : std::fmod(l.asNum(), d)); }
        double a, b;
        bool num = l.numeric(a) && r.numeric(b) && !(l.k == Val::Str && r.k == Val::Str && !looksNumeric(l.s) && !looksNumeric(r.s));
        if (num) {
            if (op == "==") return Val::boolean(std::fabs(a - b) < 1e-9);
            if (op == "!=") return Val::boolean(std::fabs(a - b) >= 1e-9);
            if (op == "<") return Val::boolean(a < b);
            if (op == ">") return Val::boolean(a > b);
            if (op == "<=") return Val::boolean(a <= b);
            if (op == ">=") return Val::boolean(a >= b);
        }
        std::string x = l.text(), y = r.text();
        if (op == "==") return Val::boolean(x == y);
        if (op == "!=") return Val::boolean(x != y);
        if (op == "<") return Val::boolean(x < y);
        if (op == ">") return Val::boolean(x > y);
        if (op == "<=") return Val::boolean(x <= y);
        if (op == ">=") return Val::boolean(x >= y);
        throw std::runtime_error("unknown operator " + op);
    }

    Val call(const Expr& e) {
        const std::string& f = e.name;
        auto arg = [&](size_t i) { return eval(*e.a.at(i)); };
        if (f == "size" || f == "empty") {
            Val v = e.a.at(0)->k == Expr::Var ? lookup(e.a[0]->name, true) : eval(*e.a[0], true);
            size_t n = v.k == Val::Vec ? v.v.size() : (v.k == Val::Nil ? 0 : 1);
            return f == "size" ? Val::num((double)n) : Val::boolean(n == 0);
        }
        if (f == "is_nil") {
            try {
                Val v = e.a.at(0)->k == Expr::Var ? lookup(e.a[0]->name, false) : eval(*e.a[0]);
                return Val::boolean(v.k == Val::Nil || (v.k == Val::Str && v.s == "nil"));
            } catch (...) {
                return Val::boolean(true);
            }
        }
        if (f == "min" || f == "max") {
            double a = arg(0).asNum(), b = arg(1).asNum();
            return Val::num(f == "min" ? std::min(a, b) : std::max(a, b));
        }
        if (f == "int") return Val::num(std::trunc(arg(0).asNum()));
        if (f == "round") return Val::num(std::round(arg(0).asNum()));
        if (f == "abs") return Val::num(std::fabs(arg(0).asNum()));
        if (f == "ceil") return Val::num(std::ceil(arg(0).asNum()));
        if (f == "floor") return Val::num(std::floor(arg(0).asNum()));
        if (f == "digits" || f == "zdigits") {
            double x = arg(0).asNum();
            int w = e.a.size() > 1 ? (int)arg(1).asNum() : 0;
            int d = e.a.size() > 2 ? (int)arg(2).asNum() : 0;
            char b[64];
            std::snprintf(b, sizeof b, f == "zdigits" ? "%0*.*f" : "%*.*f", w, d, x);
            return Val::str(b);
        }
        if (f == "one_of") {
            Val x = arg(0);
            for (size_t i = 1; i < e.a.size(); ++i) {
                Val c = arg(i);
                if (x.text() == c.text()) return Val::boolean(true);
            }
            return Val::boolean(false);
        }
        if (f == "random") return arg(0);
        throw std::runtime_error("unknown function " + f + "()");
    }

    void assign(const Stmt& s, std::string&) {
        if (!s.index) {
            Val v = (s.value->k == Expr::Var) ? lookup(s.value->name, true) : eval(*s.value, true);
            if (s.k == Stmt::Global && globals_) (*globals_)[s.name] = toJson(v);
            else locals_[s.name] = v;
            return;
        }
        Val base;
        try { base = lookup(s.name, true); } catch (...) { base.k = Val::Vec; }
        if (base.k != Val::Vec) { Val t; t.k = Val::Vec; t.v.push_back(base); base = t; }
        int i = (int)eval(*s.index).asNum();
        if (i < 0) i = 0;
        if ((int)base.v.size() <= i) base.v.resize(i + 1, Val::num(0));
        base.v[i] = eval(*s.value);
        locals_[s.name] = base;
    }

    void exec(const Stmt& s, std::string& out) {
        switch (s.k) {
            case Stmt::Local:
            case Stmt::Global:
            case Stmt::Assign: assign(s, out); return;
            case Stmt::If:
                for (auto& br : s.branches)
                    if (eval(*br.first).truthy()) { exec(br.second, out); return; }
                if (s.hasElse) exec(s.elseBody, out);
                return;
            case Stmt::ExprS: out += eval(*s.value).text(); return;
        }
    }
};

// Finds the '}' closing a block that starts at `open` ('{'), skipping string literals.
size_t blockEnd(const std::string& t, size_t open) {
    bool inStr = false;
    for (size_t i = open + 1; i < t.size(); ++i) {
        char c = t[i];
        if (inStr) {
            if (c == '\\') { ++i; continue; }
            if (c == '"') inStr = false;
            continue;
        }
        if (c == '"') { inStr = true; continue; }
        if (c == '}') return i;
    }
    return std::string::npos;
}

std::string trimmed(const std::string& s) {
    size_t b = s.find_first_not_of(" \t\r\n");
    if (b == std::string::npos) return "";
    size_t e = s.find_last_not_of(" \t\r\n");
    return s.substr(b, e - b + 1);
}

bool startsWord(const std::string& s, const char* w) {
    size_t n = std::char_traits<char>::length(w);
    return s.compare(0, n, w) == 0 && (s.size() == n || !(std::isalnum((unsigned char)s[n]) || s[n] == '_'));
}

}  // namespace

std::string renderTemplate(const std::string& t, const VarLookup& vars, int di, std::string* error, std::map<std::string, json>* globals) {
    std::string out;
    out.reserve(t.size() + 256);
    Interp in(vars, di, globals);
    struct Frame { bool parent, active, taken; };
    std::vector<Frame> st;
    auto active = [&]() { return st.empty() || st.back().active; };
    auto fail = [&](const std::string& what, const std::string& body) {
        if (error && error->empty()) *error = what + " in {" + body.substr(0, 80) + "}";
    };
    size_t i = 0, n = t.size();
    while (i < n) {
        char c = t[i];
        if (c == '{') {
            size_t e = blockEnd(t, i);
            if (e == std::string::npos) { if (active()) out += t.substr(i); break; }
            std::string body = t.substr(i + 1, e - i - 1);
            std::string tb = trimmed(body);
            i = e + 1;
            try {
                bool macroIf = startsWord(tb, "if") || startsWord(tb, "elsif");
                bool hasThen = false;
                if (macroIf) {
                    Parser probe(tokenize(tb));
                    hasThen = probe.hasThen();
                }
                if (macroIf && !hasThen && startsWord(tb, "if")) {
                    bool par = active();
                    bool cond = false;
                    if (par) {
                        Parser p(tokenize(tb.substr(2)));
                        cond = in.eval(*p.exprOnly()).truthy();
                    }
                    st.push_back({par, cond, cond});
                    continue;
                }
                if (macroIf && !hasThen) {  // elsif
                    if (st.empty()) throw std::runtime_error("elsif without if");
                    Frame& f = st.back();
                    bool cond = false;
                    if (f.parent && !f.taken) {
                        Parser p(tokenize(tb.substr(5)));
                        cond = in.eval(*p.exprOnly()).truthy();
                    }
                    f.active = cond;
                    f.taken = f.taken || cond;
                    continue;
                }
                if (tb == "else") {
                    if (st.empty()) throw std::runtime_error("else without if");
                    Frame& f = st.back();
                    f.active = f.parent && !f.taken;
                    f.taken = true;
                    continue;
                }
                if (tb == "endif") {
                    if (st.empty()) throw std::runtime_error("endif without if");
                    st.pop_back();
                    continue;
                }
                if (!active()) continue;
                Parser p(tokenize(body));
                auto prog = p.program();
                in.exec(prog, out);
            } catch (const std::exception& ex) {
                fail(ex.what(), body);
            }
            continue;
        }
        if (c == '[' && active()) {
            size_t j = i + 1;
            while (j < n && (std::isalnum((unsigned char)t[j]) || t[j] == '_')) ++j;
            if (j > i + 1 && j < n && (t[j] == ']' || t[j] == '[')) {
                std::string name = t.substr(i + 1, j - i - 1);
                bool known = true;
                Val base;
                try { base = in.lookup(name, true); } catch (...) { known = false; }
                if (known) {
                    if (t[j] == ']') {
                        Val v = base;
                        if (v.k == Val::Vec) v = v.v.empty() ? Val::str("") : v.v[std::max(0, std::min(di, (int)v.v.size() - 1))];
                        out += v.text();
                        i = j + 1;
                        continue;
                    }
                    size_t close = t.find("]]", j);
                    if (close != std::string::npos) {
                        std::string idxExpr = t.substr(j + 1, close - j - 1);
                        try {
                            Parser p(tokenize(idxExpr));
                            int idx = (int)in.eval(*p.exprOnly()).asNum();
                            Val v = base;
                            if (v.k == Val::Vec) v = v.v.empty() ? Val::str("") : v.v[std::max(0, std::min(idx, (int)v.v.size() - 1))];
                            out += v.text();
                        } catch (const std::exception& ex) {
                            fail(ex.what(), idxExpr);
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
