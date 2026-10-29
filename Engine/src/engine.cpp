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

#include "../include/a1engine.h"
#include "config.hpp"
#include "gcode.hpp"
#include "project.hpp"
#include "slicer.hpp"
#include "zipio.hpp"

using namespace a1;
using json = nlohmann::json;

struct A1Engine {
    json profiles;
    std::string bytes;  // original archive
    std::unique_ptr<Project> proj;
    PlateSlice lastSlice;
    std::string lastFile;
    int lastPlate = -1;
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

json projectInfo(A1Engine* e) {
    Project& P = *e->proj;
    json j;
    j["printer_model"] = P.printerModel;
    j["filaments"] = json::array();
    for (size_t i = 0; i < P.colors.size(); ++i) {
        j["filaments"].push_back({{"index", i + 1}, {"color", P.colors[i]}, {"type", P.types[i]}, {"setting_id", P.settingIds[i]},
                                  {"preset", mapFilamentPreset(e->profiles, P.settingIds[i], P.types[i])}});
    }
    j["plates"] = json::array();
    for (size_t pi = 0; pi < P.plates.size(); ++pi) {
        const Plate& pl = P.plates[pi];
        json pj{{"index", pi}, {"id", pl.id}, {"name", pl.name}, {"has_thumbnail", !pl.thumb.empty()}, {"objects", json::array()}};
        std::vector<int> fil;
        bool off = false;
        double zmax = 0;
        for (int oi : pl.objects) {
            const Object& o = P.objects[oi];
            double mn[3], mx[3];
            P.objectBounds(o, o.item, mn, mx);
            bool out = mn[0] - pl.ox < -0.05 || mn[1] - pl.oy < -0.05 || mx[0] - pl.ox > P.bedW + 0.05 || mx[1] - pl.oy > P.bedD + 0.05 || mx[2] > 256.0;
            off = off || out;
            zmax = std::max(zmax, mx[2]);
            json oj{{"index", oi}, {"id", o.id}, {"name", o.name}, {"filaments", json::array()}, {"off_bed", out}, {"edited", o.item.m != o.item0.m},
                    {"min", {mn[0] - pl.ox, mn[1] - pl.oy, mn[2]}}, {"max", {mx[0] - pl.ox, mx[1] - pl.oy, mx[2]}}, {"overrides", o.overrides}};
            for (auto& v : o.volumes) {
                oj["filaments"].push_back(v.filament);
                if (std::find(fil.begin(), fil.end(), v.filament) == fil.end()) fil.push_back(v.filament);
            }
            pj["objects"].push_back(oj);
        }
        std::sort(fil.begin(), fil.end());
        pj["filaments"] = fil;
        pj["off_bed"] = off;
        pj["height"] = zmax;
        j["plates"].push_back(pj);
    }
    j["processes"] = json::array();
    for (auto& kv : e->profiles["processes"].items()) j["processes"].push_back(kv.key());
    j["default_process"] = e->profiles.value("default_process", std::string(""));
    // pick the preset matching the project's layer height
    if (P.cfg.contains("layer_height")) {
        double lh = std::atof(P.cfg["layer_height"].is_string() ? P.cfg["layer_height"].get<std::string>().c_str() : P.cfg["layer_height"].dump().c_str());
        for (auto& kv : e->profiles["processes"].items()) {
            const json& p = kv.value();
            if (p.contains("layer_height") && std::fabs(std::atof(p["layer_height"].get<std::string>().c_str()) - lh) < 1e-6 &&
                (kv.key().find("Standard") != std::string::npos || kv.key().find("Optimal") != std::string::npos || kv.key().find("Fine") != std::string::npos ||
                 kv.key().find("Draft") != std::string::npos)) {
                j["default_process"] = kv.key();
                break;
            }
        }
    }
    j["filament_presets"] = json::array();
    for (auto& kv : e->profiles["filaments"].items()) j["filament_presets"].push_back(kv.key());
    j["bed_type"] = P.cfg.value("curr_bed_type", std::string("Textured PEI Plate"));
    return j;
}

std::string replaceItemTransforms(std::string model, const Project& P) {
    for (auto& o : P.objects) {
        if (o.item.m == o.item0.m) continue;
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

}  // namespace

extern "C" {

A1Engine* a1_create(const char* profilesJson) {
    auto* e = new A1Engine();
    try { e->profiles = json::parse(profilesJson ? profilesJson : "{}"); } catch (...) { e->profiles = json::object(); }
    return e;
}
void a1_destroy(A1Engine* e) { delete e; }
void a1_free(void* p) { std::free(p); }

char* a1_open(A1Engine* e, const uint8_t* data, size_t len) {
    try {
        e->bytes.assign((const char*)data, len);
        e->proj = Project::load(e->bytes);
        e->lastPlate = -1;
        e->lastFile.clear();
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
    Config c = buildConfig(e->profiles, P.cfg, (int)P.colors.size(), P.colors, P.types, P.settingIds, parseOpts(opts), w);
    json out;
    for (const char* k : {"layer_height", "initial_layer_print_height", "wall_loops", "top_shell_layers", "bottom_shell_layers", "sparse_infill_density",
                          "sparse_infill_pattern", "brim_type", "brim_width", "skirt_loops", "curr_bed_type", "outer_wall_speed", "inner_wall_speed",
                          "sparse_infill_speed", "top_surface_speed", "initial_layer_speed", "wall_sequence", "print_settings_id"})
        out[k] = c.str(k, 0, "");
    out["filament_presets"] = c.filamentPresets;
    json temps = json::array();
    for (int i = 0; i < c.nfil; ++i) temps.push_back(c.str("nozzle_temperature", i, ""));
    out["nozzle_temperature"] = temps;
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
    for (int i = 0; i < 12; ++i) e->proj->objects[oi].item.m[i] = m[i];
    return 0;
}
int a1_rotate(A1Engine* e, int oi, int axis, double deg) {
    if (!e->proj || oi < 0 || oi >= (int)e->proj->objects.size()) return -1;
    double R[9];
    axisAngle(axis == 0, axis == 1, axis == 2, deg * M_PI / 180.0, R);
    applyRotation(*e->proj, e->proj->objects[oi], R);
    return 0;
}
int a1_lay_flat(A1Engine* e, int oi, double nx, double ny, double nz) {
    if (!e->proj || oi < 0 || oi >= (int)e->proj->objects.size()) return -1;
    rotateNormalDown(*e->proj, e->proj->objects[oi], nx, ny, nz);
    return 0;
}
int a1_auto_flat(A1Engine* e, int oi) {
    if (!e->proj || oi < 0 || oi >= (int)e->proj->objects.size()) return -1;
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
    e->proj->objects[oi].item = e->proj->objects[oi].item0;
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
    Project& P = *e->proj;
    if (plate < 0 || plate >= (int)P.plates.size()) return err("No such plate.");
    try {
        json opts = parseOpts(optsJson);
        std::vector<std::string> warnings;
        Config C = buildConfig(e->profiles, P.cfg, (int)P.colors.size(), P.colors, P.types, P.settingIds, opts, warnings);
        SliceSettings base = C.sliceSettings();
        std::vector<SliceSettings> per(P.objects.size(), base);
        for (size_t i = 0; i < P.objects.size(); ++i)
            if (!P.objects[i].overrides.empty()) per[i] = C.sliceSettingsFor(P.objects[i].overrides);
        // off-bed check
        const Plate& pl = P.plates[plate];
        for (int oi : pl.objects) {
            double mn[3], mx[3];
            P.objectBounds(P.objects[oi], P.objects[oi].item, mn, mx);
            if (mn[0] - pl.ox < -0.05 || mn[1] - pl.oy < -0.05 || mx[0] - pl.ox > P.bedW + 0.05 || mx[1] - pl.oy > P.bedD + 0.05)
                return err(P.objects[oi].name + " hangs off the bed. Move or rotate it so it fits, then slice again.");
            if (mx[2] > 256.0) return err(P.objects[oi].name + " is taller than the A1's 256 mm.");
        }
        if (C.str("enable_support", 0, "0") == "1") warnings.push_back("Supports aren't generated yet; they were left out.");
        auto cb = [&](double f) { if (progress) progress(f * 0.9, ctx); };
        PlateSlice ps = slicePlate(P, plate, base, per, cb);
        for (auto& w : ps.warnings) warnings.push_back(w);
        GcodeOutput g = writeGcode(ps, C, pl.name);
        for (auto& w : g.warnings) warnings.push_back(w);
        if (g.gcode.empty()) return err("Nothing to print on this plate.");
        if (progress) progress(0.95, ctx);

        // package .gcode.3mf
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
        if (!pl.thumb.empty() && z.has(pl.thumb)) zw.add("Metadata/plate_" + pid + ".png", z.read(pl.thumb), false);
        // model settings with gcode reference
        std::string ms = z.has("Metadata/model_settings.config") ? z.read("Metadata/model_settings.config") : "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<config>\n</config>\n";
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
        pc["printer_model"] = "Bambu Lab A1";
        pc["from"] = "project";
        pc["name"] = "project_settings";
        zw.add("Metadata/project_settings.config", pc.dump(4));
        // slice info
        double totalG = 0;
        std::ostringstream si;
        si << "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<config>\n  <header>\n    <header_item key=\"X-BBL-Client-Type\" value=\"slicer\"/>\n"
              "    <header_item key=\"X-BBL-Client-Version\" value=\"02.05.00.66\"/>\n  </header>\n  <plate>\n";
        si << "    <metadata key=\"index\" value=\"" << pid << "\"/>\n";
        si << "    <metadata key=\"extruder_type\" value=\"0\"/>\n    <metadata key=\"nozzle_volume_type\" value=\"0\"/>\n";
        si << "    <metadata key=\"printer_model_id\" value=\"N2S\"/>\n";
        si << "    <metadata key=\"nozzle_diameters\" value=\"" << C.str("nozzle_diameter", 0, "0.4") << "\"/>\n";
        si << "    <metadata key=\"timelapse_type\" value=\"0\"/>\n";
        si << "    <metadata key=\"prediction\" value=\"" << (long)std::lround(g.seconds) << "\"/>\n";
        for (double x : g.usedG) totalG += x;
        char wb[32];
        std::snprintf(wb, sizeof wb, "%.2f", totalG);
        si << "    <metadata key=\"weight\" value=\"" << wb << "\"/>\n";
        si << "    <metadata key=\"outside\" value=\"false\"/>\n    <metadata key=\"support_used\" value=\"false\"/>\n";
        si << "    <metadata key=\"label_object_enabled\" value=\"false\"/>\n";
        json fils = json::array();
        for (int f : ps.filamentsUsed) {
            int i = f - 1;
            char ub[32], gb[32];
            std::snprintf(ub, sizeof ub, "%.2f", g.usedMm[i] / 1000.0);
            std::snprintf(gb, sizeof gb, "%.2f", g.usedG[i]);
            std::string col = C.str("filament_colour", i, "#888888");
            si << "    <filament id=\"" << f << "\" tray_info_idx=\"" << (i < (int)C.filamentIds.size() ? C.filamentIds[i] : "") << "\" type=\""
               << C.str("filament_type", i, "PLA") << "\" color=\"" << col << "\" used_m=\"" << ub << "\" used_g=\"" << gb << "\" />\n";
            fils.push_back({{"id", f}, {"type", C.str("filament_type", i, "PLA")}, {"color", col}, {"grams", g.usedG[i]}, {"meters", g.usedMm[i] / 1000.0},
                            {"flush_grams", g.flushG[i]}, {"preset", C.filamentPresets[i]}, {"tray_info_idx", i < (int)C.filamentIds.size() ? C.filamentIds[i] : ""}});
        }
        si << "  </plate>\n</config>\n";
        zw.add("Metadata/slice_info.config", si.str());
        e->lastFile = zw.finish();
        e->lastSlice = std::move(ps);
        e->lastPlate = plate;
        if (progress) progress(1.0, ctx);
        std::string bedType = C.str("curr_bed_type", 0, "Textured PEI Plate");
        static const std::map<std::string, std::string> bedCodes = {{"Textured PEI Plate", "textured_plate"}, {"Cool Plate", "cool_plate"},
                                                                    {"Engineering Plate", "eng_plate"}, {"High Temp Plate", "hot_plate"},
                                                                    {"Supertack Plate", "supertack_plate"}};
        json out{{"ok", true},
                 {"plate", plate},
                 {"plate_id", pl.id},
                 {"gcode_path", gname},
                 {"seconds", g.seconds},
                 {"model_seconds", g.modelSeconds},
                 {"grams", totalG},
                 {"layers", g.layers},
                 {"tool_changes", g.toolChanges},
                 {"filaments", fils},
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
    for (auto& n : z.names()) {
        std::string d = z.read(n);
        if (n == "3D/3dmodel.model") d = replaceItemTransforms(d, *e->proj);
        zw.add(n, d, n.size() < 4 || n.substr(n.size() - 4) != ".png");
    }
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

}  // extern "C"
