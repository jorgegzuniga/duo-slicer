#include "config.hpp"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdio>
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
    if (s.empty() || s == "nil") return def;
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

static const char* bedKeyFor(const std::string& bed) {
    if (bed == "Cool Plate") return "cool_plate_temp";
    if (bed == "Engineering Plate") return "eng_plate_temp";
    if (bed == "High Temp Plate") return "hot_plate_temp";
    if (bed == "Supertack Plate") return "supertack_plate_temp";
    if (bed == "Textured Cool Plate") return "textured_cool_plate_temp";
    return "textured_plate_temp";
}

double Config::bedTemp(int f, bool firstLayer) const {
    std::string k = bedKeyFor(str("curr_bed_type", 0, "Textured PEI Plate"));
    if (firstLayer) k += "_initial_layer";
    return num(k, f, 0);
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
    S.wFirst = width("initial_layer_line_width", nozzle * 1.25);
    S.wOuter = width("outer_wall_line_width", nozzle * 1.05);
    S.wInner = width("inner_wall_line_width", nozzle * 1.125);
    S.wSparse = width("sparse_infill_line_width", nozzle * 1.125);
    S.wSolid = width("internal_solid_infill_line_width", nozzle * 1.05);
    S.wTop = width("top_surface_line_width", nozzle * 1.05);
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
    S.bedMinX = bedMinX; S.bedMinY = bedMinY; S.bedMaxX = bedMaxX; S.bedMaxY = bedMaxY;
    S.exMinX = exMinX; S.exMinY = exMinY; S.exMaxX = exMaxX; S.exMaxY = exMaxY;
    return S;
}

static const std::vector<std::pair<std::string, std::string>>& bedTypeKeys() {
    static const std::vector<std::pair<std::string, std::string>> k = {
        {"Textured PEI Plate", "textured_plate_temp"}, {"Cool Plate", "cool_plate_temp"},     {"Engineering Plate", "eng_plate_temp"},
        {"High Temp Plate", "hot_plate_temp"},        {"Supertack Plate", "supertack_plate_temp"}, {"Textured Cool Plate", "textured_cool_plate_temp"}};
    return k;
}

std::vector<std::string> supportedBedTypes(const json& bundle) {
    std::vector<std::string> out;
    std::string pla = mapFilamentPreset(bundle, "", "PLA");
    if (!bundle.contains("filaments") || !bundle["filaments"].contains(pla)) return out;
    const json& f = bundle["filaments"][pla];
    for (auto& [name, key] : bedTypeKeys()) {
        if (!f.contains(key) || !f[key].is_array() || f[key].empty()) continue;
        double t = std::atof(scalarStr(f[key][0]).c_str());
        if (t > 0) out.push_back(name);
    }
    return out;
}

static std::string upper(std::string s) {
    for (auto& c : s) c = (char)std::toupper((unsigned char)c);
    return s;
}

std::string mapFilamentPreset(const json& bundle, const std::string& id, const std::string& type) {
    const json& fil = bundle["filaments"];
    if (fil.empty()) return "";
    if (fil.contains(id)) return id;
    std::string b = id;
    auto cut = [&](const std::string& pat) { size_t p = b.find(pat); if (p != std::string::npos) b = b.substr(0, p); };
    cut(" - Copia"); cut(" ("); cut(" @");
    while (!b.empty() && b.back() == ' ') b.pop_back();
    auto bestPrefix = [&](const std::string& prefix) -> std::string {
        std::string best;
        for (auto& kv : fil.items()) {
            const std::string& n = kv.key();
            if (n.compare(0, prefix.size(), prefix) == 0 && (best.empty() || n.size() < best.size())) best = n;
        }
        return best;
    };
    if (!b.empty()) {
        std::string m = bestPrefix(b + " @");
        if (!m.empty()) return m;
    }
    std::string t = upper(type.empty() ? "PLA" : type);
    std::string vendor = bundle.value("vendor", std::string(""));
    std::vector<std::string> tries;
    if (vendor == "Snapmaker") tries = {"Snapmaker " + t + " @", "Generic " + t + " @"};
    else tries = {"Generic " + t + " @", "Bambu " + t + " Basic @", "Bambu " + t + " @"};
    for (auto& p : tries) {
        std::string m = bestPrefix(p);
        if (!m.empty()) return m;
    }
    // any preset of the same material
    std::string best;
    for (auto& kv : fil.items()) {
        const json& f = kv.value();
        if (f.contains("filament_type") && f["filament_type"].is_array() && !f["filament_type"].empty() &&
            upper(f["filament_type"][0].get<std::string>()) == t && (best.empty() || kv.key().size() < best.size()))
            best = kv.key();
    }
    if (!best.empty()) return best;
    std::string pla = bestPrefix("Generic PLA @");
    return pla.empty() ? fil.begin().key() : pla;
}

Config buildConfig(const json& bundle, const json& proj, const std::vector<FilamentInput>& fins, const json& opt,
                   std::vector<std::string>& warnings) {
    Config c;
    c.nfil = std::max<int>(1, (int)fins.size());
    c.kind = bundle.value("kind", std::string("bambu"));
    c.printerName = bundle.value("name", std::string("printer"));
    c.machineName = bundle.value("machine_name", std::string(""));
    c.modelId = bundle.value("model_id", std::string(""));
    c.tools = bundle.value("tools", 1);
    if (bundle.contains("bed")) {
        const json& b = bundle["bed"];
        c.bedMinX = b["min"][0]; c.bedMinY = b["min"][1];
        c.bedMaxX = b["max"][0]; c.bedMaxY = b["max"][1];
        c.bedHeight = b.value("height", 250.0);
        if (b.contains("exclude") && b["exclude"].is_array() && b["exclude"].size() == 2) {
            c.exMinX = b["exclude"][0][0]; c.exMinY = b["exclude"][0][1];
            c.exMaxX = b["exclude"][1][0]; c.exMaxY = b["exclude"][1][1];
        }
    }
    static const std::set<std::string> skip = {"compatible_printers", "compatible_printers_condition", "compatible_prints",
                                               "compatible_prints_condition", "filament_id", "__filament_id", "include", "inherits"};
    for (auto& kv : bundle["machine"].items())
        if (!skip.count(kv.key())) c.j[kv.key()] = kv.value();
    if (c.has("printer_extruder_variant") && c.j["printer_extruder_variant"].is_array())
        c.variantsPerExtruder = std::max(1, (int)c.j["printer_extruder_variant"].size() / std::max(1, c.tools));
    std::string proc = opt.value("process", bundle.value("default_process", std::string("")));
    if (!bundle["processes"].contains(proc)) {
        std::string def = bundle.value("default_process", std::string(""));
        if (!proc.empty()) warnings.push_back("Quality preset \"" + proc + "\" isn't available for the " + c.printerName + "; using " + def + ".");
        proc = def;
    }
    if (bundle["processes"].contains(proc))
        for (auto& kv : bundle["processes"][proc].items())
            if (!skip.count(kv.key())) c.j[kv.key()] = kv.value();
    c.j["print_settings_id"] = proc;
    c.j["printer_settings_id"] = c.machineName;
    // designer's process tweaks from the project (scalar values only)
    if (proj.is_object() && proj.contains("different_settings_to_system") && proj["different_settings_to_system"].is_array() &&
        !proj["different_settings_to_system"].empty() && proj["different_settings_to_system"][0].is_string()) {
        std::string d = proj["different_settings_to_system"][0].get<std::string>();
        size_t p = 0;
        while (p <= d.size()) {
            size_t e = d.find(';', p);
            if (e == std::string::npos) e = d.size();
            std::string k = d.substr(p, e - p);
            if (!k.empty() && proj.contains(k) && c.j.contains(k) && (!proj[k].is_array() || proj[k].size() == 1) && !c.j[k].is_array())
                c.j[k] = proj[k];
            p = e + 1;
        }
    }
    // filaments
    std::vector<std::string> presets;
    for (auto& f : fins) {
        std::string name = (!f.preset.empty() && bundle["filaments"].contains(f.preset)) ? f.preset : mapFilamentPreset(bundle, f.settingId, f.type);
        presets.push_back(name);
    }
    std::set<std::string> fkeys;
    for (auto& name : presets)
        if (bundle["filaments"].contains(name))
            for (auto& kv : bundle["filaments"][name].items())
                if (kv.value().is_array() && !skip.count(kv.key())) fkeys.insert(kv.key());
    for (auto& k : fkeys) {
        json arr = json::array();
        for (auto& name : presets) {
            const json* v = nullptr;
            if (bundle["filaments"].contains(name) && bundle["filaments"][name].contains(k)) v = &bundle["filaments"][name][k];
            if (!v)
                for (auto& n2 : presets)
                    if (bundle["filaments"].contains(n2) && bundle["filaments"][n2].contains(k)) { v = &bundle["filaments"][n2][k]; break; }
            if (v && v->is_array() && !v->empty()) arr.push_back((*v)[0]);
            else arr.push_back("0");
        }
        c.j[k] = arr;
    }
    c.filamentPresets = presets;
    for (auto& name : presets)
        c.filamentIds.push_back(bundle["filaments"].contains(name) ? bundle["filaments"][name].value("__filament_id", std::string("")) : "");
    c.j["filament_ids"] = c.filamentIds;
    json col = json::array(), typ = json::array();
    for (size_t i = 0; i < fins.size(); ++i) {
        col.push_back(fins[i].color.empty() ? "#888888" : fins[i].color);
        const json& F = bundle["filaments"].contains(presets[i]) ? bundle["filaments"][presets[i]] : json::object();
        typ.push_back(F.contains("filament_type") && F["filament_type"].is_array() && !F["filament_type"].empty() ? F["filament_type"][0] : json("PLA"));
    }
    c.j["filament_colour"] = col;
    c.j["filament_type"] = typ;
    c.j["filament_settings_id"] = presets;
    // flush volumes (Bambu): project matrix when it matches, else Bambu's default
    if (proj.is_object() && proj.contains("flush_volumes_matrix") && proj["flush_volumes_matrix"].is_array() &&
        (int)proj["flush_volumes_matrix"].size() == c.nfil * c.nfil) {
        c.j["flush_volumes_matrix"] = proj["flush_volumes_matrix"];
    } else {
        json fm = json::array();
        for (int a = 0; a < c.nfil; ++a) for (int b = 0; b < c.nfil; ++b) fm.push_back(a == b ? "0" : "280");
        c.j["flush_volumes_matrix"] = fm;
    }
    c.j["flush_multiplier"] = (proj.is_object() && proj.contains("flush_multiplier")) ? proj["flush_multiplier"] : json::array({"1"});
    std::string defBed = c.kind == "klipper_toolchanger" ? "High Temp Plate" : "Textured PEI Plate";
    std::string bed = (proj.is_object() && proj.contains("curr_bed_type") && proj["curr_bed_type"].is_string()) ? proj["curr_bed_type"].get<std::string>() : defBed;
    if (c.kind == "klipper_toolchanger") bed = defBed;  // U1 filament presets only define smooth-PEI temperatures
    c.j["curr_bed_type"] = bed;
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
    // a plate type this printer's filament presets have no temperatures for -> the printer's own plate
    {
        bool any = false;
        for (int i = 0; i < c.nfil && !any; ++i) any = c.bedTemp(i, false) > 0;
        if (!any) {
            auto types = supportedBedTypes(bundle);
            if (!types.empty()) {
                std::string was = c.str("curr_bed_type", 0, "");
                c.j["curr_bed_type"] = types.front();
                if (c.kind != "klipper_toolchanger") warnings.push_back("The " + c.printerName + " has no temperatures for the " + was + "; using the " + types.front() + ".");
            }
        }
    }
    if (c.kind == "bambu") {
        if (!c.has("timelapse_type")) c.j["timelapse_type"] = "0";  // traditional (the print command decides whether to record)
        // long retraction before the cutter: per filament; filament presets override the printer only at level 2 ("EnableFilament")
        int level = (int)c.num("enable_long_retraction_when_cut", 0, 0);
        for (auto& kv : std::vector<std::pair<std::string, std::string>>{{"long_retractions_when_cut", "filament_long_retractions_when_cut"},
                                                                        {"retraction_distances_when_cut", "filament_retraction_distances_when_cut"}}) {
            if (!c.has(kv.first)) continue;
            std::string base = c.str(kv.first, 0, "0");
            json arr = json::array();
            for (int i = 0; i < c.nfil; ++i) {
                std::string v = base;
                if (level == 2) {
                    std::string o = c.str(kv.second, i, "nil");
                    if (o != "nil" && !o.empty()) v = o;
                }
                arr.push_back(v);
            }
            c.j[kv.first] = arr;
        }
    }
    // Orca / PrusaSlicer legacy names used by some printers' templates
    if (c.has("nozzle_temperature_initial_layer")) c.j["first_layer_temperature"] = c.j["nozzle_temperature_initial_layer"];
    if (c.has("nozzle_temperature")) c.j["temperature"] = c.j["nozzle_temperature"];
    json bed0 = json::array(), bedN = json::array(), fmap = json::array(), nvt = json::array();
    for (int i = 0; i < c.nfil; ++i) {
        bed0.push_back(c.bedTemp(i, true));
        bedN.push_back(c.bedTemp(i, false));
        fmap.push_back(std::to_string(c.kind == "klipper_toolchanger" ? i + 1 : 1));
    }
    for (int t = 0; t < std::max(1, c.tools); ++t) nvt.push_back("0");
    c.j["first_layer_bed_temperature"] = bed0;
    c.j["bed_temperature"] = bedN;
    c.j["bed_temperature_initial_layer"] = bed0;
    if (!c.has("filament_map")) c.j["filament_map"] = fmap;
    if (!c.has("nozzle_volume_type")) c.j["nozzle_volume_type"] = nvt;
    c.j["max_print_height"] = c.bedHeight;
    if (!c.has("z_offset")) c.j["z_offset"] = 0;
    double minVit = 1e9;
    for (int i = 0; i < c.nfil; ++i) minVit = std::min(minVit, c.num("temperature_vitrification", i, 1e9));
    c.j["min_vitrification_temperature"] = minVit >= 1e9 ? 100.0 : minVit;
    return c;
}

}  // namespace a1
