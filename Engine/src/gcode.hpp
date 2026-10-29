// Turns sliced toolpaths into Bambu Lab A1 G-code using the printer's own start / filament-change / end templates.
#pragma once
#include <string>
#include <vector>

#include "config.hpp"
#include "slicer.hpp"

namespace a1 {

struct GcodeOutput {
    std::string gcode;
    double seconds = 0;           // total estimate incl. prepare
    double modelSeconds = 0;      // printing only
    int layers = 0;
    int toolChanges = 0;
    std::vector<double> usedMm;   // per project filament (index 0 = filament 1)
    std::vector<double> usedG;
    std::vector<double> flushG;
    std::vector<std::string> warnings;
};

GcodeOutput writeGcode(const PlateSlice& ps, const Config& cfg, const std::string& plateName);

}  // namespace a1
