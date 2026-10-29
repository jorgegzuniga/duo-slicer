// Loads Bambu Studio / generic 3MF projects into plates, objects and per-filament triangle volumes.
#pragma once
#include <array>
#include <map>
#include <memory>
#include <string>
#include <vector>

#include "nlohmann/json.hpp"
#include "zipio.hpp"

namespace a1 {

using json = nlohmann::json;

// 3MF affine transform, row-vector convention: p' = p * M  (m00 m01 m02 m10 m11 m12 m20 m21 m22 m30 m31 m32)
struct Mat {
    std::array<double, 12> m{1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0};
    static Mat parse(const std::string& s);
    void apply(double x, double y, double z, double& ox, double& oy, double& oz) const {
        ox = x * m[0] + y * m[3] + z * m[6] + m[9];
        oy = x * m[1] + y * m[4] + z * m[7] + m[10];
        oz = x * m[2] + y * m[5] + z * m[8] + m[11];
    }
    std::string str() const;
};

// Indexed triangle mesh for one filament inside one object, in object-local space (component transforms applied).
struct Volume {
    int filament = 1;  // 1-based project filament
    std::vector<float> verts;       // xyz
    std::vector<uint32_t> tris;     // indices
};

struct Object {
    std::string id;
    std::string name;
    Mat item;       // current placement (world coords of the project)
    Mat item0;      // as loaded
    std::vector<Volume> volumes;
    std::map<std::string, std::string> overrides;  // per-object settings (e.g. sparse_infill_density)
    int plate = 0;  // index into plates
};

struct Plate {
    int id = 1;
    std::string name;
    std::string thumb;  // zip path
    double ox = 0, oy = 0;
    std::vector<int> objects;  // indices into objects
};

struct Project {
    std::vector<Plate> plates;
    std::vector<Object> objects;
    json cfg;  // project_settings.config (may be empty)
    std::vector<std::string> colors, types, settingIds;
    std::unique_ptr<ZipReader> zip;
    std::string printerModel;
    double bedW = 256, bedD = 256;

    static std::unique_ptr<Project> load(const std::string& bytes);
    // Triangles of every volume on a plate in plate-local (printer) coordinates.
    void plateTriangles(int plate, std::vector<float>& xyz, std::vector<uint8_t>& fil) const;
    void objectBounds(const Object& o, const Mat& m, double mn[3], double mx[3]) const;
};

}  // namespace a1
