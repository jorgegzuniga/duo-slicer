#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <map>
#include <memory>
#include <sstream>
#include <tuple>
#include <array>
#include <cstdio>
#include <cctype>

#include "../include/a1engine.h"
#include "config.hpp"
#include "gcode.hpp"
#include "project.hpp"
#include "slicer.hpp"
#include "zipio.hpp"

using namespace a1;
using json = nlohmann::json;

// Placement state for undo: plates (with their object lists) and every object's transforms and plate.
struct Placement {
    std::vector<Plate> plates;
    std::vector<std::tuple<Mat, Mat, int>> objects;  // item, item0, plate
    bool platesEdited = false;
};

struct A1Engine {
    json printer;       // target printer bundle (Resources/profiles/<id>.json)
    std::string bytes;  // original archive
    std::unique_ptr<Project> proj;
    PlateSlice lastSlice;
    std::string lastFile;
    std::string lastKind;  // "gcode.3mf" (Bambu) or "gcode"
    int lastPlate = -1;
    std::vector<Placement> undo;  // most recent last
};

namespace {

char* dupJson(const json& j) {
    std::string s = j.dump();
    char* p = (char*)std::malloc(s.size() + 1);
    std::memcpy(p, s.c_str(), s.size() + 1);
    return p;
}
char* err(const std::string& m) { return dupJson(json{{"error", m}}); }
template <class T>
T* dupBuf(const std::vector<T>& v) {
    T* p = (T*)std::malloc(std::max<size_t>(1, v.size() * sizeof(T)));
    if (!v.empty()) std::memcpy(p, v.data(), v.size() * sizeof(T));
    return p;
}
uint8_t* dupStr(const std::string& s) {
    uint8_t* p = (uint8_t*)std::malloc(std::max<size_t>(1, s.size()));
    if (!s.empty()) std::memcpy(p, s.data(), s.size());
    return p;
}

json parseOpts(const char* s) {
    if (!s || !*s) return json::object();
    try { return json::parse(s); } catch (...) { return json::object(); }
}

// 3x3 helpers on Mat (row-vector convention: p' = p*M)
void mul(const Mat& a, const Mat& b, Mat& out) {  // apply a then b
    Mat r;
    for (int i = 0; i < 3; ++i)
        for (int j = 0; j < 3; ++j) r.m[i * 3 + j] = a.m[i * 3] * b.m[j] + a.m[i * 3 + 1] * b.m[3 + j] + a.m[i * 3 + 2] * b.m[6 + j];
    for (int j = 0; j < 3; ++j) r.m[9 + j] = a.m[9] * b.m[j] + a.m[10] * b.m[3 + j] + a.m[11] * b.m[6 + j] + b.m[9 + j];
    out = r;
}
Mat translate(double x, double y, double z) { Mat t; t.m[9] = x; t.m[10] = y; t.m[11] = z; return t; }
// rotation as row-vector matrix from a column-vector rotation R (p' = R p)  -> M = R^T
Mat fromR(const double R[9]) {
    Mat m;
    for (int i = 0; i < 3; ++i) for (int j = 0; j < 3; ++j) m.m[i * 3 + j] = R[j * 3 + i];
    m.m[9] = m.m[10] = m.m[11] = 0;
    return m;
}
void axisAngle(double ax, double ay, double az, double ang, double R[9]) {
    double c = std::cos(ang), s = std::sin(ang), t = 1 - c;
    double n = std::sqrt(ax * ax + ay * ay + az * az);
    if (n < 1e-12) { for (int i = 0; i < 9; ++i) R[i] = (i % 4 == 0); return; }
    ax /= n; ay /= n; az /= n;
    double r[9] = {t * ax * ax + c, t * ax * ay - s * az, t * ax * az + s * ay,
                   t * ax * ay + s * az, t * ay * ay + c, t * ay * az - s * ax,
                   t * ax * az - s * ay, t * ay * az + s * ax, t * az * az + c};
    std::memcpy(R, r, sizeof r);
}

void applyRotation(Project& P, Object& o, const double R[9]) {
    double mn[3], mx[3];
    P.objectBounds(o, o.item, mn, mx);
    double cx = (mn[0] + mx[0]) / 2, cy = (mn[1] + mx[1]) / 2, cz = (mn[2] + mx[2]) / 2;
    Mat a, b;
    mul(o.item, translate(-cx, -cy, -cz), a);
    mul(a, fromR(R), b);
    mul(b, translate(cx, cy, cz), a);
    P.objectBounds(o, a, mn, mx);
    mul(a, translate(0, 0, -mn[2]), b);
    o.item = b;
}

void rotateNormalDown(Project& P, Object& o, double nx, double ny, double nz) {
    double n = std::sqrt(nx * nx + ny * ny + nz * nz);
    if (n < 1e-12) return;
    nx /= n; ny /= n; nz /= n;
    // rotate n onto (0,0,-1)
    double tx = 0, ty = 0, tz = -1;
    double ax = ny * tz - nz * ty, ay = nz * tx - nx * tz, az = nx * ty - ny * tx;
    double dot = nx * tx + ny * ty + nz * tz;
    double ang = std::acos(std::max(-1.0, std::min(1.0, dot)));
    double R[9];
    if (std::sqrt(ax * ax + ay * ay + az * az) < 1e-9) {
        if (dot > 0) return;           // already down
        axisAngle(1, 0, 0, M_PI, R);   // pointing up: flip
    } else {
        axisAngle(ax, ay, az, ang, R);
    }
    applyRotation(P, o, R);
}

struct Bed {
    double x0 = 0, y0 = 0, x1 = 256, y1 = 256, h = 256;
    double ex0 = 0, ey0 = 0, ex1 = 0, ey1 = 0;  // no-print box (X1/P1 filament cutter corner)
    bool hasEx() const { return ex1 > ex0 && ey1 > ey0; }
};

Bed bedOf(const json& printer) {
    Bed b;
    if (!printer.is_object() || !printer.contains("bed")) return b;
    try {
        const json& j = printer["bed"];
        b.x0 = j["min"][0]; b.y0 = j["min"][1];
        b.x1 = j["max"][0]; b.y1 = j["max"][1];
        b.h = j.value("height", 256.0);
        if (j.contains("exclude") && j["exclude"].is_array() && j["exclude"].size() == 2) {
            b.ex0 = j["exclude"][0][0]; b.ey0 = j["exclude"][0][1];
            b.ex1 = j["exclude"][1][0]; b.ey1 = j["exclude"][1][1];
        }
    } catch (...) {}
    return b;
}

std::string printerName(const json& p) { return p.is_object() ? p.value("name", std::string("printer")) : std::string("printer"); }
bool isToolChanger(const json& p) { return p.is_object() && p.value("kind", std::string("bambu")) == "klipper_toolchanger"; }

std::string fmt1(double v) {
    char b[32];
    std::snprintf(b, sizeof b, "%.0f", v);
    return b;
}

// The project's bed centre lands on the target printer's bed centre (a plain 3MF without a printer: its parts are centred).
void placePlates(A1Engine* e) {
    if (!e->proj) return;
    Project& P = *e->proj;
    Bed b = bedOf(e->printer);
    double tcx = (b.x0 + b.x1) / 2, tcy = (b.y0 + b.y1) / 2;
    for (auto& pl : P.plates) {
        double pcx = P.bedX0 + P.bedW / 2, pcy = P.bedY0 + P.bedD / 2;
        if (!P.hasBed) {
            double x0 = 1e18, y0 = 1e18, x1 = -1e18, y1 = -1e18;
            for (int oi : pl.objects) {
                double mn[3], mx[3];
                P.objectBounds(P.objects[oi], P.objects[oi].item0, mn, mx);
                x0 = std::min(x0, mn[0] - pl.ox0); y0 = std::min(y0, mn[1] - pl.oy0);
                x1 = std::max(x1, mx[0] - pl.ox0); y1 = std::max(y1, mx[1] - pl.oy0);
            }
            if (x1 > x0 && y1 > y0) { pcx = (x0 + x1) / 2; pcy = (y0 + y1) / 2; }
        }
        pl.ox = pl.ox0 + pcx - tcx;
        pl.oy = pl.oy0 + pcy - tcy;
    }
}

// Why an object can't print on the target bed ("" = it fits). mn/mx return its box in bed coordinates.
std::string fitIssue(const Project& P, const Plate& pl, const Object& o, const Bed& b, double mn[3], double mx[3]) {
    P.objectBounds(o, o.item, mn, mx);
    mn[0] -= pl.ox; mx[0] -= pl.ox;
    mn[1] -= pl.oy; mx[1] -= pl.oy;
    if (mn[0] < b.x0 - 0.05 || mn[1] < b.y0 - 0.05 || mx[0] > b.x1 + 0.05 || mx[1] > b.y1 + 0.05) return "off_bed";
    if (mx[2] > b.h + 0.05) return "too_tall";
    if (b.hasEx() && !(mx[0] <= b.ex0 || mn[0] >= b.ex1 || mx[1] <= b.ey0 || mn[1] >= b.ey1)) {
        for (auto& v : o.volumes)
            for (size_t k = 0; k + 2 < v.verts.size(); k += 3) {
                double x, y, z;
                o.item.apply(v.verts[k], v.verts[k + 1], v.verts[k + 2], x, y, z);
                x -= pl.ox;
                y -= pl.oy;
                if (x > b.ex0 && x < b.ex1 && y > b.ey0 && y < b.ey1) return "excluded_zone";
            }
    }
    return "";
}

std::string fitMessage(const std::string& issue, const std::string& obj, const json& printer, const Bed& b) {
    std::string pn = printerName(printer);
    if (issue == "off_bed") return obj + " doesn't fit on the " + pn + "'s bed. Move or rotate it, or use Center on bed, then slice again.";
    if (issue == "too_tall") return obj + " is taller than the " + pn + " can print (" + fmt1(b.h) + " mm).";
    if (issue == "excluded_zone") return obj + " sits in the front-left corner the " + pn + " keeps clear for cutting filament. Move it, then slice again.";
    return obj + " can't be printed on the " + pn + ".";
}

// ---- placement edits

void pushUndo(A1Engine* e) {
    if (!e->proj) return;
    Placement s;
    s.plates = e->proj->plates;
    for (auto& o : e->proj->objects) s.objects.emplace_back(o.item, o.item0, o.plate);
    s.platesEdited = e->proj->platesEdited;
    e->undo.push_back(std::move(s));
    if (e->undo.size() > 40) e->undo.erase(e->undo.begin());
}

struct Box {
    double x0, y0, x1, y1;
    double w() const { return x1 - x0; }
    double d() const { return y1 - y0; }
};

// An object's footprint on its plate's bed (printer coordinates).
Box footprint(const Project& P, const Object& o) {
    const Plate& pl = P.plates[o.plate];
    double mn[3], mx[3];
    P.objectBounds(o, o.item, mn, mx);
    return {mn[0] - pl.ox, mn[1] - pl.oy, mx[0] - pl.ox, mx[1] - pl.oy};
}

// Closer than `gap` (touching counts as overlapping when gap is 0).
bool tooClose(const Box& a, const Box& b, double gap) {
    const double eps = 1e-6;
    return !(a.x1 + gap <= b.x0 + eps || b.x1 + gap <= a.x0 + eps || a.y1 + gap <= b.y0 + eps || b.y1 + gap <= a.y0 + eps);
}

bool insideBed(const Box& c, const Bed& b, double margin) {
    const double eps = 1e-6;
    return c.x0 >= b.x0 + margin - eps && c.y0 >= b.y0 + margin - eps && c.x1 <= b.x1 - margin + eps && c.y1 <= b.y1 - margin + eps;
}

bool spotFree(const Box& c, const Bed& b, double margin, double gap, const std::vector<Box>& taken) {
    if (!insideBed(c, b, margin)) return false;
    for (auto& t : taken)
        if (tooClose(c, t, gap)) return false;
    return true;
}

// Front-left-most spot for a w x d footprint on the bed, clear of `taken` by `gap` (bottom-left packing).
bool findSpot(const Bed& b, double margin, double gap, double w, double d, const std::vector<Box>& taken, double& x, double& y) {
    std::vector<double> xs{b.x0 + margin}, ys{b.y0 + margin};
    for (auto& t : taken) {
        xs.push_back(t.x1 + gap);
        ys.push_back(t.y1 + gap);
        xs.push_back(t.x0 - gap - w);
        ys.push_back(t.y0 - gap - d);
    }
    std::sort(xs.begin(), xs.end());
    std::sort(ys.begin(), ys.end());
    xs.erase(std::unique(xs.begin(), xs.end(), [](double a, double c) { return std::fabs(a - c) < 1e-6; }), xs.end());
    ys.erase(std::unique(ys.begin(), ys.end(), [](double a, double c) { return std::fabs(a - c) < 1e-6; }), ys.end());
    for (double cy : ys)
        for (double cx : xs) {
            Box c{cx, cy, cx + w, cy + d};
            if (spotFree(c, b, margin, gap, taken)) { x = cx; y = cy; return true; }
        }
    return false;
}

void shiftObject(Object& o, double dx, double dy) {
    o.item.m[9] += dx;
    o.item.m[10] += dy;
}

// Shift item and the Reset baseline together (the object changes plate, not position on its plate).
void carryObject(Object& o, double dx, double dy) {
    shiftObject(o, dx, dy);
    o.item0.m[9] += dx;
    o.item0.m[10] += dy;
}

// What an object on a plate must stay clear of: the no-print corner and the plate's other objects.
std::vector<Box> obstacles(const Project& P, const Bed& b, int plate, int except) {
    std::vector<Box> v;
    if (b.hasEx()) v.push_back({b.ex0, b.ey0, b.ex1, b.ey1});
    for (int oi : P.plates[plate].objects)
        if (oi != except) v.push_back(footprint(P, P.objects[oi]));
    return v;
}

// A new, empty plate at the end (the grid is laid out again for the new count).
int addPlate(Project& P) {
    Plate pl;
    int maxId = 0;
    for (auto& p : P.plates) maxId = std::max(maxId, p.id);
    pl.id = maxId + 1;
    pl.name = "Plate " + std::to_string(pl.id);
    // same world -> printer bed mapping as the first plate, before layout moves it to its grid spot
    if (!P.plates.empty()) {
        pl.ox0 = P.plates[0].ox0;
        pl.oy0 = P.plates[0].oy0;
        pl.ox = P.plates[0].ox;
        pl.oy = P.plates[0].oy;
    }
    P.plates.push_back(pl);
    P.platesEdited = true;
    P.layoutPlates();
    return (int)P.plates.size() - 1;
}

const double kArrangeGap = 6, kBedMargin = 3;

// Project filaments (1-based) used by the objects on a plate.
std::vector<int> plateFilaments(const Project& P, int plate) {
    std::vector<int> f;
    for (int oi : P.plates[plate].objects)
        for (auto& v : P.objects[oi].volumes)
            if (std::find(f.begin(), f.end(), v.filament) == f.end()) f.push_back(v.filament);
    std::sort(f.begin(), f.end());
    return f;
}

// Each project filament as the config sees it, with the user's preset and colour choices.
std::vector<FilamentInput> projectInputs(const Project& P, const json& o) {
    std::vector<FilamentInput> v;
    for (size_t i = 0; i < P.colors.size(); ++i) {
        FilamentInput f{P.settingIds[i], P.types[i], P.colors[i], ""};
        if (o.contains("filaments") && o["filaments"].is_array() && i < o["filaments"].size() && o["filaments"][i].is_string()) f.preset = o["filaments"][i];
        if (o.contains("colors") && o["colors"].is_array() && i < o["colors"].size() && o["colors"][i].is_string()) f.color = o["colors"][i];
        v.push_back(f);
    }
    return v;
}

// Default toolhead for each used filament: options.tool_map where given, then the free toolheads in order.
// Returns false (with a message) when the plate needs more toolheads than the printer has.
bool toolMapFor(const json& printer, const Project& P, const std::vector<int>& used, const json& o, std::vector<int>& toolOf, std::string& error) {
    int tools = std::max(1, printer.value("tools", 1));
    toolOf.assign(P.colors.size(), -1);
    if (o.contains("tool_map") && o["tool_map"].is_array())
        for (size_t i = 0; i < toolOf.size() && i < o["tool_map"].size(); ++i)
            if (o["tool_map"][i].is_number_integer()) {
                int t = o["tool_map"][i];
                toolOf[i] = (t >= 0 && t < tools) ? t : -1;
            }
    std::vector<bool> taken(tools, false);
    for (int f : used) if (toolOf[f - 1] >= 0) taken[toolOf[f - 1]] = true;
    for (int f : used) {
        if (toolOf[f - 1] >= 0) continue;
        int t = 0;
        while (t < tools && taken[t]) ++t;
        if (t == tools) {
            error = "This plate uses " + std::to_string(used.size()) + " filaments, but the " + printerName(printer) + " has " + std::to_string(tools) +
                    " toolheads. Assign filaments that can share a toolhead (same material and colour), or print a plate with fewer colours.";
            return false;
        }
        toolOf[f - 1] = t;
        taken[t] = true;
    }
    return true;
}

// Inputs per G-code filament. Bambu: the project's filaments (AMS maps them to slots).
// Tool changer: one per toolhead, from the first filament assigned to it (unused heads: options.tool_filaments or generic PLA).
std::vector<FilamentInput> gcodeInputs(const json& printer, const Project& P, const std::vector<int>& used, const std::vector<int>& toolOf, const json& o) {
    auto pf = projectInputs(P, o);
    if (!isToolChanger(printer)) return pf;
    int tools = std::max(1, printer.value("tools", 1));
    std::vector<FilamentInput> ins(tools, FilamentInput{"", "PLA", "#FFFFFF", ""});
    if (o.contains("tool_filaments") && o["tool_filaments"].is_array())
        for (int t = 0; t < tools && t < (int)o["tool_filaments"].size(); ++t) {
            const json& tf = o["tool_filaments"][t];
            if (!tf.is_object()) continue;
            if (tf.contains("type") && tf["type"].is_string() && !tf["type"].get<std::string>().empty()) ins[t].type = tf["type"];
            if (tf.contains("color") && tf["color"].is_string() && !tf["color"].get<std::string>().empty()) ins[t].color = tf["color"];
            if (tf.contains("preset") && tf["preset"].is_string()) ins[t].preset = tf["preset"];
        }
    std::vector<bool> set(tools, false);
    for (int f : used) {
        int t = toolOf[f - 1];
        if (t >= 0 && t < tools && !set[t]) { ins[t] = pf[f - 1]; set[t] = true; }
    }
    return ins;
}

std::string unbase64(const std::string& in) {
    static int T[256];
    static bool init = false;
    if (!init) {
        for (int i = 0; i < 256; ++i) T[i] = -1;
        const char* a = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        for (int i = 0; i < 64; ++i) T[(unsigned char)a[i]] = i;
        init = true;
    }
    std::string out;
    int val = 0, bits = -8;
    for (unsigned char c : in) {
        if (T[c] < 0) continue;
        val = (val << 6) + T[c];
        bits += 6;
        if (bits >= 0) { out.push_back(char((val >> bits) & 0xFF)); bits -= 8; }
    }
    return out;
}

std::string labelName(const std::string& name, int oi) {
    std::string s;
    for (char c : name) s += (std::isalnum((unsigned char)c) || c == '_' || c == '-' || c == '.') ? c : '_';
    if (s.empty()) s = "object";
    return s + "_id_" + std::to_string(oi) + "_copy_0";
}

ObjectLabel labelFor(const Project& P, const Plate& pl, int oi) {
    const Object& o = P.objects[oi];
    std::vector<std::pair<double, double>> pts;
    for (auto& v : o.volumes) {
        size_t step = std::max<size_t>(1, v.verts.size() / 3 / 20000);  // plenty for a footprint hull
        for (size_t k = 0; k + 2 < v.verts.size(); k += 3 * step) {
            double x, y, z;
            o.item.apply(v.verts[k], v.verts[k + 1], v.verts[k + 2], x, y, z);
            pts.push_back({x - pl.ox, y - pl.oy});
        }
    }
    std::sort(pts.begin(), pts.end());
    pts.erase(std::unique(pts.begin(), pts.end()), pts.end());
    auto cross = [](const std::pair<double, double>& a, const std::pair<double, double>& b, const std::pair<double, double>& c) {
        return (b.first - a.first) * (c.second - a.second) - (b.second - a.second) * (c.first - a.first);
    };
    std::vector<std::pair<double, double>> h(2 * pts.size() + 1);
    size_t k = 0;
    for (size_t i = 0; i < pts.size(); ++i) { while (k >= 2 && cross(h[k - 2], h[k - 1], pts[i]) <= 0) k--; h[k++] = pts[i]; }
    for (size_t i = pts.size() - 1, t = k + 1; i > 0; --i) { while (k >= t && cross(h[k - 2], h[k - 1], pts[i - 1]) <= 0) k--; h[k++] = pts[i - 1]; }
    h.resize(k > 0 ? k - 1 : 0);
    ObjectLabel L;
    L.object = oi;
    L.name = labelName(o.name, oi);
    double x0 = 1e18, y0 = 1e18, x1 = -1e18, y1 = -1e18;
    for (auto& p : h) {
        L.polygon.push_back({p.first, p.second});
        x0 = std::min(x0, p.first); x1 = std::max(x1, p.first); y0 = std::min(y0, p.second); y1 = std::max(y1, p.second);
    }
    if (!h.empty()) { L.cx = (x0 + x1) / 2; L.cy = (y0 + y1) / 2; }
    return L;
}

json printerInfo(const json& pr) {
    json j{{"id", pr.value("id", std::string(""))},       {"name", printerName(pr)},
           {"vendor", pr.value("vendor", std::string(""))}, {"kind", pr.value("kind", std::string("bambu"))},
           {"tools", pr.value("tools", 1)},                 {"nozzle", pr.value("nozzle", 0.4)},
           {"model_id", pr.value("model_id", std::string(""))}};
    if (pr.contains("bed")) j["bed"] = pr["bed"];
    j["bed_types"] = supportedBedTypes(pr);
    return j;
}

json projectInfo(A1Engine* e) {
    Project& P = *e->proj;
    Bed bed = bedOf(e->printer);
    json j;
    j["printer_model"] = P.printerModel;  // printer the project was made for
    j["printer"] = printerInfo(e->printer);
    j["filaments"] = json::array();
    for (size_t i = 0; i < P.colors.size(); ++i) {
        j["filaments"].push_back({{"index", i + 1}, {"color", P.colors[i]}, {"type", P.types[i]}, {"setting_id", P.settingIds[i]},
                                  {"preset", mapFilamentPreset(e->printer, P.settingIds[i], P.types[i])}});
    }
    j["plates"] = json::array();
    for (size_t pi = 0; pi < P.plates.size(); ++pi) {
        const Plate& pl = P.plates[pi];
        json pj{{"index", pi}, {"id", pl.id}, {"name", pl.name}, {"has_thumbnail", !pl.thumb.empty()}, {"objects", json::array()}};
        bool off = false;
        double zmax = 0;
        json issues = json::array();
        for (int oi : pl.objects) {
            const Object& o = P.objects[oi];
            double mn[3], mx[3];
            std::string issue = fitIssue(P, pl, o, bed, mn, mx);
            off = off || !issue.empty();
            if (!issue.empty()) issues.push_back(fitMessage(issue, o.name, e->printer, bed));
            zmax = std::max(zmax, mx[2]);
            json oj{{"index", oi}, {"id", o.id}, {"name", o.name}, {"filaments", json::array()}, {"off_bed", !issue.empty()}, {"fit", issue},
                    {"edited", o.item.m != o.item0.m}, {"min", {mn[0], mn[1], mn[2]}}, {"max", {mx[0], mx[1], mx[2]}}, {"overrides", o.overrides}};
            for (auto& v : o.volumes) oj["filaments"].push_back(v.filament);
            pj["objects"].push_back(oj);
        }
        std::vector<int> fil = plateFilaments(P, (int)pi);
        pj["filaments"] = fil;
        pj["empty"] = pl.objects.empty();
        pj["off_bed"] = off;
        pj["fit_issues"] = issues;
        pj["height"] = zmax;
        if (isToolChanger(e->printer)) {
            std::vector<int> toolOf;
            std::string er;
            pj["tool_map"] = toolMapFor(e->printer, P, fil, json::object(), toolOf, er) ? json(toolOf) : json(nullptr);
            pj["needs_more_tools"] = !er.empty();
        }
        j["plates"].push_back(pj);
    }
    j["processes"] = json::array();
    for (auto& kv : e->printer["processes"].items()) j["processes"].push_back(kv.key());
    j["default_process"] = e->printer.value("default_process", std::string(""));
    // the preset matching the project's layer height
    if (P.cfg.contains("layer_height")) {
        double lh = std::atof(P.cfg["layer_height"].is_string() ? P.cfg["layer_height"].get<std::string>().c_str() : P.cfg["layer_height"].dump().c_str());
        for (auto& kv : e->printer["processes"].items()) {
            const json& p = kv.value();
            if (p.contains("layer_height") && p["layer_height"].is_string() && std::fabs(std::atof(p["layer_height"].get<std::string>().c_str()) - lh) < 1e-6 &&
                (kv.key().find("Standard") != std::string::npos || kv.key().find("Optimal") != std::string::npos || kv.key().find("Fine") != std::string::npos ||
                 kv.key().find("Draft") != std::string::npos)) {
                j["default_process"] = kv.key();
                break;
            }
        }
    }
    j["filament_presets"] = json::array();
    for (auto& kv : e->printer["filaments"].items()) j["filament_presets"].push_back(kv.key());
    std::vector<std::string> beds = supportedBedTypes(e->printer);
    std::string bt = P.cfg.value("curr_bed_type", std::string("Textured PEI Plate"));
    if (!beds.empty() && std::find(beds.begin(), beds.end(), bt) == beds.end()) bt = beds.front();
    j["bed_type"] = bt;
    j["can_undo"] = !e->undo.empty();
    return j;
}

std::string replaceItemTransforms(std::string model, const Project& P) {
    for (auto& o : P.objects) {
        if (o.item.m == o.itemFile.m) continue;
        std::string key = "objectid=\"" + o.id + "\"";
        size_t p = 0;
        while ((p = model.find("<item", p)) != std::string::npos) {
            size_t e = model.find('>', p);
            if (e == std::string::npos) break;
            std::string tag = model.substr(p, e - p + 1);
            if (tag.find(key) != std::string::npos) {
                size_t t = tag.find("transform=\"");
                std::string nt;
                if (t != std::string::npos) {
                    size_t te = tag.find('"', t + 11);
                    nt = tag.substr(0, t + 11) + o.item.str() + tag.substr(te);
                } else {
                    nt = tag;
                    nt.insert(5, " transform=\"" + o.item.str() + "\"");
                }
                model.replace(p, tag.size(), nt);
                break;
            }
            p = e;
        }
    }
    return model;
}

bool loadPrinter(A1Engine* e, const char* bundle, std::string& error) {
    json j;
    try { j = json::parse(bundle ? bundle : ""); } catch (...) { error = "That printer profile didn't load."; return false; }
    if (!j.is_object() || !j.contains("machine") || !j.contains("processes") || !j.contains("filaments") || !j.contains("bed")) {
        error = "That printer profile is incomplete.";
        return false;
    }
    e->printer = std::move(j);
    return true;
}

// Bambu .gcode.3mf: the G-code plus the project, plate picture and slice info the printer and Bambu Handy read.
std::string packageBambu(const A1Engine* e, const Project& P, const Plate& pl, const Config& C, const PlateSlice& ps, const GcodeOutput& g,
                         const std::string& fallbackPng, double& totalG) {
    const ZipReader& z = *P.zip;
    ZipWriter zw;
    std::string pid = std::to_string(pl.id);
    std::string gname = "Metadata/plate_" + pid + ".gcode";
    zw.add("[Content_Types].xml", z.has("[Content_Types].xml") ? z.read("[Content_Types].xml")
               : "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">\n"
                 " <Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>\n"
                 " <Default Extension=\"model\" ContentType=\"application/vnd.ms-package.3dmanufacturing-3dmodel+xml\"/>\n"
                 " <Default Extension=\"png\" ContentType=\"image/png\"/>\n <Default Extension=\"gcode\" ContentType=\"text/x.gcode\"/>\n</Types>\n");
    zw.add("_rels/.rels", z.has("_rels/.rels") ? z.read("_rels/.rels")
               : "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\n"
                 " <Relationship Target=\"/3D/3dmodel.model\" Id=\"rel-1\" Type=\"http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel\"/>\n</Relationships>\n");
    for (auto& n : z.names()) {
        if (n.rfind("3D/", 0) != 0) continue;
        std::string data = z.read(n);
        if (n == "3D/3dmodel.model") data = replaceItemTransforms(data, P);
        zw.add(n, data);
    }
    zw.add(gname, g.gcode);
    zw.add(gname + ".md5", md5_hex(g.gcode), false);
    // the app's picture of the plate as it is now; the project's own one may show an older arrangement
    std::string png = !fallbackPng.empty() ? fallbackPng : ((!pl.thumb.empty() && z.has(pl.thumb)) ? z.read(pl.thumb) : "");
    if (!png.empty()) zw.add("Metadata/plate_" + pid + ".png", png, false);
    std::string ms = P.modelSettings();
    {
        std::string needle = "<metadata key=\"plater_id\" value=\"" + pid + "\"/>";
        size_t p = ms.find(needle);
        if (p != std::string::npos) ms.insert(p + needle.size(), "\n    <metadata key=\"gcode_file\" value=\"" + gname + "\"/>");
        else {
            size_t c = ms.rfind("</config>");
            if (c != std::string::npos)
                ms.insert(c, "  <plate>\n    <metadata key=\"plater_id\" value=\"" + pid + "\"/>\n    <metadata key=\"gcode_file\" value=\"" + gname +
                                 "\"/>\n    <metadata key=\"thumbnail_file\" value=\"Metadata/plate_" + pid + ".png\"/>\n  </plate>\n");
        }
    }
    zw.add("Metadata/model_settings.config", ms);
    json pc = C.j;
    pc["printer_model"] = printerName(e->printer);
    pc["from"] = "project";
    pc["name"] = "project_settings";
    zw.add("Metadata/project_settings.config", pc.dump(4));
    totalG = 0;
    for (double x : g.usedG) totalG += x;
    std::ostringstream si;
    si << "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<config>\n  <header>\n    <header_item key=\"X-BBL-Client-Type\" value=\"slicer\"/>\n"
          "    <header_item key=\"X-BBL-Client-Version\" value=\"02.05.00.66\"/>\n  </header>\n  <plate>\n";
    si << "    <metadata key=\"index\" value=\"" << pid << "\"/>\n";
    si << "    <metadata key=\"extruder_type\" value=\"0\"/>\n    <metadata key=\"nozzle_volume_type\" value=\"0\"/>\n";
    si << "    <metadata key=\"printer_model_id\" value=\"" << e->printer.value("model_id", std::string("")) << "\"/>\n";
    si << "    <metadata key=\"nozzle_diameters\" value=\"" << C.str("nozzle_diameter", 0, "0.4") << "\"/>\n";
    si << "    <metadata key=\"timelapse_type\" value=\"0\"/>\n";
    si << "    <metadata key=\"prediction\" value=\"" << (long)std::lround(g.seconds) << "\"/>\n";
    char wb[32];
    std::snprintf(wb, sizeof wb, "%.2f", totalG);
    si << "    <metadata key=\"weight\" value=\"" << wb << "\"/>\n";
    si << "    <metadata key=\"outside\" value=\"false\"/>\n    <metadata key=\"support_used\" value=\"false\"/>\n";
    si << "    <metadata key=\"label_object_enabled\" value=\"false\"/>\n";
    for (int f : ps.filamentsUsed) {
        int i = f - 1;
        char ub[32], gb[32];
        std::snprintf(ub, sizeof ub, "%.2f", g.usedMm[i] / 1000.0);
        std::snprintf(gb, sizeof gb, "%.2f", g.usedG[i]);
        si << "    <filament id=\"" << f << "\" tray_info_idx=\"" << (i < (int)C.filamentIds.size() ? C.filamentIds[i] : "") << "\" type=\""
           << C.str("filament_type", i, "PLA") << "\" color=\"" << C.str("filament_colour", i, "#888888") << "\" used_m=\"" << ub << "\" used_g=\"" << gb
           << "\" />\n";
    }
    si << "  </plate>\n</config>\n";
    zw.add("Metadata/slice_info.config", si.str());
    return zw.finish();
}

}  // namespace

extern "C" {

A1Engine* a1_create(const char* printerBundle) {
    auto* e = new A1Engine();
    std::string er;
    if (printerBundle && *printerBundle && !loadPrinter(e, printerBundle, er)) e->printer = json::object();
    return e;
}
void a1_destroy(A1Engine* e) { delete e; }
void a1_free(void* p) { std::free(p); }

char* a1_set_printer(A1Engine* e, const char* printerBundle) {
    std::string er;
    if (!loadPrinter(e, printerBundle, er)) return err(er);
    placePlates(e);
    e->undo.clear();
    e->lastFile.clear();
    e->lastKind.clear();
    e->lastPlate = -1;
    e->lastSlice = PlateSlice();
    if (!e->proj) return dupJson(json{{"ok", true}, {"printer", printerInfo(e->printer)}});
    return dupJson(json{{"ok", true}, {"project", projectInfo(e)}});
}

char* a1_open(A1Engine* e, const uint8_t* data, size_t len) {
    if (!e->printer.contains("machine")) return err("Choose a printer first.");
    try {
        e->bytes.assign((const char*)data, len);
        e->proj = Project::load(e->bytes);
        placePlates(e);
        e->undo.clear();
        e->lastPlate = -1;
        e->lastFile.clear();
        e->lastKind.clear();
        e->lastSlice = PlateSlice();
        return dupJson(json{{"ok", true}, {"project", projectInfo(e)}});
    } catch (const std::exception& ex) {
        e->proj.reset();
        return err(std::string("That file didn't open as a 3MF project: ") + ex.what());
    }
}

char* a1_info(A1Engine* e) {
    if (!e->proj) return err("No project open.");
    return dupJson(projectInfo(e));
}

char* a1_settings(A1Engine* e, const char* opts) {
    if (!e->proj) return err("No project open.");
    std::vector<std::string> w;
    Project& P = *e->proj;
    json o = parseOpts(opts);
    Config c = buildConfig(e->printer, P.cfg, projectInputs(P, o), o, w);
    json out;
    for (const char* k : {"layer_height", "initial_layer_print_height", "wall_loops", "top_shell_layers", "bottom_shell_layers", "sparse_infill_density",
                          "sparse_infill_pattern", "brim_type", "brim_width", "skirt_loops", "curr_bed_type", "outer_wall_speed", "inner_wall_speed",
                          "sparse_infill_speed", "top_surface_speed", "initial_layer_speed", "wall_sequence", "print_settings_id"})
        out[k] = c.str(k, 0, "");
    out["filament_presets"] = c.filamentPresets;
    json temps = json::array();
    for (int i = 0; i < c.nfil; ++i) temps.push_back(c.str("nozzle_temperature", i, ""));
    out["nozzle_temperature"] = temps;
    out["bed_types"] = supportedBedTypes(e->printer);
    out["warnings"] = w;
    return dupJson(out);
}

int a1_get_transform(A1Engine* e, int oi, double* m) {
    if (!e->proj || oi < 0 || oi >= (int)e->proj->objects.size()) return -1;
    for (int i = 0; i < 12; ++i) m[i] = e->proj->objects[oi].item.m[i];
    return 0;
}
int a1_set_transform(A1Engine* e, int oi, const double* m) {
    if (!e->proj || oi < 0 || oi >= (int)e->proj->objects.size()) return -1;
    pushUndo(e);
    for (int i = 0; i < 12; ++i) e->proj->objects[oi].item.m[i] = m[i];
    return 0;
}
int a1_rotate(A1Engine* e, int oi, int axis, double deg) {
    if (!e->proj || oi < 0 || oi >= (int)e->proj->objects.size()) return -1;
    pushUndo(e);
    double R[9];
    axisAngle(axis == 0, axis == 1, axis == 2, deg * M_PI / 180.0, R);
    applyRotation(*e->proj, e->proj->objects[oi], R);
    return 0;
}
int a1_lay_flat(A1Engine* e, int oi, double nx, double ny, double nz) {
    if (!e->proj || oi < 0 || oi >= (int)e->proj->objects.size()) return -1;
    pushUndo(e);
    rotateNormalDown(*e->proj, e->proj->objects[oi], nx, ny, nz);
    return 0;
}
int a1_auto_flat(A1Engine* e, int oi) {
    if (!e->proj || oi < 0 || oi >= (int)e->proj->objects.size()) return -1;
    pushUndo(e);
    Object& o = e->proj->objects[oi];
    std::map<std::tuple<int, int, int>, std::pair<double, std::array<double, 3>>> buckets;
    for (auto& v : o.volumes)
        for (size_t t = 0; t + 2 < v.tris.size(); t += 3) {
            double p[3][3];
            for (int k = 0; k < 3; ++k) o.item.apply(v.verts[v.tris[t + k] * 3], v.verts[v.tris[t + k] * 3 + 1], v.verts[v.tris[t + k] * 3 + 2], p[k][0], p[k][1], p[k][2]);
            double ux = p[1][0] - p[0][0], uy = p[1][1] - p[0][1], uz = p[1][2] - p[0][2];
            double vx = p[2][0] - p[0][0], vy = p[2][1] - p[0][1], vz = p[2][2] - p[0][2];
            double nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx;
            double a = std::sqrt(nx * nx + ny * ny + nz * nz);
            if (a < 1e-12) continue;
            nx /= a; ny /= a; nz /= a;
            auto key = std::make_tuple((int)std::lround(nx * 25), (int)std::lround(ny * 25), (int)std::lround(nz * 25));
            auto& b = buckets[key];
            b.first += a / 2;
            b.second[0] += nx * a; b.second[1] += ny * a; b.second[2] += nz * a;
        }
    double best = -1;
    std::array<double, 3> n{0, 0, -1};
    for (auto& kv : buckets) if (kv.second.first > best) { best = kv.second.first; n = kv.second.second; }
    rotateNormalDown(*e->proj, o, n[0], n[1], n[2]);
    return 0;
}
int a1_reset_transform(A1Engine* e, int oi) {
    if (!e->proj || oi < 0 || oi >= (int)e->proj->objects.size()) return -1;
    pushUndo(e);
    e->proj->objects[oi].item = e->proj->objects[oi].item0;
    return 0;
}

int a1_center_plate(A1Engine* e, int plate) {
    if (!e->proj || plate < 0 || plate >= (int)e->proj->plates.size()) return -1;
    pushUndo(e);
    Project& P = *e->proj;
    const Plate& pl = P.plates[plate];
    double x0 = 1e18, y0 = 1e18, x1 = -1e18, y1 = -1e18;
    for (int oi : pl.objects) {
        double mn[3], mx[3];
        P.objectBounds(P.objects[oi], P.objects[oi].item, mn, mx);
        x0 = std::min(x0, mn[0] - pl.ox); y0 = std::min(y0, mn[1] - pl.oy);
        x1 = std::max(x1, mx[0] - pl.ox); y1 = std::max(y1, mx[1] - pl.oy);
    }
    if (!(x1 > x0)) return 0;
    Bed b = bedOf(e->printer);
    double dx = (b.x0 + b.x1) / 2 - (x0 + x1) / 2, dy = (b.y0 + b.y1) / 2 - (y0 + y1) / 2;
    for (int oi : pl.objects) {
        P.objects[oi].item.m[9] += dx;
        P.objects[oi].item.m[10] += dy;
    }
    return 0;
}

int a1_plate_mesh(A1Engine* e, int plate, float** xyz, uint8_t** fil, int32_t** obj, size_t* count) {
    if (!e->proj || plate < 0 || plate >= (int)e->proj->plates.size()) return -1;
    std::vector<float> p;
    std::vector<uint8_t> f;
    std::vector<int32_t> ob;
    const Plate& pl = e->proj->plates[plate];
    for (int oi : pl.objects) {
        size_t before = f.size();
        const Object& o = e->proj->objects[oi];
        for (auto& v : o.volumes) {
            for (auto t : v.tris) {
                double x, y, z;
                o.item.apply(v.verts[t * 3], v.verts[t * 3 + 1], v.verts[t * 3 + 2], x, y, z);
                p.push_back((float)(x - pl.ox)); p.push_back((float)(y - pl.oy)); p.push_back((float)z);
            }
            for (size_t k = 0; k < v.tris.size() / 3; ++k) f.push_back((uint8_t)v.filament);
        }
        ob.insert(ob.end(), f.size() - before, oi);
    }
    *xyz = dupBuf(p);
    *fil = dupBuf(f);
    *obj = dupBuf(ob);
    *count = f.size();
    return 0;
}

int a1_plate_thumbnail(A1Engine* e, int plate, uint8_t** data, size_t* len) {
    if (!e->proj || plate < 0 || plate >= (int)e->proj->plates.size()) return -1;
    const Plate& pl = e->proj->plates[plate];
    if (pl.thumb.empty() || !e->proj->zip->has(pl.thumb)) return -1;
    std::string s = e->proj->zip->read(pl.thumb);
    *data = dupStr(s);
    *len = s.size();
    return 0;
}

char* a1_slice(A1Engine* e, int plate, const char* optsJson, A1Progress progress, void* ctx) {
    if (!e->proj) return err("No project open.");
    if (!e->printer.contains("machine")) return err("Choose a printer first.");
    Project& P = *e->proj;
    if (plate < 0 || plate >= (int)P.plates.size()) return err("No such plate.");
    try {
        json opts = parseOpts(optsJson);
        const Plate& pl = P.plates[plate];
        const bool tc = isToolChanger(e->printer);
        std::vector<int> used = plateFilaments(P, plate);
        if (used.empty()) return err("Nothing to print on this plate.");
        std::vector<int> toolOf;
        if (tc) {
            std::string er;
            if (!toolMapFor(e->printer, P, used, opts, toolOf, er)) return err(er);
        } else {
            for (size_t i = 0; i < P.colors.size(); ++i) toolOf.push_back((int)i);
        }
        std::vector<std::string> warnings;
        Config C = buildConfig(e->printer, P.cfg, gcodeInputs(e->printer, P, used, toolOf, opts), opts, warnings);
        for (int f : used) {
            int g = toolOf[f - 1];
            if (C.bedTemp(g, true) <= 0)
                return err("The " + C.filamentPresets[g] + " profile has no bed temperature for the " + C.str("curr_bed_type", 0, "plate") +
                           ". Pick another plate type or filament profile.");
        }
        Bed bed = bedOf(e->printer);
        std::vector<std::array<double, 4>> boxes;
        for (int oi : pl.objects) {
            double mn[3], mx[3];
            std::string issue = fitIssue(P, pl, P.objects[oi], bed, mn, mx);
            if (!issue.empty()) return err(fitMessage(issue, P.objects[oi].name, e->printer, bed));
            boxes.push_back({mn[0], mn[1], mx[0], mx[1]});
        }
        SliceSettings base = C.sliceSettings();
        std::vector<SliceSettings> per(P.objects.size(), base);
        for (size_t i = 0; i < P.objects.size(); ++i)
            if (!P.objects[i].overrides.empty()) per[i] = C.sliceSettingsFor(P.objects[i].overrides);
        if (C.str("enable_support", 0, "0") == "1") warnings.push_back("Supports aren't generated yet; they were left out.");
        auto cb = [&](double f) { if (progress) progress(f * 0.9, ctx); };
        PlateSlice ps = slicePlate(P, plate, base, per, cb);
        for (auto& w : ps.warnings) warnings.push_back(w);

        GcodeExtras X;
        X.objectBoxes = boxes;
        std::string fallbackPng;
        if (opts.contains("thumbnails") && opts["thumbnails"].is_array())
            for (auto& t : opts["thumbnails"])
                if (t.is_string()) {
                    std::string png = unbase64(t.get<std::string>());
                    if (png.size() > 24) X.thumbnails.push_back(png);
                }
        for (auto& t : X.thumbnails) if (t.size() > fallbackPng.size()) fallbackPng = t;
        if (tc) {
            X.toolOf = toolOf;
            if (X.thumbnails.empty() && !pl.thumb.empty() && P.zip->has(pl.thumb)) X.thumbnails.push_back(P.zip->read(pl.thumb));
            for (int oi : pl.objects) X.labels.push_back(labelFor(P, pl, oi));
        }
        GcodeOutput g = writeGcode(ps, C, pl.name, X);
        for (auto& w : g.warnings) warnings.push_back(w);
        if (g.gcode.empty()) return err("Nothing to print on this plate.");
        if (progress) progress(0.95, ctx);

        double totalG = 0;
        std::string gname;
        if (tc) {
            for (double x : g.usedG) totalG += x;
            e->lastFile = g.gcode;
            e->lastKind = "gcode";
            gname = "plate_" + std::to_string(pl.id) + ".gcode";
        } else {
            e->lastFile = packageBambu(e, P, pl, C, ps, g, fallbackPng, totalG);
            e->lastKind = "gcode.3mf";
            gname = "Metadata/plate_" + std::to_string(pl.id) + ".gcode";
        }
        // filament summary: per project filament on Bambu (AMS mapping), per toolhead on tool changers
        json fils = json::array();
        if (tc) {
            std::vector<int> tools;
            for (int f : used) if (std::find(tools.begin(), tools.end(), toolOf[f - 1]) == tools.end()) tools.push_back(toolOf[f - 1]);
            std::sort(tools.begin(), tools.end());
            for (int t : tools) {
                json pfs = json::array();
                for (int f : used) if (toolOf[f - 1] == t) pfs.push_back(f);
                fils.push_back({{"id", pfs[0]}, {"tool", t}, {"project_filaments", pfs}, {"type", C.str("filament_type", t, "PLA")},
                                {"color", C.str("filament_colour", t, "#888888")}, {"grams", g.usedG[t]}, {"meters", g.usedMm[t] / 1000.0},
                                {"flush_grams", 0.0}, {"preset", C.filamentPresets[t]}, {"tray_info_idx", t < (int)C.filamentIds.size() ? C.filamentIds[t] : ""}});
            }
        } else {
            for (int f : ps.filamentsUsed) {
                int i = f - 1;
                fils.push_back({{"id", f}, {"tool", i}, {"project_filaments", {f}}, {"type", C.str("filament_type", i, "PLA")},
                                {"color", C.str("filament_colour", i, "#888888")}, {"grams", g.usedG[i]}, {"meters", g.usedMm[i] / 1000.0},
                                {"flush_grams", g.flushG[i]}, {"preset", C.filamentPresets[i]}, {"tray_info_idx", i < (int)C.filamentIds.size() ? C.filamentIds[i] : ""}});
            }
        }
        e->lastSlice = std::move(ps);
        e->lastPlate = plate;
        if (progress) progress(1.0, ctx);
        std::string bedType = C.str("curr_bed_type", 0, "Textured PEI Plate");
        static const std::map<std::string, std::string> bedCodes = {{"Textured PEI Plate", "textured_plate"}, {"Cool Plate", "cool_plate"},
                                                                    {"Engineering Plate", "eng_plate"}, {"High Temp Plate", "hot_plate"},
                                                                    {"Supertack Plate", "supertack_plate"}, {"Textured Cool Plate", "textured_cool_plate"}};
        json tm = json::array();
        for (int t : toolOf) tm.push_back(t);
        json out{{"ok", true},
                 {"plate", plate},
                 {"plate_id", pl.id},
                 {"printer_id", e->printer.value("id", std::string(""))},
                 {"printer", printerName(e->printer)},
                 {"file_kind", e->lastKind},
                 {"gcode_path", gname},
                 {"seconds", g.seconds},
                 {"model_seconds", g.modelSeconds},
                 {"grams", totalG},
                 {"layers", g.layers},
                 {"tool_changes", g.toolChanges},
                 {"filaments", fils},
                 {"tool_map", tc ? tm : json(nullptr)},
                 {"bed_type", bedType},
                 {"bed_code", bedCodes.count(bedType) ? bedCodes.at(bedType) : "auto"},
                 {"process", C.str("print_settings_id", 0, "")},
                 {"file_bytes", e->lastFile.size()},
                 {"warnings", warnings}};
        return dupJson(out);
    } catch (const std::exception& ex) {
        return err(std::string("Slicing failed: ") + ex.what());
    }
}

int a1_sliced_file(A1Engine* e, uint8_t** data, size_t* len) {
    if (e->lastFile.empty()) return -1;
    *data = dupStr(e->lastFile);
    *len = e->lastFile.size();
    return 0;
}

int a1_export_project(A1Engine* e, uint8_t** data, size_t* len) {
    if (!e->proj) return -1;
    const ZipReader& z = *e->proj->zip;
    ZipWriter zw;
    bool wroteSettings = false;
    for (auto& n : z.names()) {
        std::string d = z.read(n);
        if (n == "3D/3dmodel.model") d = replaceItemTransforms(d, *e->proj);
        if (n == "Metadata/model_settings.config") { d = e->proj->modelSettings(); wroteSettings = true; }
        zw.add(n, d, n.size() < 4 || n.substr(n.size() - 4) != ".png");
    }
    if (!wroteSettings && e->proj->platesEdited) zw.add("Metadata/model_settings.config", e->proj->modelSettings());
    std::string s = zw.finish();
    *data = dupStr(s);
    *len = s.size();
    return 0;
}

int a1_layer_count(A1Engine* e) { return (int)e->lastSlice.layers.size(); }
double a1_layer_z(A1Engine* e, int layer) {
    if (layer < 0 || layer >= (int)e->lastSlice.layers.size()) return 0;
    return e->lastSlice.layers[layer].z;
}

int a1_layer_preview(A1Engine* e, int layer, float** segs, uint16_t** meta, size_t* count) {
    if (layer < 0 || layer >= (int)e->lastSlice.layers.size()) return -1;
    std::vector<float> s;
    std::vector<uint16_t> m;
    for (auto& isl : e->lastSlice.layers[layer].islands)
        for (auto& tp : isl.paths) {
            size_t n = tp.pts.size();
            size_t last = tp.closed ? n : n - 1;
            for (size_t i = 0; i < last; ++i) {
                auto& a = tp.pts[i];
                auto& b = tp.pts[(i + 1) % n];
                s.push_back((float)(a.x / kScale)); s.push_back((float)(a.y / kScale));
                s.push_back((float)(b.x / kScale)); s.push_back((float)(b.y / kScale));
                m.push_back((uint16_t)((int)tp.role | (isl.filament << 8)));
            }
        }
    *segs = dupBuf(s);
    *meta = dupBuf(m);
    *count = m.size();
    return 0;
}

// ---- placement edits (each one can be undone)

int a1_move_object(A1Engine* e, int oi, double dx, double dy) {
    if (!e->proj || oi < 0 || oi >= (int)e->proj->objects.size()) return -1;
    pushUndo(e);
    shiftObject(e->proj->objects[oi], dx, dy);
    return 0;
}

int a1_place_object(A1Engine* e, int oi, double x, double y) {
    if (!e->proj || oi < 0 || oi >= (int)e->proj->objects.size()) return -1;
    pushUndo(e);
    Object& o = e->proj->objects[oi];
    Box f = footprint(*e->proj, o);
    shiftObject(o, x - (f.x0 + f.x1) / 2, y - (f.y0 + f.y1) / 2);
    return 0;
}

char* a1_arrange(A1Engine* e, int plate, const char* optsJson) {
    if (!e->proj) return err("No project open.");
    Project& P = *e->proj;
    if (plate < 0 || plate >= (int)P.plates.size()) return err("No such plate.");
    json o = parseOpts(optsJson);
    double gap = o.value("spacing", kArrangeGap);
    bool rotate = o.value("allow_rotation", false);
    Bed b = bedOf(e->printer);
    pushUndo(e);
    // biggest footprints first
    std::vector<int> order = P.plates[plate].objects;
    std::vector<double> area(P.objects.size(), 0);
    for (int oi : order) { Box f = footprint(P, P.objects[oi]); area[oi] = f.w() * f.d(); }
    std::stable_sort(order.begin(), order.end(), [&](int a, int c) { return area[a] > area[c]; });
    std::vector<Box> taken;
    if (b.hasEx()) taken.push_back({b.ex0, b.ey0, b.ex1, b.ey1});
    std::vector<int> placed, left;
    for (int oi : order) {
        Object& ob = P.objects[oi];
        Box f = footprint(P, ob);
        double x = 0, y = 0;
        bool ok = findSpot(b, kBedMargin, gap, f.w(), f.d(), taken, x, y);
        if (rotate) {
            double x2 = 0, y2 = 0;
            bool ok2 = findSpot(b, kBedMargin, gap, f.d(), f.w(), taken, x2, y2);
            if (ok2 && (!ok || y2 < y - 1e-6 || (std::fabs(y2 - y) < 1e-6 && x2 < x - 1e-6))) {
                double R[9];
                axisAngle(0, 0, 1, M_PI / 2, R);
                applyRotation(P, ob, R);
                f = footprint(P, ob);
                x = x2;
                y = y2;
                ok = true;
            }
        }
        if (!ok) { left.push_back(oi); continue; }
        shiftObject(ob, x - f.x0, y - f.y0);
        taken.push_back(footprint(P, ob));
        placed.push_back(oi);
    }
    // centre the packed group on the bed, as far as the no-print corner allows
    if (!placed.empty()) {
        Box g{1e18, 1e18, -1e18, -1e18};
        for (int oi : placed) {
            Box f = footprint(P, P.objects[oi]);
            g.x0 = std::min(g.x0, f.x0); g.y0 = std::min(g.y0, f.y0);
            g.x1 = std::max(g.x1, f.x1); g.y1 = std::max(g.y1, f.y1);
        }
        double dx = (b.x0 + b.x1) / 2 - (g.x0 + g.x1) / 2, dy = (b.y0 + b.y1) / 2 - (g.y0 + g.y1) / 2;
        auto clear = [&](double sx, double sy) {
            for (int oi : placed) {
                Box f = footprint(P, P.objects[oi]);
                Box m{f.x0 + sx, f.y0 + sy, f.x1 + sx, f.y1 + sy};
                if (!insideBed(m, b, kBedMargin)) return false;
                if (b.hasEx() && tooClose(m, Box{b.ex0, b.ey0, b.ex1, b.ey1}, gap)) return false;
            }
            return true;
        };
        double sx = 0, sy = 0;
        if (clear(dx, dy)) { sx = dx; sy = dy; }
        else if (clear(dx, 0)) sx = dx;
        else if (clear(0, dy)) sy = dy;
        for (int oi : placed) shiftObject(P.objects[oi], sx, sy);
    }
    // what didn't fit waits to the right of the bed (it shows as not fitting until it's moved to another plate)
    double nextX = b.x1 + 15;
    json names = json::array();
    for (int oi : left) {
        Box f = footprint(P, P.objects[oi]);
        shiftObject(P.objects[oi], nextX - f.x0, b.y0 + kBedMargin - f.y0);
        nextX += f.w() + gap;
        names.push_back(P.objects[oi].name);
    }
    return dupJson(json{{"ok", true}, {"placed", placed.size()}, {"left_over", names}, {"project", projectInfo(e)}});
}

char* a1_move_to_plate(A1Engine* e, int oi, int target) {
    if (!e->proj) return err("No project open.");
    Project& P = *e->proj;
    if (oi < 0 || oi >= (int)P.objects.size()) return err("No such object.");
    if (target < -1 || target > (int)P.plates.size()) return err("No such plate.");
    if (target == P.objects[oi].plate) return dupJson(json{{"ok", true}, {"plate", target}, {"project", projectInfo(e)}});
    pushUndo(e);
    if (target < 0 || target == (int)P.plates.size()) target = addPlate(P);
    Object& o = P.objects[oi];
    int from = o.plate;
    Plate& a = P.plates[from];
    Plate& b = P.plates[target];
    // the same spot on the other plate's bed
    carryObject(o, b.ox - a.ox, b.oy - a.oy);
    a.objects.erase(std::remove(a.objects.begin(), a.objects.end(), oi), a.objects.end());
    b.objects.push_back(oi);
    o.plate = target;
    a.thumb.clear();
    b.thumb.clear();
    P.platesEdited = true;
    // something already there: the front-left-most free spot instead
    Bed bed = bedOf(e->printer);
    std::vector<Box> others = obstacles(P, bed, target, oi);
    Box f = footprint(P, o);
    if (!spotFree(f, bed, 0, kArrangeGap, others)) {
        double x = 0, y = 0;
        if (findSpot(bed, kBedMargin, kArrangeGap, f.w(), f.d(), others, x, y)) shiftObject(o, x - f.x0, y - f.y0);
    }
    return dupJson(json{{"ok", true}, {"plate", target}, {"project", projectInfo(e)}});
}

int a1_add_plate(A1Engine* e) {
    if (!e->proj) return -1;
    pushUndo(e);
    return addPlate(*e->proj);
}

int a1_remove_plate(A1Engine* e, int plate) {
    if (!e->proj) return -1;
    Project& P = *e->proj;
    if (plate < 0 || plate >= (int)P.plates.size() || P.plates.size() < 2 || !P.plates[plate].objects.empty()) return -1;
    pushUndo(e);
    P.plates.erase(P.plates.begin() + plate);
    for (auto& o : P.objects)
        if (o.plate > plate) o.plate--;
    for (size_t i = 0; i < P.plates.size(); ++i) {
        Plate& pl = P.plates[i];
        pl.id = (int)i + 1;
        if (!pl.named) pl.name = "Plate " + std::to_string(pl.id);
    }
    P.platesEdited = true;
    P.layoutPlates();
    return 0;
}

int a1_undo(A1Engine* e) {
    if (!e->proj || e->undo.empty()) return -1;
    Placement s = std::move(e->undo.back());
    e->undo.pop_back();
    Project& P = *e->proj;
    P.plates = std::move(s.plates);
    for (size_t i = 0; i < P.objects.size() && i < s.objects.size(); ++i) {
        P.objects[i].item = std::get<0>(s.objects[i]);
        P.objects[i].item0 = std::get<1>(s.objects[i]);
        P.objects[i].plate = std::get<2>(s.objects[i]);
    }
    P.platesEdited = s.platesEdited;
    return 0;
}

}  // extern "C"
