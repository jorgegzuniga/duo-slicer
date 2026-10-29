// Planar slicer: mesh -> layers -> perimeters / solid / sparse toolpaths.
#pragma once
#include <functional>
#include <map>
#include <string>
#include <vector>

#include "clipper2/clipper.h"
#include "project.hpp"

namespace a1 {

constexpr double kScale = 10000.0;  // Clipper units per mm

enum class Role { Outer, Inner, Top, Bottom, Solid, Sparse, Skirt, Brim };
const char* roleName(Role r);

struct ToolPath {
    Role role;
    double width;            // mm
    bool closed;
    Clipper2Lib::Path64 pts; // scaled
};

// Everything one object prints in one filament on one layer.
struct Island {
    int object = 0;    // index in project objects
    int filament = 1;  // 1-based
    std::vector<ToolPath> paths;  // already in print order
};

struct LayerPlan {
    double z = 0;  // print_z (top of layer)
    double h = 0;  // layer height
    std::vector<Island> islands;
};

struct SliceSettings {
    double layerH = 0.2, firstH = 0.2;
    int walls = 2, topLayers = 5, bottomLayers = 3;
    double topThickness = 1.0, bottomThickness = 0.0;
    double density = 0.15;
    std::string pattern = "grid";
    double wOuter = 0.42, wInner = 0.45, wSparse = 0.45, wSolid = 0.42, wTop = 0.42, wFirst = 0.5;
    double infillOverlap = 0.15;  // fraction of inner width
    std::string brimType = "no_brim";
    double brimWidth = 5, brimGap = 0.1;
    int skirtLoops = 0;
    double skirtDistance = 2;
    double topAngle = 45, solidAngle = 45, sparseAngle = 45;
    std::string wallSequence = "inner wall/outer wall";
    // target printer bed (printable area) and an optional no-print box (e.g. the X1/P1 purge corner)
    double bedMinX = 0, bedMinY = 0, bedMaxX = 256, bedMaxY = 256;
    double exMinX = 0, exMinY = 0, exMaxX = 0, exMaxY = 0;
};

struct PlateSlice {
    std::vector<LayerPlan> layers;
    double maxZ = 0;
    double minX = 1e9, minY = 1e9, maxX = -1e9, maxY = -1e9;              // all extrusions
    double firstMinX = 1e9, firstMinY = 1e9, firstMaxX = -1e9, firstMaxY = -1e9;  // first layer
    std::vector<int> filamentsUsed;  // 1-based, sorted
    std::vector<std::string> warnings;
};

// Per-object setting overrides from model_settings (e.g. sparse_infill_density) are applied by the caller via objectSettings.
PlateSlice slicePlate(const Project& proj, int plate, const SliceSettings& base,
                      const std::vector<SliceSettings>& objectSettings,  // indexed like proj.objects (may be empty)
                      const std::function<void(double)>& progress);

}  // namespace a1
