#include "gcode.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <ctime>
#include <set>
#include <sstream>

#include "templ.hpp"

namespace a1 {
using json = nlohmann::json;
using namespace Clipper2Lib;

std::string base64(const std::string& in) {
    static const char* tbl = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string out;
    out.reserve((in.size() + 2) / 3 * 4);
    size_t i = 0;
    for (; i + 2 < in.size(); i += 3) {
        unsigned v = ((unsigned char)in[i] << 16) | ((unsigned char)in[i + 1] << 8) | (unsigned char)in[i + 2];
        out += tbl[(v >> 18) & 63]; out += tbl[(v >> 12) & 63]; out += tbl[(v >> 6) & 63]; out += tbl[v & 63];
    }
    if (i < in.size()) {
        unsigned v = (unsigned char)in[i] << 16;
        if (i + 1 < in.size()) v |= (unsigned char)in[i + 1] << 8;
        out += tbl[(v >> 18) & 63];
        out += tbl[(v >> 12) & 63];
        out += i + 1 < in.size() ? tbl[(v >> 6) & 63] : '=';
        out += '=';
    }
    return out;
}

namespace {

double mm3PerMm(double w, double h) { return (w - h) * h + M_PI * h * h / 4.0; }

struct Checkpoint { double time; size_t offset; };

struct Writer {
    const Config& C;
    const GcodeExtras& X;
    bool tc;  // tool changer (one nozzle per filament)
    std::string out;
    GcodeOutput res;
    int nfil;
    double x = 0, y = 0, z = 0;
    bool posKnown = false, zKnown = false, lifted = false;
    std::vector<double> retracted;  // per nozzle
    std::vector<bool> toolUsed;
    std::vector<bool> parked;       // toolchanger: tool sits at standby temperature
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
    int totalLayers = 0;
    std::vector<double> markTimes;
    std::vector<Checkpoint> checkpoints;  // since the last tool change (for preheating the next tool)
    std::string templErr;
    std::map<std::string, json> globals;
    std::vector<double> modelMm;  // filament extruded into the print (no purge), per G-code filament
    double lastLayerMass = 0;

    Writer(const Config& c, const GcodeExtras& x) : C(c), X(x) {
        tc = c.kind == "klipper_toolchanger";
        nfil = c.nfil;
        res.usedMm.assign(nfil, 0);
        res.usedG.assign(nfil, 0);
        res.flushG.assign(nfil, 0);
        retracted.assign(std::max(nfil, 1), 0);
        modelMm.assign(std::max(nfil, 1), 0);
        toolUsed.assign(std::max(nfil, 1), false);
        parked.assign(std::max(nfil, 1), false);
        filArea = M_PI / 4 * std::pow(C.num("filament_diameter", 0, 1.75), 2);
        out.reserve(1 << 22);
    }

    int nozzle() const { return tc ? std::max(tool, 0) : 0; }
    // G-code filament for a 1-based project filament
    int gf(int projectFilament) const {
        int i = projectFilament - 1;
        if (X.toolOf.empty()) return i;
        return (i >= 0 && i < (int)X.toolOf.size() && X.toolOf[i] >= 0) ? X.toolOf[i] : 0;
    }
    // exclude_object labels (Klipper)
    int curLabel = -1;
    std::string labelName(int obj) const {
        for (auto& l : X.labels) if (l.object == obj) return l.name;
        return "";
    }
    void endLabel() {
        if (curLabel < 0) return;
        line("EXCLUDE_OBJECT_END NAME=" + labelName(curLabel));
        curLabel = -1;
    }
    void startLabel(int obj) {
        if (X.labels.empty() || obj == curLabel) return;
        endLabel();
        std::string n = labelName(obj);
        if (n.empty()) return;
        line("EXCLUDE_OBJECT_START NAME=" + n);
        curLabel = obj;
    }
    void line(const std::string& s) { out += s; out += '\n'; }
    static std::string f3(double v) { char b[32]; std::snprintf(b, sizeof b, "%.3f", v); std::string s = b; while (s.back() == '0') s.pop_back(); if (s.back() == '.') s.pop_back(); if (s == "-0") s = "0"; return s; }
    static std::string f5(double v) { char b[32]; std::snprintf(b, sizeof b, "%.5f", v); std::string s = b; while (s.back() == '0') s.pop_back(); if (s.back() == '.') s.pop_back(); if (s == "-0") s = "0"; return s; }

    // machine values that are per extruder on tool changers
    double mnum(const std::string& k, double def) const { return tc ? C.numExt(k, std::max(tool, 0), def) : C.num(k, 0, def); }

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

    double retractLen() {
        double len = mnum("retraction_length", 0.8);
        std::string fr = C.str("filament_retraction_length", tool, "nil");
        if (fr != "nil" && !fr.empty()) len = std::atof(fr.c_str());
        return len;
    }
    void retract() {
        if (tool < 0) return;
        double len = retractLen();
        double& r = retracted[nozzle()];
        if (r >= len - 1e-6 || len <= 0) return;
        double d = len - r;
        double sp = mnum("retraction_speed", 30);
        line("G1 E-" + f5(d) + " F" + std::to_string((int)(sp * 60)));
        time += d / sp;
        r = len;
    }
    void unretract() {
        double& r = retracted[nozzle()];
        if (r <= 0) return;
        double sp = mnum("deretraction_speed", 30);
        if (sp <= 0) sp = mnum("retraction_speed", 30);
        line("G1 E" + f5(r) + " F" + std::to_string((int)(sp * 60)));
        time += r / sp;
        r = 0;
    }
    double zhop() { return mnum("z_hop", 0.4); }
    void lift() {
        if (lifted || !zKnown) return;
        double hop = zhop();
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
        double minT = mnum("retraction_minimum_travel", 1);
        if (d > minT) { retract(); lift(); }
        double v = C.num("travel_speed", 0, 700);
        if (!posKnown && !zKnown) line("G1 Z" + f3(maxLayerZ + zhop()) + " F12000");
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
        if (tc) checkpoints.push_back({time, out.size()});
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
            modelMm[tool] += e;
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
        vars["position"] = json::array({x, y, zKnown ? z : maxLayerZ});
        std::string err;
        std::string r = renderTemplate(t, [this](const std::string& k) { return lookup(k); }, defaultIdx, &err, &globals);
        if (!err.empty() && templErr.empty()) templErr = key + ": " + err;
        return r;
    }
    void emitTemplate(const std::string& key, int idx) {
        std::string r = render(key, idx);
        if (r.empty()) return;
        out += r;
        if (out.back() != '\n') out += '\n';
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
    int nozzleTemp(int f, bool firstLayer) {
        return (int)std::lround(firstLayer ? C.num("nozzle_temperature_initial_layer", f, 220) : C.num("nozzle_temperature", f, 220));
    }

    double printedGrams() const {
        double g = 0;
        for (int i = 0; i < nfil; ++i) g += modelMm[i] * filArea / 1000.0 * C.num("filament_density", i, 1.24);
        return g;
    }
    // Bambu: long retraction before the cutter, per filament (filament presets may override the printer)
    void setCutVars(int f) {
        vars["retraction_distance_when_cut"] = C.num("retraction_distances_when_cut", f, 18);
        vars["long_retraction_when_cut"] = C.num("long_retractions_when_cut", f, 0) != 0;
    }

    void setToolVars(int old, int nt) {
        vars["previous_extruder"] = old;
        vars["next_extruder"] = nt;
        vars["current_extruder_id"] = 0;
        vars["next_extruder_id"] = tc ? nt : 0;
        vars["current_filament_id"] = old;
        vars["next_filament_id"] = nt;
        vars["layer_z"] = layerZ;
        vars["layer_num"] = layerIdx;
        vars["max_layer_z"] = maxLayerZ;
        vars["toolchange_count"] = res.toolChanges;
        vars["x_after_toolchange"] = x;
        vars["y_after_toolchange"] = y;
        vars["z_after_toolchange"] = layerZ;
        vars["current_nozzle_id"] = tc ? old : (old >= 0 ? 0 : -1);
        vars["next_nozzle_id"] = tc ? nt : 0;
        vars["next_hotend"] = tc ? nt : 0;
        vars["relative_e_axis"] = true;
        vars["fan_speed"] = 0;
        vars["wipe_avoid_perimeter"] = false;
        vars["wipe_avoid_pos_x"] = 110.0;
        vars["is_prime_tower_interface"] = false;
        vars["filament_tower_interface_purge_volume"] = 0.0;
        vars["filament_tower_interface_print_temp"] = -1;
        vars["wipe_tower_center_pos_x"] = 0.0;
        vars["wipe_tower_center_pos_y"] = 0.0;
        vars["wipe_tower_center_pos_valid"] = false;
        std::string variant = C.str("printer_extruder_variant", 0, "Direct Drive Standard");
        vars["old_extruder_variant"] = old >= 0 ? variant : "";
        vars["new_extruder_variant"] = variant;
    }

    // Bambu: single nozzle, AMS swaps filament and purges into the chute.
    void toolChangeBambu(int nt, bool firstLayer) {
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
        setToolVars(old, nt);
        vars["flush_length"] = flushLen;
        for (int k = 0; k < 4; ++k) vars["flush_length_" + std::to_string(k + 1)] = k < count ? flushLen / count : 0.0;
        vars["first_flush_volume"] = flushLen / 2;
        vars["second_flush_volume"] = flushLen / 2;
        vars["old_filament_temp"] = old >= 0 ? nozzleTemp(old, firstLayer) : 0;
        vars["new_filament_temp"] = nozzleTemp(nt, firstLayer);
        vars["old_retract_length"] = old >= 0 ? C.num("retraction_length", 0, 0.8) : 0.0;
        vars["new_retract_length"] = C.num("retraction_length", 0, 0.8);
        vars["old_retract_length_toolchange"] = old >= 0 ? C.num("retract_length_toolchange", 0, 2) : 0.0;
        vars["new_retract_length_toolchange"] = C.num("retract_length_toolchange", 0, 2);
        vars["outer_wall_volumetric_speed"] = outerWallVolumetric(nt);
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
        vars["current_extruder"] = nt;
        vars["current_filament_id"] = nt;
        setCutVars(nt);
        retracted[0] = C.num("retract_length_toolchange", 0, 2);
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

    // Tool changer: park the old head (standby temperature), pick the next one.
    void toolChangeTC(int nt, bool firstLayer) {
        int old = tool;
        bool ooze = C.num("ooze_prevention", 0, 0) > 0;
        double delta = C.num("standby_temperature_delta", 0, -5);
        double preheat = C.num("preheat_time", 0, 0);
        // preheat the next head ahead of time if it was parked
        if (ooze && preheat > 0 && nt >= 0 && (parked[nt] || !toolUsed[nt]) && !checkpoints.empty()) {
            size_t pick = 0;
            for (size_t i = 0; i < checkpoints.size(); ++i)
                if (checkpoints[i].time <= time - preheat) pick = i;
            std::string cmd = "M104 S" + std::to_string(nozzleTemp(nt, firstLayer)) + " T" + std::to_string(nt) + " ;preheat\n";
            out.insert(checkpoints[pick].offset, cmd);
        }
        if (old >= 0) {
            double rl = C.numExt("retract_length_toolchange", old, 0);
            double& r = retracted[old];
            if (rl > r) {
                double sp = mnum("retraction_speed", 30);
                line("G1 E-" + f5(rl - r) + " F" + std::to_string((int)(sp * 60)));
                time += (rl - r) / sp;
                r = rl;
            }
        }
        lift();
        setToolVars(old, nt);
        line("; CHANGE_TOOL " + std::to_string(old) + " -> " + std::to_string(nt));
        emitTemplate("change_filament_gcode", nt);
        bool wasParked = parked[nt];
        tool = nt;
        vars["current_extruder"] = nt;
        toolUsed[nt] = true;
        parked[nt] = false;
        res.toolChanges++;
        posKnown = false;
        zKnown = false;
        lifted = false;
        accel = -1;
        if (ooze && old >= 0) {
            std::string idle = C.str("idle_temperature", old, "nil");
            int sb = (idle != "nil" && !idle.empty() && std::atof(idle.c_str()) > 0) ? (int)std::lround(std::atof(idle.c_str()))
                                                                                     : std::max(0, nozzleTemp(old, firstLayer) + (int)std::lround(delta));
            line("M104 S" + std::to_string(sb) + " T" + std::to_string(old) + " ;cooldown");
            parked[old] = true;
        }
        int keepFan = fan;
        fan = -1;
        if (keepFan >= 0) setFan(keepFan);
        time += C.num("machine_tool_change_time", 0, 5) + (wasParked ? 12 : 45) + 5;
        checkpoints.clear();
        haveRole = false;
    }

    void toolChange(int nt, bool firstLayer) {
        endLabel();
        if (tc) toolChangeTC(nt, firstLayer);
        else toolChangeBambu(nt, firstLayer);
    }
};

std::string hms(double s) {
    int h = (int)(s / 3600), m = (int)(std::fmod(s, 3600) / 60), sec = (int)std::fmod(s, 60);
    std::ostringstream o;
    if (h) o << h << "h ";
    o << m << "m " << sec << "s";
    return o.str();
}

bool pngSize(const std::string& png, int& w, int& h) {
    if (png.size() < 24 || png.compare(1, 3, "PNG") != 0) return false;
    auto be = [&](size_t o) { return ((unsigned char)png[o] << 24) | ((unsigned char)png[o + 1] << 16) | ((unsigned char)png[o + 2] << 8) | (unsigned char)png[o + 3]; };
    w = (int)be(16);
    h = (int)be(20);
    return w > 0 && h > 0;
}

}  // namespace

GcodeOutput writeGcode(const PlateSlice& ps, const Config& C, const std::string& plateName, const GcodeExtras& X) {
    Writer W(C, X);
    const int n = (int)ps.layers.size();
    W.totalLayers = n;
    if (n == 0) { W.res.warnings.push_back("Nothing to print on this plate."); return W.res; }

    int initial = ps.layers[0].islands.empty() ? 0 : W.gf(ps.layers[0].islands.front().filament);
    double bed0 = C.bedTemp(initial, true), bedN = C.bedTemp(initial, false);
    for (auto& isl : ps.layers[0].islands) bed0 = std::max(bed0, C.bedTemp(W.gf(isl.filament), true));

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
    {
        // Orca's adaptive bed mesh: probe only the first layer's footprint (plus margin), clamped to the mesh range
        auto vec2 = [&](const char* k, double dx, double dy) {
            std::string v = C.str(k, 0, "");
            std::array<double, 2> r{dx, dy};
            size_t c = v.find_first_of(",x");
            if (!v.empty() && c != std::string::npos) { r[0] = std::atof(v.substr(0, c).c_str()); r[1] = std::atof(v.substr(c + 1).c_str()); }
            return r;
        };
        auto mmin = vec2("bed_mesh_min", -99999, -99999), mmax = vec2("bed_mesh_max", 99999, 99999), dist = vec2("bed_mesh_probe_distance", 50, 50);
        double margin = C.num("adaptive_bed_mesh_margin", 0, 0);
        double x0 = std::max(ps.firstMinX - margin, mmin[0]), y0 = std::max(ps.firstMinY - margin, mmin[1]);
        double x1 = std::min(ps.firstMaxX + margin, mmax[0]), y1 = std::min(ps.firstMaxY + margin, mmax[1]);
        if (x1 <= x0 || y1 <= y0) { x0 = mmin[0]; y0 = mmin[1]; x1 = mmax[0]; y1 = mmax[1]; }
        int cx = std::max(3, (int)std::ceil((x1 - x0) / std::max(1.0, dist[0])));
        int cy = std::max(3, (int)std::ceil((y1 - y0) / std::max(1.0, dist[1])));
        std::string algo = "bicubic";
        if (cx * cy <= 6) algo = "lagrange";
        else if (W.tc) { cx = std::max(cx, 4); cy = std::max(cy, 4); }
        V["adaptive_bed_mesh_min"] = json::array({x0, y0});
        V["adaptive_bed_mesh_max"] = json::array({x1, y1});
        V["bed_mesh_probe_count"] = json::array({cx, cy});
        V["bed_mesh_algo"] = algo;
    }
    V["flush_temperatures"] = W.perFilament("filament_flush_temp", "nozzle_temperature_range_high");
    V["flush_volumetric_speeds"] = W.perFilament("filament_flush_volumetric_speed", "filament_max_volumetric_speed");
    V["outer_wall_volumetric_speed"] = W.outerWallVolumetric(initial);
    V["max_layer_z"] = 0.0;
    V["layer_z"] = 0.0;
    V["layer_num"] = 0;
    V["total_layer_count"] = n;
    V["spiral_mode"] = 0;
    V["print_sequence"] = "by layer";  // the only sequence this slicer produces
    if (C.str("print_sequence", 0, "by layer") == "by object") W.res.warnings.push_back("Printing one object at a time isn't supported yet; printing layer by layer.");
    V["plate_name"] = plateName;
    V["in_head_wrap_detect_zone"] = false;
    V["is_extruder_used"] = json::array();
    for (int i = 0; i < W.nfil; ++i) {
        bool used = false;
        for (int f : ps.filamentsUsed) used = used || W.gf(f) == i;
        V["is_extruder_used"].push_back(used);
    }
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

    // values BambuStudio / Orca compute for the start and change templates
    {
        std::vector<int> usedG, firstG;
        for (int f : ps.filamentsUsed)
            if (std::find(usedG.begin(), usedG.end(), W.gf(f)) == usedG.end()) usedG.push_back(W.gf(f));
        for (auto& isl : ps.layers[0].islands)
            if (std::find(firstG.begin(), firstG.end(), W.gf(isl.filament)) == firstG.end()) firstG.push_back(W.gf(isl.filament));
        double chamber = 0, addFan = 0, minVit = 1e9;
        bool allBbl = true, tpu1 = false;
        for (int g : usedG) {
            chamber = std::max(chamber, C.num("chamber_temperatures", g, 0));
            addFan = std::max(addFan, C.num("additional_cooling_fan_speed", g, 0));
            minVit = std::min(minVit, C.num("temperature_vitrification", g, 1e9));
            allBbl = allBbl && C.str("filament_vendor", g, "") == "Bambu Lab";
        }
        for (int g : firstG) tpu1 = tpu1 || C.str("filament_type", g, "") == "TPU";
        V["overall_chamber_temperature"] = (int)std::lround(chamber);
        V["chamber_temperature"] = json::array({(int)std::lround(chamber)});
        V["max_additional_fan"] = addFan;
        if (minVit < 1e9) V["min_vitrification_temperature"] = (int)std::lround(minVit);
        V["is_all_bbl_filament"] = allBbl;
        V["has_tpu_in_first_layer"] = tpu1;
        V["max_print_z"] = (int)std::ceil(ps.layers.back().z - 1e-9);
        V["bbl_bed_temperature_gcode"] = false;
        // flat prints on big beds keep the chamber warm (BambuStudio's threshold, using the first layer's footprint)
        {
            double bw = C.bedMaxX - C.bedMinX, bd = C.bedMaxY - C.bedMinY;
            double thr = 40000.0;
            if (bw > 260 && bd > 260) { double l = std::max(bw, bd) - 70.0; thr = l * l; }
            double area = (ps.firstMaxX - ps.firstMinX) * (ps.firstMaxY - ps.firstMinY);
            V["hold_chamber_temp_for_flat_print"] = n == 1 && area > thr;
        }
        int nn = W.tc ? W.nfil : 1;
        json nd = json::array(), nvt = json::array();
        for (int i = 0; i < nn; ++i) { nd.push_back(C.num("nozzle_diameter", i, 0.4)); nvt.push_back("Standard"); }
        V["nozzle_diameter_at_nozzle_id"] = nd;
        V["nozzle_volume_types"] = nvt;
        V["initial_filament_id"] = initial;
        V["initial_extruder_id"] = W.tc ? initial : 0;
        V["initial_nozzle_id"] = W.tc ? initial : 0;
        V["initial_no_support_filament_id"] = initial;
        V["initial_no_support_extruder_id"] = W.tc ? initial : 0;
        V["initial_no_support_nozzle_id"] = W.tc ? initial : 0;
        V["initial_no_support_tool"] = initial;
        V["current_hotend"] = W.tc ? initial : 0;
        V["initial_no_support_hotend"] = W.tc ? initial : 0;
        V["current_filament_id"] = initial;
        V["current_extruder_id"] = W.tc ? initial : 0;
        V["current_nozzle_id"] = W.tc ? initial : 0;
        V["current_object_idx"] = 0;
        V["most_used_physical_extruder_id"] = 0;
        V["curr_physical_extruder_id"] = 0;
        V["clear_to_x0"] = true;  // layer-by-layer printing never leaves parts in the way
        V["relative_e_axis"] = true;
        V["wipe_tower_center_pos_x"] = -1.0;
        V["wipe_tower_center_pos_y"] = -1.0;
        V["wipe_tower_center_pos_valid"] = false;
        W.setCutVars(initial);
        // Bambu X1/P1: route from the filament cutter to the purge chute around the parts (BambuStudio's get_path_of_change_filament)
        std::array<double, 6> tp{54, 0, 54, 0, 54, 245};
        std::vector<std::array<double, 2>> excl;
        if (C.has("bed_exclude_area") && C.j["bed_exclude_area"].is_array())
            for (auto& p : C.j["bed_exclude_area"]) {
                std::string t = p.is_string() ? p.get<std::string>() : "";
                size_t xp = t.find('x');
                if (xp != std::string::npos) excl.push_back({std::atof(t.substr(0, xp).c_str()), std::atof(t.substr(xp + 1).c_str())});
            }
        if (excl.size() == 4 && usedG.size() > 1) {
            double sx = 30, ex = 54, ey = 245;  // start_end_points default (30,-3) (54,245)
            if (C.has("start_end_points") && C.j["start_end_points"].is_array() && C.j["start_end_points"].size() == 2) {
                auto pt = [&](int i) {
                    std::string t = C.j["start_end_points"][i].get<std::string>();
                    size_t xp = t.find('x');
                    return std::array<double, 2>{std::atof(t.substr(0, xp).c_str()), std::atof(t.substr(xp + 1).c_str())};
                };
                sx = pt(0)[0];
                ex = pt(1)[0];
                ey = pt(1)[1];
            }
            double cutY = excl[2][1] + 2;
            bool fromLeft = true;
            std::vector<std::pair<double, double>> iv;
            for (auto& b : X.objectBoxes) {
                if (b[0] < sx && b[1] < cutY) fromLeft = false;
                std::pair<double, double> sc{b[0] - 2, b[2] + 2};
                std::vector<std::pair<double, double>> nv;
                bool hit = false;
                std::pair<double, double> merged;
                for (auto& o : iv) {
                    if (o.second >= sc.first && o.first <= sc.second) {
                        merged = hit ? std::make_pair(std::min(o.first, merged.first), std::max(o.second, merged.second))
                                     : std::make_pair(std::min(o.first, sc.first), std::max(o.second, sc.second));
                        hit = true;
                    } else {
                        nv.push_back(o);
                    }
                }
                if (hit) { nv.push_back(merged); iv = nv; }
                else iv.push_back(sc);
            }
            std::sort(iv.begin(), iv.end());
            std::vector<std::pair<double, double>> av;
            double start = 0;
            for (auto& o : iv) {
                if (o.first > start) av.push_back({start, o.first});
                start = o.second;
            }
            av.push_back({start, 255});
            double path = 255;
            for (auto& a : av) {
                if (a.first > ex) {
                    double dist = a.first - ex;
                    path = std::fabs(ex - path) < dist ? path : a.first;
                    break;
                }
                if (a.second >= ex) { path = ex; break; }
                if (!fromLeft && a.second < sx) continue;
                path = a.second;
            }
            if (path < sx) tp = {sx, cutY, path, cutY, path, ey};
            else tp = {path, 0, path, 0, path, ey};
        }
        for (int i = 0; i < 3; ++i) {
            V["travel_point_" + std::to_string(i + 1) + "_x"] = tp[i * 2];
            V["travel_point_" + std::to_string(i + 1) + "_y"] = tp[i * 2 + 1];
        }
    }

    W.line("; EXECUTABLE_BLOCK_START");
    if (W.tc)
        for (auto& l : X.labels) {
            std::string poly;
            for (auto& p : l.polygon) poly += (poly.empty() ? "" : ",") + std::string("[") + Writer::f3(p[0]) + "," + Writer::f3(p[1]) + "]";
            W.line("EXCLUDE_OBJECT_DEFINE NAME=" + l.name + " CENTER=" + Writer::f3(l.cx) + "," + Writer::f3(l.cy) + " POLYGON=[" + poly + "]");
        }
    W.line("\x01" "M73_START" "\x01");
    if (!W.tc) {
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
    W.toolUsed[initial] = true;
    W.posKnown = false;
    W.zKnown = false;
    double prepareTime = W.tc ? 420 : 330;  // heating, leveling, nozzle cleaning
    W.time = 0;

    int closeFan = (int)C.num("close_fan_the_first_x_layers", initial, 1);
    for (int li = 0; li < n; ++li) {
        const LayerPlan& L = ps.layers[li];
        bool first = li == 0;
        W.layerIdx = li;
        W.layerZ = L.z;
        W.layerH = L.h;
        W.endLabel();
        W.retract();
        W.vars["layer_num"] = li;
        W.vars["layer_z"] = L.z;
        if (W.tc) {
            W.vars["max_layer_z"] = W.maxLayerZ;
            W.emitTemplate("before_layer_change_gcode", W.tool);
        } else if (!C.str("before_layer_change_gcode", 0, "").empty()) {
            W.emitTemplate("before_layer_change_gcode", W.tool);
        }
        W.line("; CHANGE_LAYER");
        W.line("; Z_HEIGHT: " + Writer::f3(L.z));
        W.line("; LAYER_HEIGHT: " + Writer::f3(L.h));
        W.maxLayerZ = std::max(W.maxLayerZ, L.z);
        W.vars["max_layer_z"] = W.maxLayerZ;
        W.lift();
        {
            double accY = 1e10;
            if (C.has("machine_max_acceleration_y") && C.j["machine_max_acceleration_y"].is_array())
                for (size_t k = 0; k < C.j["machine_max_acceleration_y"].size(); ++k) accY = std::min(accY, C.num("machine_max_acceleration_y", (int)k, 1e10));
            if (accY >= 1e10) accY = C.num("machine_max_acceleration_y", 0, 10000);
            double force = C.num("machine_max_force_Y", 0, 0), bedMass = C.num("machine_bed_mass_Y", 0, 0), mass = W.printedGrams();
            double lim = accY;
            if (force > 1e-9 && bedMass > 1e-9 && mass > 1e-9) lim = std::min(force * 1e6 / (bedMass + mass), accY);
            W.vars["curr_y_acceleration_limit"] = lim;
            W.vars["curr_accumulated_mass"] = mass;
            W.vars["curr_layer_mass"] = std::max(0.0, mass - W.lastLayerMass);
            W.lastLayerMass = mass;
            W.vars["current_filament_id"] = W.tool;
            W.vars["current_extruder_id"] = W.tc ? W.tool : 0;
            W.vars["current_nozzle_id"] = W.tc ? W.tool : 0;
        }
        W.out += W.render("layer_change_gcode", W.tool);
        if (W.out.back() != '\n') W.out += '\n';
        W.line("\x01" "M73_" + std::to_string(li) + "\x01");
        W.markTimes.push_back(W.time);
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
            int t = W.nozzleTemp(W.tool, false);
            if (t != W.nozzleTemp(W.tool, true)) W.line(W.tc ? "M104 T" + std::to_string(W.tool) + " S" + std::to_string(t) : "M104 S" + std::to_string(t));
            if (std::lround(bedN) != std::lround(bed0)) W.line("M140 S" + std::to_string((int)std::lround(bedN)));
        }

        std::vector<int> tools;
        for (auto& isl : L.islands)
            if (std::find(tools.begin(), tools.end(), W.gf(isl.filament)) == tools.end()) tools.push_back(W.gf(isl.filament));
        std::sort(tools.begin(), tools.end());
        auto it = std::find(tools.begin(), tools.end(), W.tool);
        if (it != tools.end()) std::rotate(tools.begin(), it, it + 1);

        double est = 0;
        for (auto& isl : L.islands)
            for (auto& tp : isl.paths) {
                double len = 0;
                for (size_t k = 1; k < tp.pts.size(); ++k)
                    len += std::hypot((tp.pts[k].x - tp.pts[k - 1].x) / kScale, (tp.pts[k].y - tp.pts[k - 1].y) / kScale);
                int saveTool = W.tool;
                W.tool = W.gf(isl.filament);
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
            std::vector<const Island*> todo;
            for (auto& isl : L.islands) if (W.gf(isl.filament) == t) todo.push_back(&isl);
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
                if (W.tc) W.startLabel(isl->object);
                size_t i = 0;
                const auto& P = isl->paths;
                while (i < P.size()) {
                    size_t j = i;
                    while (j < P.size() && P[j].role == P[i].role) ++j;
                    std::vector<const ToolPath*> grp;
                    for (size_t k = i; k < j; ++k) grp.push_back(&P[k]);
                    if (!P[i].closed) {
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

    W.endLabel();
    W.retract();
    W.vars["max_layer_z"] = W.maxLayerZ;
    W.vars["layer_z"] = W.maxLayerZ;
    W.vars["layer_num"] = n - 1;
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

    double totG = 0;
    std::ostringstream lens, vols, wts, dens, dias;
    for (int i = 0; i < W.nfil; ++i) {
        double cm3 = W.res.usedMm[i] * W.filArea / 1000.0;
        double gr = cm3 * C.num("filament_density", i, 1.24);
        W.res.usedG[i] = gr;
        totG += gr;
        lens << (i ? "," : "") << Writer::f3(W.res.usedMm[i]);
        vols << (i ? "," : "") << Writer::f3(cm3);
        wts << (i ? "," : "") << Writer::f3(gr);
        dens << (i ? "," : "") << C.str("filament_density", i, "1.24");
        dias << (i ? "," : "") << C.str("filament_diameter", i, "1.75");
    }
    std::ostringstream h;
    h << "; HEADER_BLOCK_START\n";
    if (W.tc) {
        // Orca's header wording, so Moonraker and the printer's screen read time, filament and thumbnails
        std::time_t now = std::time(nullptr);
        char ts[64];
        std::strftime(ts, sizeof ts, "%Y-%m-%d at %H:%M:%S", std::gmtime(&now));
        h << "; generated by OrcaSlicer 2.3.1 (Duo Slicer) on " << ts << "\n";
    } else {
        h << "; generated by Duo Slicer (iOS) with " << C.printerName << " profiles\n";
    }
    h << "; model printing time: " << hms(model) << "; total estimated time: " << hms(total) << "\n";
    h << "; total layer number: " << n << "\n";
    h << "; total filament length [mm] : " << lens.str() << "\n";
    h << "; total filament volume [cm^3] : " << vols.str() << "\n";
    h << "; total filament weight [g] : " << wts.str() << "\n";
    h << "; filament_density: " << dens.str() << "\n";
    h << "; filament_diameter: " << dias.str() << "\n";
    h << "; max_z_height: " << Writer::f3(W.maxLayerZ) << "\n";
    h << "; HEADER_BLOCK_END\n\n";
    if (!W.tc) {
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
    bool anyThumb = false;
    for (auto& png : X.thumbnails) {
        int tw = 0, th = 0;
        if (!pngSize(png, tw, th)) continue;
        if (!anyThumb) h << "; THUMBNAIL_BLOCK_START\n";
        anyThumb = true;
        std::string b64 = base64(png);
        h << ";\n; thumbnail begin " << tw << "x" << th << " " << b64.size() << "\n";
        for (size_t i = 0; i < b64.size(); i += 78) h << "; " << b64.substr(i, 78) << "\n";
        h << "; thumbnail end\n;\n";
    }
    if (anyThumb) h << "; THUMBNAIL_BLOCK_END\n\n";
    std::ostringstream f;
    char tg[32];
    std::snprintf(tg, sizeof tg, "%.2f", totG);
    std::string lensC = lens.str(), volsC = vols.str(), wtsC = wts.str();
    for (std::string* t : {&lensC, &volsC, &wtsC}) {
        std::string o;
        for (char c : *t) { o += c; if (c == ',') o += ' '; }
        *t = o;
    }
    f << "\n; filament used [mm] = " << lensC << "\n";
    f << "; filament used [cm3] = " << volsC << "\n";
    f << "; filament used [g] = " << wtsC << "\n";
    f << "; total filament used [g] = " << tg << "\n";
    f << "; total layers count = " << n << "\n";
    f << "; estimated printing time (normal mode) = " << hms(total) << "\n\n";
    // full configuration, serialized the way Orca does (numbers joined with ',', strings with ';', newlines escaped)
    auto isNumLike = [](const std::string& v) {
        if (v == "nil") return true;
        if (v.empty()) return false;
        char* end = nullptr;
        std::strtod(v.c_str(), &end);
        if (end && *end == 0) return true;
        size_t x = v.find('x');  // points like 0.5x1
        if (x != std::string::npos && x > 0) {
            char* e1 = nullptr;
            std::string a = v.substr(0, x), b = v.substr(x + 1);
            std::strtod(a.c_str(), &e1);
            if (!(e1 && *e1 == 0)) return false;
            std::strtod(b.c_str(), &e1);
            return e1 && *e1 == 0 && !b.empty();
        }
        return false;
    };
    auto esc = [](const std::string& v) {
        std::string o;
        for (char c : v) {
            if (c == '\n') o += "\\n";
            else if (c == '\r') o += "\\r";
            else if (c == '\\') o += "\\\\";
            else o += c;
        }
        return o;
    };
    auto scalar = [](const json& v) { return v.is_string() ? v.get<std::string>() : v.dump(); };
    json full = C.j;
    full["first_layer_temperature"] = json::array();
    for (int i = 0; i < W.nfil; ++i) full["first_layer_temperature"].push_back(std::to_string(W.nozzleTemp(i, true)));
    f << "; CONFIG_BLOCK_START\n";
    for (auto& kv : full.items()) {
        const json& v = kv.value();
        std::string out;
        if (v.is_array()) {
            bool nums = true;
            for (auto& e : v) nums = nums && (e.is_number() || e.is_boolean() || (e.is_string() && isNumLike(e.get<std::string>())));
            for (size_t i = 0; i < v.size(); ++i) {
                std::string e = scalar(v[i]);
                if (!nums && (e.find_first_of(" ;\"") != std::string::npos || e.empty())) {
                    std::string q = "\"";
                    for (char c : e) { if (c == '"' || c == '\\') q += '\\'; q += c; }
                    e = q + "\"";
                }
                out += (i ? (nums ? "," : ";") : "") + esc(e);
            }
        } else {
            out = esc(scalar(v));
        }
        f << "; " << kv.key() << " = " << out << "\n";
    }
    f << "; CONFIG_BLOCK_END\n";
    W.res.gcode = h.str() + g + f.str();
    return W.res;
}

}  // namespace a1
