// Turns sliced toolpaths into printer G-code using each printer's own start / filament-change / end templates.
//   kind "bambu":               single nozzle + AMS (purge into the chute), Bambu header, packaged as .gcode.3mf
//   kind "klipper_toolchanger": Snapmaker U1 (one head per filament, standby temperatures), Orca-style metadata, plain .gcode
#pragma once
#include <array>
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
    std::vector<double> usedMm;   // per G-code filament (AMS filament on Bambu, toolhead on tool changers)
    std::vector<double> usedG;
    std::vector<double> flushG;
    std::vector<std::string> warnings;
};

// One printable object, for Klipper's exclude_object (skip a failed part from the printer screen).
struct ObjectLabel {
    int object = -1;  // index in Project::objects (matches Island::object)
    std::string name;
    double cx = 0, cy = 0;
    std::vector<std::array<double, 2>> polygon;  // convex footprint
};

struct GcodeExtras {
    std::vector<int> toolOf;              // project filament (0-based) -> G-code filament; empty = identity
    std::vector<std::string> thumbnails;  // PNG files embedded as G-code thumbnails (Klipper printers)
    std::vector<ObjectLabel> labels;      // Klipper printers only
    std::vector<std::array<double, 4>> objectBoxes;  // x0,y0,x1,y1 of each object on the plate (bed coordinates)
};

GcodeOutput writeGcode(const PlateSlice& ps, const Config& cfg, const std::string& plateName, const GcodeExtras& extras = {});

std::string base64(const std::string& data);

}  // namespace a1
