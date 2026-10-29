#include "project.hpp"

#include <algorithm>
#include <map>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <sstream>
#include <stdexcept>

namespace a1 {

Mat Mat::parse(const std::string& s) {
    Mat r;
    if (s.empty()) return r;
    std::istringstream is(s);
    for (int i = 0; i < 12 && is; ++i) is >> r.m[i];
    return r;
}

std::string Mat::str() const {
    std::ostringstream os;
    os.precision(12);
    for (int i = 0; i < 12; ++i) {
        double v = std::fabs(m[i]) < 1e-12 ? 0.0 : m[i];
        if (i) os << ' ';
        os << v;
    }
    return os.str();
}

namespace {

// Value of attribute `name` inside a tag's text, or "".
std::string attr(const char* b, const char* e, const char* name) {
    size_t nl = std::strlen(name);
    for (const char* p = b; p + nl + 2 < e; ++p) {
        if ((p == b || p[-1] == ' ' || p[-1] == '\t' || p[-1] == '\n' || p[-1] == '\r') && std::memcmp(p, name, nl) == 0 && p[nl] == '=' &&
            (p[nl + 1] == '"' || p[nl + 1] == '\'')) {
            char q = p[nl + 1];
            const char* v = p + nl + 2;
            const char* ve = v;
            while (ve < e && *ve != q) ++ve;
            return std::string(v, ve);
        }
    }
    return "";
}

std::string unescape(std::string s) {
    static const std::pair<const char*, const char*> rep[] = {{"&lt;", "<"}, {"&gt;", ">"}, {"&quot;", "\""}, {"&apos;", "'"}, {"&amp;", "&"}};
    for (auto& r : rep) {
        size_t p = 0;
        while ((p = s.find(r.first, p)) != std::string::npos) { s.replace(p, std::strlen(r.first), r.second); p += std::strlen(r.second); }
    }
    return s;
}

// Iterate over tags named `tag` (e.g. "vertex") in [b,e). Calls f(tagBegin, tagEnd).
template <class F>
void eachTag(const char* b, const char* e, const char* tag, F f) {
    size_t tl = std::strlen(tag);
    const char* p = b;
    while (p < e) {
        const char* lt = (const char*)std::memchr(p, '<', e - p);
        if (!lt) break;
        if (lt + tl + 1 < e && std::memcmp(lt + 1, tag, tl) == 0 && (lt[tl + 1] == ' ' || lt[tl + 1] == '>' || lt[tl + 1] == '/' || lt[tl + 1] == '\n' || lt[tl + 1] == '\t' || lt[tl + 1] == '\r')) {
            const char* gt = (const char*)std::memchr(lt, '>', e - lt);
            if (!gt) break;
            f(lt, gt);
            p = gt + 1;
        } else {
            p = lt + 1;
        }
    }
}

// Finds <tag ...> ... </tag> blocks (non-nested for same tag). f(openBegin, openEnd, bodyBegin, bodyEnd)
template <class F>
void eachBlock(const char* b, const char* e, const char* tag, F f) {
    std::string open = std::string("<") + tag, close = std::string("</") + tag + ">";
    const char* p = b;
    while (p < e) {
        const char* s = std::search(p, e, open.begin(), open.end());
        if (s == e) break;
        char nc = s[open.size()];
        if (!(nc == ' ' || nc == '>' || nc == '\n' || nc == '\t' || nc == '/' || nc == '\r')) { p = s + 1; continue; }
        const char* gt = (const char*)std::memchr(s, '>', e - s);
        if (!gt) break;
        if (gt[-1] == '/') { f(s, gt, gt, gt); p = gt + 1; continue; }
        const char* c = std::search(gt, e, close.begin(), close.end());
        if (c == e) break;
        f(s, gt, gt + 1, c);
        p = c + close.size();
    }
}

int paintState(const std::string& hex) {
    if (hex.empty()) return 0;
    auto hv = [](char c) { return c >= '0' && c <= '9' ? c - '0' : (c >= 'a' && c <= 'f' ? c - 'a' + 10 : (c >= 'A' && c <= 'F' ? c - 'A' + 10 : 0)); };
    int n = hv(hex.back());
    if ((n & 3) != 0) return -1;  // subdivided triangle
    int s = n >> 2;
    if (s == 3) s = (hex.size() > 1 ? hv(hex[hex.size() - 2]) : 0) + 3;
    return s;
}

struct RawMesh {
    std::vector<float> verts;
    std::vector<uint32_t> tris;
    std::vector<int8_t> paint;
    bool painted = false;
};

void parseMeshes(const std::string& text, const std::string& path, std::map<std::string, RawMesh>& out) {
    const char* b = text.data();
    const char* e = b + text.size();
    eachBlock(b, e, "object", [&](const char* ob, const char* oe, const char* bb, const char* be) {
        std::string id = attr(ob, oe, "id");
        RawMesh m;
        eachTag(bb, be, "vertex", [&](const char* tb, const char* te) {
            m.verts.push_back((float)std::atof(attr(tb, te, "x").c_str()));
            m.verts.push_back((float)std::atof(attr(tb, te, "y").c_str()));
            m.verts.push_back((float)std::atof(attr(tb, te, "z").c_str()));
        });
        if (m.verts.empty()) return;
        eachTag(bb, be, "triangle", [&](const char* tb, const char* te) {
            m.tris.push_back((uint32_t)std::strtoul(attr(tb, te, "v1").c_str(), nullptr, 10));
            m.tris.push_back((uint32_t)std::strtoul(attr(tb, te, "v2").c_str(), nullptr, 10));
            m.tris.push_back((uint32_t)std::strtoul(attr(tb, te, "v3").c_str(), nullptr, 10));
            std::string pc = attr(tb, te, "paint_color");
            if (!pc.empty()) m.painted = true;
            m.paint.push_back((int8_t)paintState(pc));
        });
        out[path + "#" + id] = std::move(m);
    });
}

}  // namespace

std::unique_ptr<Project> Project::load(const std::string& bytes) {
    auto P = std::make_unique<Project>();
    P->zip.reset(new ZipReader(bytes));
    const ZipReader& z = *P->zip;
    std::string mainPath = "3D/3dmodel.model";
    if (!z.has(mainPath)) {
        for (auto& n : z.names())
            if (n.size() > 6 && n.substr(n.size() - 6) == ".model") { mainPath = n; break; }
    }
    std::string mainText = z.read(mainPath);
    if (z.has("Metadata/project_settings.config")) {
        try { P->cfg = json::parse(z.read("Metadata/project_settings.config")); } catch (...) { P->cfg = json::object(); }
    } else {
        P->cfg = json::object();
    }
    auto strs = [&](const char* k) {
        std::vector<std::string> v;
        if (P->cfg.contains(k) && P->cfg[k].is_array())
            for (auto& x : P->cfg[k]) v.push_back(x.is_string() ? x.get<std::string>() : x.dump());
        return v;
    };
    P->colors = strs("filament_colour");
    P->types = strs("filament_type");
    P->settingIds = strs("filament_settings_id");
    if (P->colors.empty()) P->colors = {"#9AA4AA"};
    for (auto& c : P->colors) if (c.size() > 7) c = c.substr(0, 7);
    while (P->types.size() < P->colors.size()) P->types.push_back("PLA");
    while (P->settingIds.size() < P->colors.size()) P->settingIds.push_back("");
    if (P->cfg.contains("printer_model") && P->cfg["printer_model"].is_string()) P->printerModel = P->cfg["printer_model"];
    if (P->cfg.contains("printable_area") && P->cfg["printable_area"].is_array()) {
        double x0 = 1e9, x1 = -1e9, y0 = 1e9, y1 = -1e9;
        for (auto& s : P->cfg["printable_area"]) {
            std::string t = s.get<std::string>();
            auto xp = t.find('x');
            double x = std::atof(t.substr(0, xp).c_str()), y = std::atof(t.substr(xp + 1).c_str());
            x0 = std::min(x0, x); x1 = std::max(x1, x); y0 = std::min(y0, y); y1 = std::max(y1, y);
        }
        if (x1 > x0 && y1 > y0) { P->bedX0 = x0; P->bedY0 = y0; P->bedW = x1 - x0; P->bedD = y1 - y0; P->hasBed = true; }
    }

    // meshes
    std::map<std::string, RawMesh> meshes;
    for (auto& n : z.names())
        if (n.rfind("3D/Objects/", 0) == 0 && n.size() > 6 && n.substr(n.size() - 6) == ".model") parseMeshes(z.read(n), "/" + n, meshes);
    parseMeshes(mainText, "/" + mainPath, meshes);

    // object definitions in main model
    struct Comp { std::string key; Mat m; };
    std::map<std::string, std::vector<Comp>> defs;
    const char* b = mainText.data();
    const char* e = b + mainText.size();
    eachBlock(b, e, "object", [&](const char* ob, const char* oe, const char* bb, const char* be) {
        std::string id = attr(ob, oe, "id");
        std::vector<Comp> comps;
        eachTag(bb, be, "component", [&](const char* tb, const char* te) {
            std::string path = attr(tb, te, "p:path");
            if (path.empty()) path = "/" + mainPath;
            comps.push_back({path + "#" + attr(tb, te, "objectid"), Mat::parse(attr(tb, te, "transform"))});
        });
        if (comps.empty() && meshes.count("/" + mainPath + "#" + id)) comps.push_back({"/" + mainPath + "#" + id, Mat()});
        defs[id] = comps;
    });
    struct Item { std::string id; Mat m; };
    std::vector<Item> items;
    eachTag(b, e, "item", [&](const char* tb, const char* te) { items.push_back({attr(tb, te, "objectid"), Mat::parse(attr(tb, te, "transform"))}); });

    // model_settings: names, extruders, per-object overrides, plates
    struct PartInfo { std::string subtype; int extruder; };
    struct ObjInfo { std::string name; int extruder = 1; std::vector<PartInfo> parts; std::map<std::string, std::string> own; };
    std::map<std::string, ObjInfo> infos;
    struct PlateDef { int id; std::string name, thumb; std::vector<std::string> ids; };
    std::vector<PlateDef> plateDefs;
    if (z.has("Metadata/model_settings.config")) {
        std::string ms = z.read("Metadata/model_settings.config");
        const char* mb = ms.data();
        const char* me = mb + ms.size();
        auto metaOf = [](const char* bb, const char* be, bool topOnly) {
            std::map<std::string, std::string> kv;
            // only metadata not inside <part>/<model_instance> when topOnly
            const char* p = bb;
            while (p < be) {
                const char* lt = (const char*)std::memchr(p, '<', be - p);
                if (!lt) break;
                if (topOnly && (std::strncmp(lt, "<part", 5) == 0 || std::strncmp(lt, "<model_instance", 15) == 0 || std::strncmp(lt, "<mesh_stat", 10) == 0)) {
                    const char* close = std::strncmp(lt, "<part", 5) == 0 ? "</part>" : (std::strncmp(lt, "<model_instance", 15) == 0 ? "</model_instance>" : nullptr);
                    if (close) {
                        const char* c = std::strstr(lt, close);
                        if (c && c < be) { p = c + std::strlen(close); continue; }
                    }
                }
                if (std::strncmp(lt, "<metadata", 9) == 0) {
                    const char* gt = (const char*)std::memchr(lt, '>', be - lt);
                    if (!gt) break;
                    std::string k = attr(lt, gt, "key");
                    if (!k.empty()) kv[k] = unescape(attr(lt, gt, "value"));
                    p = gt + 1;
                } else {
                    p = lt + 1;
                }
            }
            return kv;
        };
        eachBlock(mb, me, "object", [&](const char* ob, const char* oe, const char* bb, const char* be) {
            ObjInfo oi;
            auto kv = metaOf(bb, be, true);
            oi.name = kv["name"];
            oi.extruder = kv.count("extruder") ? std::atoi(kv["extruder"].c_str()) : 1;
            for (auto& p : kv)
                if (p.first != "name" && p.first != "extruder") oi.own[p.first] = p.second;
            eachBlock(bb, be, "part", [&](const char* pb, const char* pe, const char* pbb, const char* pbe) {
                PartInfo pi;
                pi.subtype = attr(pb, pe, "subtype");
                if (pi.subtype.empty()) pi.subtype = "normal_part";
                auto pkv = metaOf(pbb, pbe, false);
                pi.extruder = pkv.count("extruder") ? std::atoi(pkv["extruder"].c_str()) : oi.extruder;
                oi.parts.push_back(pi);
            });
            infos[attr(ob, oe, "id")] = oi;
        });
        eachBlock(mb, me, "plate", [&](const char*, const char*, const char* bb, const char* be) {
            PlateDef pd;
            auto kv = metaOf(bb, be, true);
            pd.id = kv.count("plater_id") ? std::atoi(kv["plater_id"].c_str()) : (int)plateDefs.size() + 1;
            pd.name = kv["plater_name"];
            pd.thumb = kv["thumbnail_file"];
            eachBlock(bb, be, "model_instance", [&](const char*, const char*, const char* ib, const char* ie) {
                auto ikv = metaOf(ib, ie, false);
                pd.ids.push_back(ikv["object_id"]);
            });
            plateDefs.push_back(pd);
        });
    }
    std::sort(plateDefs.begin(), plateDefs.end(), [](const PlateDef& a, const PlateDef& b) { return a.id < b.id; });
    if (plateDefs.empty()) {
        PlateDef pd{1, "Plate 1", z.has("Metadata/plate_1.png") ? "Metadata/plate_1.png" : "", {}};
        for (auto& it : items) pd.ids.push_back(it.id);
        plateDefs.push_back(pd);
    }
    int cols = (int)std::ceil(std::sqrt((double)plateDefs.size()));
    double sx = P->bedW * 1.2, sy = P->bedD * 1.2;
    for (size_t i = 0; i < plateDefs.size(); ++i) {
        Plate pl;
        pl.id = plateDefs[i].id;
        pl.name = plateDefs[i].name.empty() ? "Plate " + std::to_string(pl.id) : plateDefs[i].name;
        pl.thumb = z.has(plateDefs[i].thumb) ? plateDefs[i].thumb : "";
        pl.ox = pl.ox0 = (i % cols) * sx;
        pl.oy = pl.oy0 = -(double)(i / cols) * sy;
        P->plates.push_back(pl);
    }

    int nfil = (int)P->colors.size();
    for (auto& it : items) {
        auto d = defs.find(it.id);
        if (d == defs.end()) continue;
        Object obj;
        obj.id = it.id;
        obj.item = obj.item0 = it.m;
        ObjInfo oi;
        if (infos.count(it.id)) oi = infos[it.id];
        obj.name = oi.name.empty() ? "Object " + it.id : oi.name;
        obj.overrides = oi.own;
        std::map<int, Volume> vols;
        const auto& comps = d->second;
        for (size_t ci = 0; ci < comps.size(); ++ci) {
            const PartInfo* part = oi.parts.size() == comps.size() ? &oi.parts[ci] : nullptr;
            if (part && part->subtype != "normal_part") continue;
            auto mi = meshes.find(comps[ci].key);
            if (mi == meshes.end()) continue;
            const RawMesh& rm = mi->second;
            int ext = part ? part->extruder : oi.extruder;
            // Painted components: use the dominant painted filament for the whole part.
            if (rm.painted) {
                std::map<int, int> count;
                for (auto s : rm.paint) count[s > 0 ? s : ext]++;
                int best = ext, bc = -1;
                for (auto& c : count) if (c.second > bc) { bc = c.second; best = c.first; }
                ext = best;
            }
            if (ext < 1 || ext > nfil) ext = std::min(std::max(1, ext), nfil);
            Volume& v = vols[ext];
            v.filament = ext;
            uint32_t base = (uint32_t)(v.verts.size() / 3);
            const Mat& cm = comps[ci].m;
            for (size_t k = 0; k + 2 < rm.verts.size(); k += 3) {
                double x, y, zz;
                cm.apply(rm.verts[k], rm.verts[k + 1], rm.verts[k + 2], x, y, zz);
                v.verts.push_back((float)x); v.verts.push_back((float)y); v.verts.push_back((float)zz);
            }
            for (auto t : rm.tris) v.tris.push_back(base + t);
        }
        if (vols.empty()) continue;
        for (auto& kv : vols) obj.volumes.push_back(std::move(kv.second));
        // plate assignment
        int plate = -1;
        for (size_t pi = 0; pi < plateDefs.size() && plate < 0; ++pi)
            if (std::find(plateDefs[pi].ids.begin(), plateDefs[pi].ids.end(), it.id) != plateDefs[pi].ids.end()) plate = (int)pi;
        if (plate < 0) {
            double mn[3], mx[3];
            P->objectBounds(obj, obj.item, mn, mx);
            double cx = (mn[0] + mx[0]) / 2, cy = (mn[1] + mx[1]) / 2;
            for (size_t pi = 0; pi < P->plates.size() && plate < 0; ++pi) {
                const Plate& pl = P->plates[pi];
                if (cx >= pl.ox && cx <= pl.ox + sx && cy >= pl.oy && cy <= pl.oy + sy) plate = (int)pi;
            }
            if (plate < 0) plate = 0;
        }
        obj.plate = plate;
        P->plates[plate].objects.push_back((int)P->objects.size());
        P->objects.push_back(std::move(obj));
    }
    if (P->objects.empty()) throw std::runtime_error("No printable objects found in this 3MF.");
    return P;
}

void Project::objectBounds(const Object& o, const Mat& m, double mn[3], double mx[3]) const {
    for (int i = 0; i < 3; ++i) { mn[i] = 1e18; mx[i] = -1e18; }
    for (auto& v : o.volumes)
        for (size_t k = 0; k + 2 < v.verts.size(); k += 3) {
            double p[3];
            m.apply(v.verts[k], v.verts[k + 1], v.verts[k + 2], p[0], p[1], p[2]);
            for (int i = 0; i < 3; ++i) { mn[i] = std::min(mn[i], p[i]); mx[i] = std::max(mx[i], p[i]); }
        }
}

void Project::plateTriangles(int plate, std::vector<float>& xyz, std::vector<uint8_t>& fil) const {
    const Plate& pl = plates.at(plate);
    for (int oi : pl.objects) {
        const Object& o = objects[oi];
        for (auto& v : o.volumes) {
            for (auto t : v.tris) {
                double x, y, z;
                o.item.apply(v.verts[t * 3], v.verts[t * 3 + 1], v.verts[t * 3 + 2], x, y, z);
                xyz.push_back((float)(x - pl.ox));
                xyz.push_back((float)(y - pl.oy));
                xyz.push_back((float)z);
            }
            for (size_t k = 0; k < v.tris.size() / 3; ++k) fil.push_back((uint8_t)v.filament);
        }
    }
}

}  // namespace a1
