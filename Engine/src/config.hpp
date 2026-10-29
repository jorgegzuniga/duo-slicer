// Effective print configuration: printer machine preset + quality preset + per-filament presets + project + user overrides.
#pragma once
#include <map>
#include <string>
#include <vector>

#include "nlohmann/json.hpp"
#include "slicer.hpp"

namespace a1 {

class Config {
public:
    nlohmann::json j = nlohmann::json::object();
    int nfil = 1;                              // filaments as the G-code sees them (AMS slots or toolheads)
    std::vector<std::string> filamentPresets;  // chosen preset name per filament
    std::vector<std::string> filamentIds;      // e.g. GFA01

    // printer
    std::string kind = "bambu";  // "bambu" (single nozzle + AMS) or "klipper_toolchanger"
    std::string printerName, machineName, modelId;
    int tools = 1;
    int variantsPerExtruder = 1;
    double bedMinX = 0, bedMinY = 0, bedMaxX = 256, bedMaxY = 256, bedHeight = 256;
    double exMinX = 0, exMinY = 0, exMaxX = 0, exMaxY = 0;  // bed exclusion box (0 size = none)
    bool hasExclude() const { return exMaxX > exMinX && exMaxY > exMinY; }

    bool has(const std::string& k) const { return j.contains(k) && !j[k].is_null(); }
    std::string str(const std::string& k, int idx = 0, const std::string& def = "") const;
    double num(const std::string& k, int idx = 0, double def = 0) const;
    // Per-extruder machine/process values stored as [extruder x variant] arrays.
    double numExt(const std::string& k, int tool, double def = 0) const { return num(k, tool * variantsPerExtruder, def); }
    // Values like "15%" relative to `base`; plain numbers returned as is.
    double numPct(const std::string& k, double base, int idx = 0, double def = 0) const;

    // Bed temperature for filament `f` on the current plate type (0 if the filament has none for it).
    double bedTemp(int f, bool firstLayer) const;

    SliceSettings sliceSettings() const;
    SliceSettings sliceSettingsFor(const std::map<std::string, std::string>& objOverrides) const;
};

// Inputs per G-code filament (length = Config::nfil).
struct FilamentInput {
    std::string settingId;  // preset name from the source project (mapped to this printer's presets)
    std::string type;
    std::string color;
    std::string preset;     // explicit choice from the user (empty = map automatically)
};

// bundle: Resources/profiles/<printer>.json; projectCfg may be an empty object.
// options: {"process": name, "overrides": {key: value}}
Config buildConfig(const nlohmann::json& bundle, const nlohmann::json& projectCfg, const std::vector<FilamentInput>& filaments,
                   const nlohmann::json& options, std::vector<std::string>& warnings);

std::string mapFilamentPreset(const nlohmann::json& bundle, const std::string& projectSettingId, const std::string& type);

// Plate types the printer's PLA preset has bed temperatures for (e.g. "Textured PEI Plate").
std::vector<std::string> supportedBedTypes(const nlohmann::json& bundle);

}  // namespace a1
