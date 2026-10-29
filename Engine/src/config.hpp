// Effective print configuration: A1 machine + quality preset + per-filament presets + project + user overrides.
#pragma once
#include <string>
#include <vector>

#include "nlohmann/json.hpp"
#include "slicer.hpp"

namespace a1 {

class Config {
public:
    nlohmann::json j = nlohmann::json::object();
    int nfil = 1;
    std::vector<std::string> filamentPresets;  // chosen preset name per project filament
    std::vector<std::string> filamentIds;      // e.g. GFA01

    bool has(const std::string& k) const { return j.contains(k) && !j[k].is_null(); }
    std::string str(const std::string& k, int idx = 0, const std::string& def = "") const;
    double num(const std::string& k, int idx = 0, double def = 0) const;
    // Values like "15%" relative to `base`; plain numbers returned as is.
    double numPct(const std::string& k, double base, int idx = 0, double def = 0) const;

    SliceSettings sliceSettings() const;
    SliceSettings sliceSettingsFor(const std::map<std::string, std::string>& objOverrides) const;
};

// bundle: a1-profiles.json; project cfg may be empty json.
// options: {"process": name, "filaments": [preset names], "overrides": {key: value}, "colors": [...]}
Config buildConfig(const nlohmann::json& bundle, const nlohmann::json& projectCfg, int nfil,
                   const std::vector<std::string>& colors, const std::vector<std::string>& types,
                   const std::vector<std::string>& settingIds, const nlohmann::json& options,
                   std::vector<std::string>& warnings);

std::string mapFilamentPreset(const nlohmann::json& bundle, const std::string& projectSettingId, const std::string& type);

}  // namespace a1
