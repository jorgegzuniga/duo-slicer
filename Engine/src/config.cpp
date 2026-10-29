#include "config.hpp"

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cmath>
#include <cstdlib>
#include <set>

namespace a1 {
using json = nlohmann::json;

static std::string scalarStr(const json& v) {
    if (v.is_string()) return v.get<std::string>();
    if (v.is_number_integer()) return std::to_string(v.get<long long>());
    if (v.is_number()) {
        char b[64];
        std::snprintf(b, sizeof b, "%g", v.get<double>());
        return b;
    }
    if (v.is_boolean()) return v.get<bool>() ? "1" : "0";
    return v.dump();
}

std::string Config::str(const std::string& k, int idx, const std::string& def) const {
    if (!has(k)) return def;
    const json& v = j[k];
    if (v.is_array()) {
        if (v.empty()) return def;
        return scalarStr(v[std::max(0, std::min(idx, (int)v.size() - 1))]);
    }
    return scalarStr(v);
}

double Config::num(const std::string& k, int idx, double def) const {
    std::string s = str(k, idx, "");
    if (s.empty()) return def;
    char* end = nullptr;
    double d = std::strtod(s.c_str(), &end);
    if (end == s.c_str()) return def;
    return d;
}

double Config::numPct(const std::string& k, double base, int idx, double def) const {
    std::string s = str(k, idx, "");
    if (s.empty()) return def;
    double d = std::atof(s.c_str());
    if (s.find('%') != std::string::npos) return base * d / 100.0;
    return d;
}

SliceSettings Config::sliceSettings() const { return sliceSettingsFor({}); }

SliceSettings Config::sliceSettingsFor(const std::map<std::string, std::string>& ov) const {
    auto get = [&](const std::string& k, double def) {
        auto it = ov.find(k);
        if (it != ov.end()) return std::atof(it->second.c_str());
        return num(k, 0, def);
    };
    auto gets = [&](const std::string& k, const std::string& def) {
        auto it = ov.find(k);
        if (it != ov.end()) return it->second;
        return str(k, 0, def);
    };
    double nozzle = num("nozzle_diameter", 0, 0.4);
    auto width = [&](const std::string& k, double def) {
        std::string s = gets(k, "");
        double w = s.empty() ? 0 : std::atof(s.c_str());
        if (s.find('%') != std::string::npos) w = nozzle * w / 100.0;
        return w > 0.05 ? w : def;
    };
    SliceSettings S;
    S.layerH = get("layer_height", 0.2);
    S.firstH = get("initial_layer_print_height", S.layerH);
    S.walls = (int)get("wall_loops", 2);
    S.topLayers = (int)get("top_shell_layers", 5);
    S.bottomLayers = (int)get("bottom_shell_layers", 3);
    S.topThickness = get("top_shell_thickness", 0);
    S.bottomThickness = get("bottom_shell_thickness", 0);
    S.density = std::max(0.0, std::min(1.0, std::atof(gets("sparse_infill_density", "15%").c_str()) / 100.0));
    S.pattern = gets("sparse_infill_pattern", "grid");
    S.wFirst = width("initial_layer_line_width", 0.5);
    S.wOuter = width("outer_wall_line_width", 0.42);
    S.wInner = width("inner_wall_line_width", 0.45);
    S.wSparse = width("sparse_infill_line_width", 0.45);
    S.wSolid = width("internal_solid_infill_line_width", 0.42);
    S.wTop = width("top_surface_line_width", 0.42);
    std::string ovl = gets("infill_wall_overlap", "15%");
    S.infillOverlap = std::atof(ovl.c_str()) / (ovl.find('%') != std::string::npos ? 100.0 : 1.0);
    S.brimType = gets("brim_type", "auto_brim");
    S.brimWidth = get("brim_width", 5);
    S.brimGap = get("brim_object_gap", 0.1);
    S.skirtLoops = (int)get("skirt_loops", 0);
    S.skirtDistance = get("skirt_distance", 2);
    S.wallSequence = gets("wall_sequence", "inner wall/outer wall");
    S.sparseAngle = get("infill_direction", 45);
    S.solidAngle = get("solid_infill_direction", 45);
    S.topAngle = S.solidAngle;
    return S;
}

std::string mapFilamentPreset(const json& bundle, const std::string& id, const std::string& type) {
    const json& fil = bundle["filaments"];
    std::string b = id;
    auto cut = [&](const std::string& pat) { size_t p = b.find(pat); if (p != std::string::npos) b = b.substr(0, p); };
    cut(" - Copia"); cut(" ("); cut(" @");
    while (!b.empty() && b.back() == ' ') b.pop_back();
    if (!b.empty() && fil.contains(b + " @BBL A1")) return b + " @BBL A1";
    std::string t = type.empty() ? "PLA" : type;
    for (auto& c : t) c = (char)std::toupper((unsigned char)c);
    if (fil.contains("Generic " + t + " @BBL A1")) return "Generic " + t + " @BBL A1";
    if (fil.contains("Bambu " + t + " Basic @BBL A1")) return "Bambu " + t + " Basic @BBL A1";
    if (fil.contains("Generic PLA @BBL A1")) return "Generic PLA @BBL A1";
    return fil.begin().key();
}

Config buildConfig(const json& bundle, const json& proj, int nfil, const std::vector<std::string>& colors,
                   const std::vector<std::string>& types, const std::vector<std::string>& settingIds, const json& opt,
                   std::vector<std::string>& warnings) {
    Config c;
    c.nfil = std::max(1, nfil);
    static const std::set<std::string> skip = {"compatible_printers", "compatible_printers_condition", "compatible_prints",
                                               "compatible_prints_condition", "filament_id", "__filament_id", "include", "inherits"};
    for (auto& kv : bundle["machine"].items())
        if (!skip.count(kv.key())) c.j[kv.key()] = kv.value();
    std::string proc = opt.value("process", bundle.value("default_process", std::string("0.20mm Standard @BBL A1")));
    if (!bundle["processes"].contains(proc)) {
        warnings.push_back("Unknown quality preset \"" + proc + "\"; using 0.20mm Standard.");
        proc = bundle.value("default_process", std::string("0.20mm Standard @BBL A1"));
    }
    for (auto& kv : bundle["processes"][proc].items())
        if (!skip.count(kv.key())) c.j[kv.key()] = kv.value();
    c.j["print_settings_id"] = proc;
    c.j["printer_settings_id"] = bundle.value("machine_name", std::string("Bambu Lab A1 0.4 nozzle"));
    // designer's process tweaks from the project
    if (proj.is_object() && proj.contains("different_settings_to_system") && proj["different_settings_to_system"].is_array() &&
        !proj["different_settings_to_system"].empty()) {
        std::string d = proj["different_settings_to_system"][0].is_string() ? proj["different_settings_to_system"][0].get<std::string>() : "";
        size_t p = 0;
        while (p <= d.size()) {
            size_t e = d.find(';', p);
            if (e == std::string::npos) e = d.size();
            std::string k = d.substr(p, e - p);
            if (!k.empty() && proj.contains(k) && c.j.contains(k)) {
                // keep scalar process values only
                if (!proj[k].is_array() || proj[k].size() == 1) c.j[k] = proj[k];
            }
            p = e + 1;
        }
    }
    // filaments
    std::vector<std::string> presets;
    for (int i = 0; i < c.nfil; ++i) {
        std::string name;
        if (opt.contains("filaments") && opt["filaments"].is_array() && i < (int)opt["filaments"].size() && opt["filaments"][i].is_string() &&
            bundle["filaments"].contains(opt["filaments"][i].get<std::string>()))
            name = opt["filaments"][i].get<std::string>();
        else
            name = mapFilamentPreset(bundle, i < (int)settingIds.size() ? settingIds[i] : "", i < (int)types.size() ? types[i] : "PLA");
        presets.push_back(name);
    }
    std::set<std::string> fkeys;
    for (auto& name : presets)
        for (auto& kv : bundle["filaments"][name].items())
            if (kv.value().is_array() && !skip.count(kv.key())) fkeys.insert(kv.key());
    for (auto& k : fkeys) {
        json arr = json::array();
        for (auto& name : presets) {
            const json& F = bundle["filaments"][name];
            const json* v = F.contains(k) ? &F[k] : nullptr;
            if (!v) for (auto& n2 : presets) if (bundle["filaments"][n2].contains(k)) { v = &bundle["filaments"][n2][k]; break; }
            if (v && v->is_array() && !v->empty()) arr.push_back((*v)[0]);
            else arr.push_back("0");
        }
        c.j[k] = arr;
    }
    c.filamentPresets = presets;
    for (auto& name : presets) c.filamentIds.push_back(bundle["filaments"][name].value("__filament_id", std::string("")));
    json col = json::array();
    for (int i = 0; i < c.nfil; ++i) {
        std::string cc = i < (int)colors.size() ? colors[i] : "#888888";
        if (opt.contains("colors") && opt["colors"].is_array() && i < (int)opt["colors"].size() && opt["colors"][i].is_string()) cc = opt["colors"][i];
        col.push_back(cc);
    }
    c.j["filament_colour"] = col;
    json typ = json::array();
    for (auto& name : presets) typ.push_back(bundle["filaments"][name].contains("filament_type") ? bundle["filaments"][name]["filament_type"][0] : json("PLA"));
    c.j["filament_type"] = typ;
    c.j["filament_settings_id"] = presets;
    // flush matrix from project, else Bambu's default 280 mm3 everywhere except same filament
    if (proj.is_object() && proj.contains("flush_volumes_matrix") && proj["flush_volumes_matrix"].is_array() &&
        (int)proj["flush_volumes_matrix"].size() >= c.nfil * c.nfil) {
        c.j["flush_volumes_matrix"] = proj["flush_volumes_matrix"];
    } else {
        json fm = json::array();
        for (int a = 0; a < c.nfil; ++a) for (int b = 0; b < c.nfil; ++b) fm.push_back(a == b ? "0" : "280");
        c.j["flush_volumes_matrix"] = fm;
    }
    c.j["flush_multiplier"] = (proj.is_object() && proj.contains("flush_multiplier")) ? proj["flush_multiplier"] : json::array({"1"});
    std::string bed = (proj.is_object() && proj.contains("curr_bed_type") && proj["curr_bed_type"].is_string()) ? proj["curr_bed_type"].get<std::string>() : "Textured PEI Plate";
    c.j["curr_bed_type"] = bed;
    // project-level layout keys the slicer understands
    for (const char* k : {"brim_type", "brim_width", "skirt_loops", "skirt_distance"})
        if (proj.is_object() && proj.contains(k) && !c.j.contains(k)) c.j[k] = proj[k];
    // user overrides
    if (opt.contains("overrides") && opt["overrides"].is_object()) {
        for (auto& kv : opt["overrides"].items()) {
            std::string v = scalarStr(kv.value());
            if (c.j.contains(kv.key()) && c.j[kv.key()].is_array()) {
                json arr = json::array();
                for (size_t i = 0; i < c.j[kv.key()].size(); ++i) arr.push_back(v);
                c.j[kv.key()] = arr;
            } else {
                c.j[kv.key()] = v;
            }
        }
    }
    return c;
}

}  // namespace a1
