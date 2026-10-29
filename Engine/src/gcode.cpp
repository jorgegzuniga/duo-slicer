#include "gcode.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <set>
#include <sstream>

#include "templ.hpp"

namespace a1 {
using json = nlohmann::json;
using namespace Clipper2Lib;

namespace {

const char* bedKey(const std::string& bed) {
    if (bed == "Cool Plate") return "cool_plate_temp";
    if (bed == "Engineering Plate") return "eng_plate_temp";
    if (bed == "High Temp Plate") return "hot_plate_temp";
    if (bed == "Supertack Plate") return "supertack_plate_temp";
    return "textured_plate_temp";
}

double mm3PerMm(double w, double h) { return (w - h) * h + M_PI * h * h / 4.0; }

struct Writer {
    const Config& C;
    std::string out;
    GcodeOutput res;
    int nfil;
    double x = 0, y = 0, z = 0;
    bool posKnown = false, zKnown = false, lifted = false;
    double retracted = 0;
    int tool = -1;
    int accel = -1;
    int fan = -1;
    double time = 0;
    double layerZ = 0, layerH = 0.2;
    int layerIdx = 0;
    double maxLayerZ = 0;
    double filArea = M_PI / 4 * 1.75 * 1.75;
    double speedFactor = 1;
    Role lastRole = Role::Skirt;
    bool haveRole = false;
    double firstMinX = 0, firstMinY = 0, firstMaxX = 0, firstMaxY = 0;
    int totalLayers = 0;
    std::vector<double> markTimes;
    std::string templErr;

    explicit Writer(const Config& c) : C(c) {
        nfil = c.nfil;
        res.usedMm.assign(nfil, 0);
        res.usedG.assign(nfil, 0);
        res.flushG.assign(nfil, 0);
        filArea = M_PI / 4 * std::pow(C.num("filament_diameter", 0, 1.75), 2);
        out.reserve(1 << 22);
    }

    void line(const std::string& s) { out += s; out += '\n'; }
    static std::string f3(double v) { char b[32]; std::snprintf(b, sizeof b, "%.3f", v); std::string s = b; while (s.back() == '0') s.pop_back(); if (s.back() == '.') s.pop_back(); if (s == "-0") s = "0"; return s; }
    static std::string f5(double v) { char b[32]; std::snprintf(b, sizeof b, "%.5f", v); std::string s = b; while (s.back() == '0') s.pop_back(); if (s.back() == '.') s.pop_back(); if (s == "-0") s = "0"; return s; }

    double moveTime(double d, double v, double a) {
        if (v <= 0) return 0;
        if (a <= 0) return d / v;
        double dAcc = v * v / a;
        if (d >= dAcc) return d / v + v / a;
        return 2 * std::sqrt(d / a);
    }
    double accelFor(const std::string& key) {
        double def = C.num("default_acceleration", 0, 6000);
        std::string s = C.str(key, 0, "");
        if (s.empty()) return def;
        double v = std::atof(s.c_str());
        if (s.find('%') != std::string::npos) v = def * v / 100.0;
        return v > 0 ? v : def;
    }
    void setAccel(double a) {
        int ai = (int)std::lround(a);
        if (ai != accel) { line("M204 S" + std::to_string(ai)); accel = ai; }
    }
    void setFan(int s) {
        if (s != fan) { line("M106 S" + std::to_string(s)); fan = s; }
    }

    void retract() {
        if (tool < 0) return;
        double len = C.num("retraction_length", 0, 0.8);
        std::string fr = C.str("filament_retraction_length", tool, "nil");
        if (fr != "nil" && !fr.empty()) len = std::atof(fr.c_str());
        if (retracted >= len - 1e-6 || len <= 0) return;
        double d = len - retracted;
        double sp = C.num("retraction_speed", 0, 30);
        line("G1 E-" + f5(d) + " F" + std::to_string((int)(sp * 60)));
        time += d / sp;
        retracted = len;
    }
    void unretract() {
        if (retracted <= 0) return;
        double sp = C.num("deretraction_speed", 0, 30);
        if (sp <= 0) sp = C.num("retraction_speed", 0, 30);
        line("G1 E" + f5(retracted) + " F" + std::to_string((int)(sp * 60)));
        time += retracted / sp;
        retracted = 0;
    }
    void lift() {
        if (lifted || !zKnown) return;
        double hop = C.num("z_hop", 0, 0.4);
        if (hop <= 0) return;
        line("G1 Z" + f3(layerZ + hop) + " F" + std::to_string((int)(C.num("travel_speed_z", 0, 0) > 0 ? C.num("travel_speed_z", 0, 0) * 60 : 12000)));
        time += hop / 100.0;
        lifted = true;
    }
    void ensureZ() {
        if (!zKnown || lifted || std::fabs(z - layerZ) > 1e-6) {
            line("G1 Z" + f3(layerZ) + " F12000");
            time += 0.05;
            z = layerZ;
            zKnown = true;
            lifted = false;
        }
    }
    void travelTo(double nx, double ny) {
        double d = posKnown ? std::hypot(nx - x, ny - y) : 1e9;
        if (posKnown && d < 1e-4) { ensureZ(); return; }
        double minT = C.num("retraction_minimum_travel", 0, 1);
        if (d > minT) { retract(); lift(); }
        double v = C.num("travel_speed", 0, 700);
        if (!posKnown) {
            // coming back from a template: go up first so we never drag across the print
            if (!zKnown) { line("G1 Z" + f3(maxLayerZ + C.num("z_hop", 0, 0.4)) + " F12000"); }
        }
        setAccel(accelFor("travel_acceleration"));
        line("G1 X" + f3(nx) + " Y" + f3(ny) + " F" + std::to_string((int)(v * 60)));
        time += moveTime(posKnown ? d : 100, v, accelFor("travel_acceleration"));
        x = nx; y = ny; posKnown = true;
        ensureZ();
    }

    double roleSpeed(Role r, bool first) {
        if (first) {
            if (r == Role::Outer || r == Role::Inner || r == Role::Skirt || r == Role::Brim) return C.num("initial_layer_speed", 0, 50);
            return C.num("initial_layer_infill_speed", 0, 105);
        }
        switch (r) {
            case Role::Outer: return C.num("outer_wall_speed", 0, 200);
            case Role::Inner: return C.num("inner_wall_speed", 0, 300);
            case Role::Top: return C.num("top_surface_speed", 0, 200);
            case Role::Solid: case Role::Bottom: return C.num("internal_solid_infill_speed", 0, 250);
            case Role::Sparse: return C.num("sparse_infill_speed", 0, 270);
            default: return C.num("initial_layer_speed", 0, 50);
        }
    }
    double roleAccel(Role r, bool first) {
        if (first) return accelFor("initial_layer_acceleration");
        switch (r) {
            case Role::Outer: return accelFor("outer_wall_acceleration");
            case Role::Inner: return accelFor("inner_wall_acceleration");
            case Role::Top: return accelFor("top_surface_acceleration");
            case Role::Sparse: return accelFor("sparse_infill_acceleration");
            case Role::Solid: case Role::Bottom: return accelFor("internal_solid_infill_acceleration");
            default: return accelFor("default_acceleration");
        }
    }
    double effSpeed(Role r, double w, bool first) {
        double v = roleSpeed(r, first);
        double maxVol = C.num("filament_max_volumetric_speed", tool, 20);
        double cap = maxVol / mm3PerMm(w, layerH);
        v = std::min(v, cap);
        if (!first && speedFactor < 1) v = std::max(std::min(v, C.num("slow_down_min_speed", tool, 20)), v * speedFactor);
        return v;
    }

    void extrudePath(const ToolPath& tp, bool first) {
        const Path64& P = tp.pts;
        if (P.size() < 2) return;
        // pick start
        std::vector<Point64> pts(P.begin(), P.end());
        if (tp.closed) {
            size_t best = 0;
            double bd = 1e300;
            if (posKnown)
                for (size_t i = 0; i < pts.size(); ++i) {
                    double d = std::hypot(pts[i].x / kScale - x, pts[i].y / kScale - y);
                    if (d < bd) { bd = d; best = i; }
                }
            std::rotate(pts.begin(), pts.begin() + best, pts.end());
            pts.push_back(pts.front());
        } else if (posKnown) {
            double ds = std::hypot(pts.front().x / kScale - x, pts.front().y / kScale - y);
            double de = std::hypot(pts.back().x / kScale - x, pts.back().y / kScale - y);
            if (de < ds) std::reverse(pts.begin(), pts.end());
        }
        travelTo(pts[0].x / kScale, pts[0].y / kScale);
        unretract();
        if (!haveRole || lastRole != tp.role) {
            line(std::string("; FEATURE: ") + roleName(tp.role));
            line("; LINE_WIDTH: " + f3(tp.width));
            lastRole = tp.role;
            haveRole = true;
        }
        double a = roleAccel(tp.role, first);
        setAccel(a);
        double v = effSpeed(tp.role, tp.width, first);
        double flow = C.num("filament_flow_ratio", tool, 1.0);
        if (first) flow *= C.num("initial_layer_flow_ratio", 0, 1.0) > 0 ? C.num("initial_layer_flow_ratio", 0, 1.0) : 1.0;
        double ePerMm = mm3PerMm(tp.width, layerH) / filArea * flow;
        int F = (int)std::lround(v * 60);
        bool fset = false;
        for (size_t i = 1; i < pts.size(); ++i) {
            double nx = pts[i].x / kScale, ny = pts[i].y / kScale;
            double d = std::hypot(nx - x, ny - y);
            if (d < 1e-4) continue;
            double e = d * ePerMm;
            std::string l = "G1 X" + f3(nx) + " Y" + f3(ny) + " E" + f5(e);
            if (!fset) { l += " F" + std::to_string(F); fset = true; }
            line(l);
            res.usedMm[tool] += e;
            time += moveTime(d, v, a);
            x = nx; y = ny;
        }
    }

    json vars;  // dynamic template variables
    json lookup(const std::string& k) const {
        if (vars.contains(k)) return vars[k];
        if (C.j.contains(k)) return C.j[k];
        return json();
    }
    std::string render(const std::string& key, int defaultIdx) {
        std::string t = C.str(key, 0, "");
        if (t.empty()) return "";
        std::string err;
        std::string r = renderTemplate(t, [this](const std::string& k) { return lookup(k); }, defaultIdx, &err);
        if (!err.empty() && templErr.empty()) templErr = key + ": " + err;
        return r;
    }

    json perFilament(const std::string& key, const std::string& fallbackKey) {
        json a = json::array();
        for (int i = 0; i < nfil; ++i) {
            double v = C.num(key, i, 0);
            if (v == 0) v = C.num(fallbackKey, i, 0);
            a.push_back(v);
        }
        return a;
    }
    double outerWallVolumetric(int f) {
        double v = C.num("outer_wall_speed", 0, 200) * mm3PerMm(C.num("outer_wall_line_width", 0, 0.42), C.num("layer_height", 0, 0.2));
        return std::min(v, C.num("filament_max_volumetric_speed", f, 20));
    }

    void toolChange(int nt, bool firstLayer) {
        int old = tool;
        retract();
        lift();
        double grab = C.num("grab_length", 0, 0) * 2.4;
        double wipe = 0;
        if (old >= 0) {
            wipe = C.num("flush_volumes_matrix", old * nfil + nt, 280) * C.num("flush_multiplier", 0, 1);
            wipe = std::max(0.0, wipe - grab);
        }
        double flushLen = wipe / filArea;
        int count = std::min(4, (int)std::lround(wipe / 135.0));
        if (count == 0 && wipe > 0) count = 1;
        vars["previous_extruder"] = old;
        vars["next_extruder"] = nt;
        vars["current_extruder_id"] = 0;
        vars["next_extruder_id"] = 0;
        vars["current_filament_id"] = old;
        vars["next_filament_id"] = nt;
        vars["flush_length"] = flushLen;
        for (int k = 0; k < 4; ++k) vars["flush_length_" + std::to_string(k + 1)] = k < count ? flushLen / count : 0.0;
        vars["first_flush_volume"] = flushLen / 2;
        vars["second_flush_volume"] = flushLen / 2;
        auto temp = [&](int f) { return (int)std::lround(firstLayer ? C.num("nozzle_temperature_initial_layer", f, 220) : C.num("nozzle_temperature", f, 220)); };
        vars["old_filament_temp"] = old >= 0 ? temp(old) : 0;
        vars["new_filament_temp"] = temp(nt);
        vars["old_retract_length"] = old >= 0 ? C.num("retraction_length", 0, 0.8) : 0.0;
        vars["new_retract_length"] = C.num("retraction_length", 0, 0.8);
        vars["old_retract_length_toolchange"] = old >= 0 ? C.num("retract_length_toolchange", 0, 2) : 0.0;
        vars["new_retract_length_toolchange"] = C.num("retract_length_toolchange", 0, 2);
        vars["x_after_toolchange"] = x;
        vars["y_after_toolchange"] = y;
        vars["z_after_toolchange"] = layerZ;
        vars["layer_z"] = layerZ;
        vars["layer_num"] = layerIdx;
        vars["max_layer_z"] = maxLayerZ;
        vars["outer_wall_volumetric_speed"] = outerWallVolumetric(nt);
        vars["toolchange_count"] = res.toolChanges;
        vars["old_filament_e_feedrate"] = old >= 0 ? (int)(60.0 * C.num("filament_max_volumetric_speed", old, 20) / filArea) : 200;
        vars["new_filament_e_feedrate"] = (int)(60.0 * C.num("filament_max_volumetric_speed", nt, 20) / filArea);
        line("; CHANGE_FILAMENT " + std::to_string(old + 1) + " -> " + std::to_string(nt + 1));
        out += render("change_filament_gcode", nt);
        if (out.back() != '\n') out += '\n';
        tool = nt;
        res.toolChanges++;
        posKnown = false;
        zKnown = false;
        lifted = false;
        accel = -1;
        retracted = C.num("retract_length_toolchange", 0, 2);
        int keepFan = fan;
        fan = -1;
        if (keepFan >= 0) setFan(keepFan);
        if (old >= 0) {
            res.usedMm[nt] += flushLen;
            double dens = C.num("filament_density", nt, 1.24);
            res.flushG[nt] += flushLen * filArea / 1000.0 * dens;
            double fs = C.num("filament_flush_volumetric_speed", nt, 0);
            if (fs <= 0) fs = C.num("filament_max_volumetric_speed", nt, 20);
            time += C.num("machine_load_filament_time", 0, 25) + C.num("machine_unload_filament_time", 0, 29) + wipe / std::max(1.0, fs) + 15;
        }
        haveRole = false;
    }
};

std::string pctTime(double s) {
    int h = (int)(s / 3600), m = (int)(std::fmod(s, 3600) / 60), sec = (int)std::fmod(s, 60);
    std::ostringstream o;
    if (h) o << h << "h ";
    o << m << "m " << sec << "s";
    return o.str();
}

}  // namespace

GcodeOutput writeGcode(const PlateSlice& ps, const Config& C, const std::string& plateName) {
    Writer W(C);
    const int n = (int)ps.layers.size();
    W.totalLayers = n;
    if (n == 0) { W.res.warnings.push_back("Nothing to print on this plate."); return W.res; }

    // initial filament = first used on layer 0
    int initial = ps.layers[0].islands.empty() ? 0 : ps.layers[0].islands.front().filament - 1;
    std::string bed = C.str("curr_bed_type", 0, "Textured PEI Plate");
    std::string bk = bedKey(bed);
    double bed0 = C.num(bk + "_initial_layer", initial, 60), bedN = C.num(bk, initial, 60);
    for (auto& isl : ps.layers[0].islands) bed0 = std::max(bed0, C.num(bk + "_initial_layer", isl.filament - 1, 0));

    // template variables for start gcode
    json& V = W.vars;
    V["initial_extruder"] = initial;
    V["initial_no_support_extruder"] = initial;
    V["initial_tool"] = initial;
    V["current_extruder"] = initial;
    V["bed_temperature_initial_layer_single"] = (int)std::lround(bed0);
    V["bed_temperature_initial_layer_vector"] = std::to_string((int)std::lround(bed0));
    V["first_layer_print_min"] = json::array({ps.firstMinX, ps.firstMinY});
    V["first_layer_print_max"] = json::array({ps.firstMaxX, ps.firstMaxY});
    V["first_layer_print_size"] = json::array({ps.firstMaxX - ps.firstMinX, ps.firstMaxY - ps.firstMinY});
    V["first_layer_center_no_wipe_tower"] = json::array({(ps.firstMinX + ps.firstMaxX) / 2, (ps.firstMinY + ps.firstMaxY) / 2});
    V["flush_temperatures"] = W.perFilament("filament_flush_temp", "nozzle_temperature_range_high");
    V["flush_volumetric_speeds"] = W.perFilament("filament_flush_volumetric_speed", "filament_max_volumetric_speed");
    V["outer_wall_volumetric_speed"] = W.outerWallVolumetric(initial);
    V["max_layer_z"] = 0.0;
    V["layer_z"] = 0.0;
    V["layer_num"] = 0;
    V["total_layer_count"] = n;
    V["spiral_mode"] = 0;
    V["print_sequence"] = C.str("print_sequence", 0, "by layer");
    V["plate_name"] = plateName;
    V["in_head_wrap_detect_zone"] = false;
    V["is_extruder_used"] = json::array();
    for (int i = 0; i < W.nfil; ++i)
        V["is_extruder_used"].push_back(std::find(ps.filamentsUsed.begin(), ps.filamentsUsed.end(), i + 1) != ps.filamentsUsed.end());
    // head wrap detect zone (A1: rear-right corner)
    if (C.has("head_wrap_detect_zone") && C.j["head_wrap_detect_zone"].is_array() && !C.j["head_wrap_detect_zone"].empty()) {
        double zx0 = 1e9, zy0 = 1e9, zx1 = -1e9, zy1 = -1e9;
        for (auto& p : C.j["head_wrap_detect_zone"]) {
            std::string s = p.get<std::string>();
            auto xp = s.find('x');
            double px = std::atof(s.substr(0, xp).c_str()), py = std::atof(s.substr(xp + 1).c_str());
            zx0 = std::min(zx0, px); zx1 = std::max(zx1, px); zy0 = std::min(zy0, py); zy1 = std::max(zy1, py);
        }
        V["in_head_wrap_detect_zone"] = !(ps.maxX < zx0 || ps.minX > zx1 || ps.maxY < zy0 || ps.minY > zy1);
    }

    W.line("; EXECUTABLE_BLOCK_START");
    W.line("\x01" "M73_START" "\x01");
    {
        auto mi = [&](const char* k, double d) { return std::to_string((long)std::lround(C.num(k, 0, d))); };
        auto mf = [&](const char* k, double d) { char b[32]; std::snprintf(b, sizeof b, "%.2f", C.num(k, 0, d)); return std::string(b); };
        W.line("M201 X" + mi("machine_max_acceleration_x", 12000) + " Y" + mi("machine_max_acceleration_y", 12000) + " Z" +
               mi("machine_max_acceleration_z", 1500) + " E" + mi("machine_max_acceleration_e", 5000));
        W.line("M203 X" + mi("machine_max_speed_x", 500) + " Y" + mi("machine_max_speed_y", 500) + " Z" + mi("machine_max_speed_z", 30) + " E" +
               mi("machine_max_speed_e", 30));
        W.line("M204 P" + mi("machine_max_acceleration_extruding", 12000) + " R" + mi("machine_max_acceleration_retracting", 5000) + " T" +
               mi("machine_max_acceleration_travel", 12000));
        W.line("M205 X" + mf("machine_max_jerk_x", 9) + " Y" + mf("machine_max_jerk_y", 9) + " Z" + mf("machine_max_jerk_z", 3) + " E" +
               mf("machine_max_jerk_e", 3));
    }
    W.line("; FEATURE: Custom");
    W.line(";===== machine start gcode =====");
    W.out += W.render("machine_start_gcode", initial);
    if (W.out.back() != '\n') W.out += '\n';
    W.line("; MACHINE_START_GCODE_END");
    W.line("G90");
    W.line("G21");
    W.line("M83 ; use relative distances for extrusion");
    W.tool = initial;
    W.posKnown = false;
    W.zKnown = false;
    double prepareTime = 330;  // heating, leveling, purge on the A1
    W.time = 0;

    int closeFan = (int)C.num("close_fan_the_first_x_layers", initial, 1);
    for (int li = 0; li < n; ++li) {
        const LayerPlan& L = ps.layers[li];
        bool first = li == 0;
        W.layerIdx = li;
        W.layerZ = L.z;
        W.layerH = L.h;
        W.retract();
        W.line("; CHANGE_LAYER");
        W.line("; Z_HEIGHT: " + Writer::f3(L.z));
        W.line("; LAYER_HEIGHT: " + Writer::f3(L.h));
        W.maxLayerZ = std::max(W.maxLayerZ, L.z);
        W.vars["layer_num"] = li;
        W.vars["layer_z"] = L.z;
        W.vars["max_layer_z"] = W.maxLayerZ;
        W.lift();
        W.out += W.render("layer_change_gcode", W.tool);
        if (W.out.back() != '\n') W.out += '\n';
        W.line("\x01" "M73_" + std::to_string(li) + "\x01");
        W.markTimes.push_back(W.time);
        // timelapse / clog detection block (guarded on the printer by flags)
        std::string tl = W.render("time_lapse_gcode", W.tool);
        if (!tl.empty()) {
            W.out += tl;
            if (W.out.back() != '\n') W.out += '\n';
            W.posKnown = false;
            W.zKnown = false;
            W.lifted = false;
            W.accel = -1;
        }
        if (li == 1) {
            int t = (int)std::lround(C.num("nozzle_temperature", W.tool, 220));
            if (t != (int)std::lround(C.num("nozzle_temperature_initial_layer", W.tool, 220))) W.line("M104 S" + std::to_string(t));
            if (std::lround(bedN) != std::lround(bed0)) W.line("M140 S" + std::to_string((int)std::lround(bedN)));
        }

        // tool order for this layer
        std::vector<int> tools;
        for (auto& isl : L.islands)
            if (std::find(tools.begin(), tools.end(), isl.filament - 1) == tools.end()) tools.push_back(isl.filament - 1);
        std::sort(tools.begin(), tools.end());
        auto it = std::find(tools.begin(), tools.end(), W.tool);
        if (it != tools.end()) std::rotate(tools.begin(), it, it + 1);

        // layer time estimate for cooling / slowdown
        double est = 0;
        for (auto& isl : L.islands)
            for (auto& tp : isl.paths) {
                double len = 0;
                for (size_t k = 1; k < tp.pts.size(); ++k)
                    len += std::hypot((tp.pts[k].x - tp.pts[k - 1].x) / kScale, (tp.pts[k].y - tp.pts[k - 1].y) / kScale);
                int saveTool = W.tool;
                W.tool = isl.filament - 1;
                double v = W.roleSpeed(tp.role, first);
                W.tool = saveTool;
                est += len / std::max(1.0, v);
            }
        double slowT = 0, coolT = 0, fmin = 0, fmax = 0;
        for (int t : tools) {
            slowT = std::max(slowT, C.num("slow_down_layer_time", t, 6));
            coolT = std::max(coolT, C.num("fan_cooling_layer_time", t, 60));
            fmin = std::max(fmin, C.num("fan_min_speed", t, 60));
            fmax = std::max(fmax, C.num("fan_max_speed", t, 100));
        }
        W.speedFactor = (!first && est > 0 && est < slowT) ? est / slowT : 1.0;
        int fanPct;
        if (li < closeFan) fanPct = 0;
        else if (est <= slowT) fanPct = (int)fmax;
        else if (est >= coolT) fanPct = (int)fmin;
        else fanPct = (int)std::lround(fmax - (fmax - fmin) * (est - slowT) / std::max(1.0, coolT - slowT));
        W.setFan((int)std::lround(fanPct * 2.55));

        for (int t : tools) {
            if (t != W.tool) W.toolChange(t, first);
            // islands of this tool, nearest-first
            std::vector<const Island*> todo;
            for (auto& isl : L.islands) if (isl.filament - 1 == t) todo.push_back(&isl);
            while (!todo.empty()) {
                size_t best = 0;
                double bd = 1e300;
                for (size_t k = 0; k < todo.size(); ++k) {
                    const auto& p0 = todo[k]->paths.front().pts.front();
                    double d = W.posKnown ? std::hypot(p0.x / kScale - W.x, p0.y / kScale - W.y) : 0;
                    if (d < bd) { bd = d; best = k; }
                }
                const Island* isl = todo[best];
                todo.erase(todo.begin() + best);
                // within island: keep role groups in order, nearest-neighbour inside each group
                size_t i = 0;
                const auto& P = isl->paths;
                while (i < P.size()) {
                    size_t j = i;
                    while (j < P.size() && P[j].role == P[i].role) ++j;
                    std::vector<const ToolPath*> grp;
                    for (size_t k = i; k < j; ++k) grp.push_back(&P[k]);
                    bool open = !P[i].closed;
                    if (open) {
                        // already boustrophedon per region; greedy NN keeps travel short across sub-regions
                        while (!grp.empty()) {
                            size_t b = 0;
                            double bdist = 1e300;
                            for (size_t k = 0; k < grp.size(); ++k) {
                                const auto& a = grp[k]->pts.front();
                                const auto& e = grp[k]->pts.back();
                                double d1 = W.posKnown ? std::hypot(a.x / kScale - W.x, a.y / kScale - W.y) : 0;
                                double d2 = W.posKnown ? std::hypot(e.x / kScale - W.x, e.y / kScale - W.y) : 0;
                                double d = std::min(d1, d2);
                                if (d < bdist) { bdist = d; b = k; }
                                if (d < 1e-3) break;
                            }
                            W.extrudePath(*grp[b], first);
                            grp.erase(grp.begin() + b);
                        }
                    } else {
                        for (auto* tp : grp) W.extrudePath(*tp, first);
                    }
                    i = j;
                }
            }
        }
    }

    // end
    W.retract();
    W.vars["max_layer_z"] = W.maxLayerZ;
    W.vars["layer_z"] = W.maxLayerZ;
    W.line("; FEATURE: Custom");
    W.line(";===== machine end gcode =====");
    W.out += W.render("machine_end_gcode", W.tool);
    if (W.out.back() != '\n') W.out += '\n';
    W.line("M73 P100 R0");
    W.line("; EXECUTABLE_BLOCK_END");

    double model = W.time;
    double total = model + prepareTime + 30;
    W.res.modelSeconds = model;
    W.res.seconds = total;
    W.res.layers = n;
    if (!W.templErr.empty()) W.res.warnings.push_back("Template issue (" + W.templErr + ")");

    // progress markers
    std::string& g = W.out;
    auto replaceMarker = [&](const std::string& token, const std::string& with) {
        size_t p = g.find(token);
        if (p != std::string::npos) g.replace(p, token.size(), with);
    };
    replaceMarker("\x01M73_START\x01", "M73 P0 R" + std::to_string((int)std::ceil(total / 60)));
    for (int li = 0; li < n; ++li) {
        double t = prepareTime + W.markTimes[li];
        int pct = (int)std::floor(100.0 * t / total);
        int rem = (int)std::ceil((total - t) / 60);
        replaceMarker("\x01M73_" + std::to_string(li) + "\x01", "M73 P" + std::to_string(pct) + " R" + std::to_string(rem));
    }

    // weights
    double totMm = 0, totCm3 = 0, totG = 0;
    std::ostringstream lens, vols, wts, dens, dias;
    for (int i = 0; i < W.nfil; ++i) {
        double cm3 = W.res.usedMm[i] * W.filArea / 1000.0;
        double gr = cm3 * C.num("filament_density", i, 1.24);
        W.res.usedG[i] = gr;
        totMm += W.res.usedMm[i]; totCm3 += cm3; totG += gr;
        lens << (i ? "," : "") << Writer::f3(W.res.usedMm[i]);
        vols << (i ? "," : "") << Writer::f3(cm3);
        wts << (i ? "," : "") << Writer::f3(gr);
        dens << (i ? "," : "") << C.str("filament_density", i, "1.24");
        dias << (i ? "," : "") << C.str("filament_diameter", i, "1.75");
    }
    std::ostringstream h;
    h << "; HEADER_BLOCK_START\n";
    h << "; generated by A1 Slicer (iOS) with Bambu Lab A1 profiles\n";
    h << "; model printing time: " << pctTime(model) << "; total estimated time: " << pctTime(total) << "\n";
    h << "; total layer number: " << n << "\n";
    h << "; total filament length [mm] : " << lens.str() << "\n";
    h << "; total filament volume [cm^3] : " << vols.str() << "\n";
    h << "; total filament weight [g] : " << wts.str() << "\n";
    h << "; filament_density: " << dens.str() << "\n";
    h << "; filament_diameter: " << dias.str() << "\n";
    h << "; max_z_height: " << Writer::f3(W.maxLayerZ) << "\n";
    h << "; HEADER_BLOCK_END\n\n";
    h << "; CONFIG_BLOCK_START\n";
    for (const char* k : {"printer_model", "printer_settings_id", "print_settings_id", "curr_bed_type", "nozzle_diameter", "layer_height",
                          "initial_layer_print_height", "wall_loops", "sparse_infill_density", "sparse_infill_pattern", "top_shell_layers",
                          "bottom_shell_layers", "filament_type", "filament_colour", "filament_settings_id", "nozzle_temperature"}) {
        if (!C.has(k)) continue;
        const json& v = C.j[k];
        std::string s;
        if (v.is_array()) { for (size_t i = 0; i < v.size(); ++i) s += (i ? ";" : "") + (v[i].is_string() ? v[i].get<std::string>() : v[i].dump()); }
        else s = v.is_string() ? v.get<std::string>() : v.dump();
        h << "; " << k << " = " << s << "\n";
    }
    h << "; CONFIG_BLOCK_END\n\n";
    W.res.gcode = h.str() + g;
    return W.res;
}

}  // namespace a1
