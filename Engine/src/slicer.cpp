#include "slicer.hpp"

#include <algorithm>
#include <cmath>
#include <functional>
#include <random>
#include <unordered_map>

namespace a1 {
using namespace Clipper2Lib;

const char* roleName(Role r) {
    switch (r) {
        case Role::Outer: return "Outer wall";
        case Role::Inner: return "Inner wall";
        case Role::Top: return "Top surface";
        case Role::Bottom: return "Bottom surface";
        case Role::Solid: return "Internal solid infill";
        case Role::Sparse: return "Sparse infill";
        case Role::Skirt: return "Skirt";
        case Role::Brim: return "Brim";
        case Role::Ironing: return "Ironing";
    }
    return "";
}

namespace {

struct Key {
    int64_t x, y;
    bool operator==(const Key& o) const { return x == o.x && y == o.y; }
};
struct KeyHash {
    size_t operator()(const Key& k) const { return std::hash<int64_t>()(k.x * 1000003LL) ^ std::hash<int64_t>()(k.y); }
};

struct PlacedVolume {
    int object;
    int filament;
    std::vector<float> v;  // plate coords
    const std::vector<uint32_t>* tris;
    std::vector<float> tzmin, tzmax;
    float zmin = 1e9f, zmax = -1e9f;
};

double spacing(double w, double h) { return w - h * (1.0 - M_PI / 4.0); }

Paths64 offset(const Paths64& p, double mm) {
    if (p.empty()) return {};
    return InflatePaths(p, mm * kScale, JoinType::Miter, EndType::Polygon, 3.0);
}

Paths64 sliceVolume(const PlacedVolume& pv, double zs) {
    struct Seg { double ax, ay, bx, by; Key a, b; bool used = false; };
    std::vector<Seg> segs;
    const auto& T = *pv.tris;
    const float* V = pv.v.data();
    size_t nt = T.size() / 3;
    for (size_t t = 0; t < nt; ++t) {
        if (pv.tzmin[t] > zs || pv.tzmax[t] < zs) continue;
        const float* p[3] = {V + 3 * T[3 * t], V + 3 * T[3 * t + 1], V + 3 * T[3 * t + 2]};
        bool above[3] = {p[0][2] > zs, p[1][2] > zs, p[2][2] > zs};
        int na = above[0] + above[1] + above[2];
        if (na == 0 || na == 3) continue;
        double pts[2][2];
        int k = 0;
        for (int e = 0; e < 3 && k < 2; ++e) {
            const float* u = p[e];
            const float* w = p[(e + 1) % 3];
            if (above[e] == above[(e + 1) % 3]) continue;
            // canonical order so shared edges give bit-identical points
            if (u[0] > w[0] || (u[0] == w[0] && (u[1] > w[1] || (u[1] == w[1] && u[2] > w[2])))) std::swap(u, w);
            double tt = (zs - u[2]) / ((double)w[2] - u[2]);
            pts[k][0] = u[0] + tt * ((double)w[0] - u[0]);
            pts[k][1] = u[1] + tt * ((double)w[1] - u[1]);
            ++k;
        }
        if (k < 2) continue;
        double e1x = p[1][0] - p[0][0], e1y = p[1][1] - p[0][1], e1z = p[1][2] - p[0][2];
        double e2x = p[2][0] - p[0][0], e2y = p[2][1] - p[0][1], e2z = p[2][2] - p[0][2];
        double nx = e1y * e2z - e1z * e2y, ny = e1z * e2x - e1x * e2z;
        double dx = pts[1][0] - pts[0][0], dy = pts[1][1] - pts[0][1];
        if (dx * (-ny) + dy * nx < 0) { std::swap(pts[0][0], pts[1][0]); std::swap(pts[0][1], pts[1][1]); }
        Seg s;
        s.ax = pts[0][0]; s.ay = pts[0][1]; s.bx = pts[1][0]; s.by = pts[1][1];
        s.a = {(int64_t)std::llround(s.ax * 1e5), (int64_t)std::llround(s.ay * 1e5)};
        s.b = {(int64_t)std::llround(s.bx * 1e5), (int64_t)std::llround(s.by * 1e5)};
        if (s.a == s.b) continue;
        segs.push_back(s);
    }
    std::unordered_multimap<Key, int, KeyHash> byStart;
    byStart.reserve(segs.size() * 2);
    for (int i = 0; i < (int)segs.size(); ++i) byStart.emplace(segs[i].a, i);
    Paths64 loops;
    for (int i = 0; i < (int)segs.size(); ++i) {
        if (segs[i].used) continue;
        Path64 loop;
        int cur = i;
        Key start = segs[i].a;
        while (cur >= 0 && !segs[cur].used) {
            segs[cur].used = true;
            loop.emplace_back((int64_t)std::llround(segs[cur].ax * kScale), (int64_t)std::llround(segs[cur].ay * kScale));
            if (segs[cur].b == start) break;
            int next = -1;
            auto range = byStart.equal_range(segs[cur].b);
            for (auto it = range.first; it != range.second; ++it)
                if (!segs[it->second].used) { next = it->second; break; }
            if (next < 0) loop.emplace_back((int64_t)std::llround(segs[cur].bx * kScale), (int64_t)std::llround(segs[cur].by * kScale));
            cur = next;
        }
        if (loop.size() >= 3) loops.push_back(std::move(loop));
    }
    if (loops.empty()) return {};
    Paths64 u = Union(loops, FillRule::NonZero);
    return SimplifyPaths(u, 0.005 * kScale);
}

// Remove slivers narrower than `w`.
Paths64 opening(const Paths64& p, double w) {
    if (p.empty()) return p;
    return offset(offset(p, -w / 2), w / 2);
}

void rotatePt(double& x, double& y, double c, double s) {
    double nx = x * c - y * s, ny = x * s + y * c;
    x = nx; y = ny;
}

// Parallel lines at `angleDeg`, `sp` mm apart, clipped to `area`, in boustrophedon order.
Paths64 hatch(const Paths64& area, double angleDeg, double sp, double phase = 0) {
    if (area.empty() || sp <= 0) return {};
    double a = angleDeg * M_PI / 180.0, c = std::cos(-a), s = std::sin(-a);
    double minx = 1e18, maxx = -1e18, miny = 1e18, maxy = -1e18;
    for (auto& path : area)
        for (auto& pt : path) {
            double x = pt.x / kScale, y = pt.y / kScale;
            rotatePt(x, y, c, s);
            minx = std::min(minx, x); maxx = std::max(maxx, x); miny = std::min(miny, y); maxy = std::max(maxy, y);
        }
    Paths64 lines;
    double y0 = std::floor((miny - phase) / sp) * sp + phase + sp / 2;
    double c2 = std::cos(a), s2 = std::sin(a);
    for (double y = y0; y < maxy; y += sp) {
        double x1 = minx - 1, y1 = y, x2 = maxx + 1, y2 = y;
        rotatePt(x1, y1, c2, s2);
        rotatePt(x2, y2, c2, s2);
        lines.push_back({Point64((int64_t)std::llround(x1 * kScale), (int64_t)std::llround(y1 * kScale)),
                         Point64((int64_t)std::llround(x2 * kScale), (int64_t)std::llround(y2 * kScale))});
    }
    Clipper64 cl;
    cl.AddOpenSubject(lines);
    cl.AddClip(area);
    Paths64 closedSol, openSol;
    cl.Execute(ClipType::Intersection, FillRule::NonZero, closedSol, openSol);
    // order by line (rotated y), then along the line; alternate direction
    struct Item { double ry, rx; Path64 p; };
    std::vector<Item> items;
    for (auto& p : openSol) {
        if (p.size() < 2) continue;
        double x = (p.front().x + p.back().x) / 2.0 / kScale, y = (p.front().y + p.back().y) / 2.0 / kScale;
        rotatePt(x, y, c, s);
        // make every segment run +x in rotated frame
        double fx = p.front().x / kScale, fy = p.front().y / kScale, bx = p.back().x / kScale, by = p.back().y / kScale;
        rotatePt(fx, fy, c, s); rotatePt(bx, by, c, s);
        if (fx > bx) std::reverse(p.begin(), p.end());
        items.push_back({std::round(y / (sp * 0.5)), x, p});
    }
    std::sort(items.begin(), items.end(), [](const Item& l, const Item& r) { return l.ry != r.ry ? l.ry < r.ry : l.rx < r.rx; });
    Paths64 out;
    bool flip = false;
    double lastRy = -1e18;
    for (auto& it : items) {
        if (it.ry != lastRy) { flip = !flip; lastRy = it.ry; }
        if (!flip) std::reverse(it.p.begin(), it.p.end());
        out.push_back(it.p);
    }
    return out;
}

double area(const Paths64& p) { return Area(p) / (kScale * kScale); }

Path64 reversed(Path64 p) {
    std::reverse(p.begin(), p.end());
    return p;
}

// Outer edges move by `contour` mm and holes by `hole` mm (positive: outer edges out, holes bigger), as
// OrcaSlicer's X-Y contour / hole compensation. Islands inside holes are handled as their own contours.
void compensateNode(const PolyPath64& outer, double contour, double hole, Paths64& out) {
    Paths64 o = std::abs(contour) > 1e-6 ? offset({outer.Polygon()}, contour) : Paths64{outer.Polygon()};
    Paths64 hs;
    for (size_t i = 0; i < outer.Count(); ++i) hs.push_back(reversed(outer.Child(i)->Polygon()));
    if (!hs.empty() && std::abs(hole) > 1e-6) hs = offset(hs, hole);
    Paths64 piece = hs.empty() ? o : Difference(o, hs, FillRule::NonZero);
    out.insert(out.end(), piece.begin(), piece.end());
    for (size_t i = 0; i < outer.Count(); ++i)
        for (size_t k = 0; k < outer.Child(i)->Count(); ++k) compensateNode(*outer.Child(i)->Child(k), contour, hole, out);
}

Paths64 compensateXY(const Paths64& reg, double contour, double hole) {
    if (reg.empty() || (std::abs(contour) < 1e-6 && std::abs(hole) < 1e-6)) return reg;
    PolyTree64 tree;
    BooleanOp(ClipType::Union, FillRule::NonZero, reg, {}, tree);
    Paths64 pieces;
    for (size_t i = 0; i < tree.Count(); ++i) compensateNode(*tree.Child(i), contour, hole, pieces);
    Paths64 r = Union(pieces, FillRule::NonZero);
    return r.empty() ? reg : r;
}

// Fuzzy skin: points every ~`dist` mm along the loop, each pushed in or out by up to `thick` mm.
Path64 fuzz(const Path64& p, double thick, double dist, std::mt19937& rng) {
    if (p.size() < 3 || thick <= 0) return p;
    std::uniform_real_distribution<double> off(-thick, thick), jitter(0.6, 1.0);
    Path64 out;
    double carry = 0;
    for (size_t i = 0; i < p.size(); ++i) {
        const Point64& a = p[i];
        const Point64& b = p[(i + 1) % p.size()];
        double ax = a.x / kScale, ay = a.y / kScale, bx = b.x / kScale, by = b.y / kScale;
        double len = std::hypot(bx - ax, by - ay);
        if (len < 1e-6) continue;
        double nx = (by - ay) / len, ny = -(bx - ax) / len;
        double t = carry;
        while (t < len) {
            double r = off(rng);
            double x = ax + (bx - ax) * t / len + nx * r, y = ay + (by - ay) * t / len + ny * r;
            out.emplace_back((int64_t)std::llround(x * kScale), (int64_t)std::llround(y * kScale));
            t += dist * jitter(rng);
        }
        carry = t - len;
    }
    return out.size() >= 3 ? out : p;
}

// Concentric loops `sp` mm apart filling `ar`, outermost first, starting `first` mm inside its edge.
Paths64 concentricLoops(const Paths64& ar, double first, double sp) {
    Paths64 out;
    if (ar.empty() || sp <= 0) return out;
    Paths64 cur = offset(ar, -first);
    for (int k = 0; k < 2000 && !cur.empty(); ++k) {
        for (auto& p : cur) if (p.size() >= 3) out.push_back(p);
        cur = offset(cur, -sp);
    }
    return out;
}

// Gyroid infill: the gyroid surface sin x cos y + sin y cos z + sin z cos x = 0 cut at height z (marching squares),
// with `period` mm per repeat, clipped to `area`.
Paths64 gyroid(const Paths64& area, double z, double period) {
    if (area.empty() || period <= 0) return {};
    Rect64 bb = GetBounds(area);
    double x0 = bb.left / kScale - 1, y0 = bb.top / kScale - 1, x1 = bb.right / kScale + 1, y1 = bb.bottom / kScale + 1;
    if (y0 > y1) std::swap(y0, y1);
    double cell = std::max(0.12, period / 16.0);
    while (((x1 - x0) / cell + 2) * ((y1 - y0) / cell + 2) > 2.5e6) cell *= 1.4;
    int nx = (int)std::ceil((x1 - x0) / cell) + 1, ny = (int)std::ceil((y1 - y0) / cell) + 1;
    double k = 2 * M_PI / period;
    std::vector<double> sx(nx), cx(nx), sy(ny), cy(ny);
    for (int i = 0; i < nx; ++i) { sx[i] = std::sin(k * (x0 + i * cell)); cx[i] = std::cos(k * (x0 + i * cell)); }
    for (int j = 0; j < ny; ++j) { sy[j] = std::sin(k * (y0 + j * cell)); cy[j] = std::cos(k * (y0 + j * cell)); }
    double sz = std::sin(k * z), cz = std::cos(k * z);
    auto F = [&](int i, int j) { return sx[i] * cy[j] + sy[j] * cz + sz * cx[i]; };
    std::vector<double> v((size_t)nx * ny);
    for (int j = 0; j < ny; ++j)
        for (int i = 0; i < nx; ++i) {
            double f = F(i, j);
            v[(size_t)j * nx + i] = std::abs(f) < 1e-9 ? 1e-9 : f;
        }
    auto val = [&](int i, int j) { return v[(size_t)j * nx + i]; };
    const int64_t H = (int64_t)nx * ny;
    auto hEdge = [&](int i, int j) { return (int64_t)j * nx + i; };       // (i,j)-(i+1,j)
    auto vEdge = [&](int i, int j) { return H + (int64_t)j * nx + i; };   // (i,j)-(i,j+1)
    auto edgePoint = [&](int64_t e) {
        bool vert = e >= H;
        int64_t r = vert ? e - H : e;
        int i = (int)(r % nx), j = (int)(r / nx);
        double fa = val(i, j), fb = vert ? val(i, j + 1) : val(i + 1, j);
        double t = fa / (fa - fb);
        double x = x0 + (i + (vert ? 0 : t)) * cell, y = y0 + (j + (vert ? t : 0)) * cell;
        return Point64((int64_t)std::llround(x * kScale), (int64_t)std::llround(y * kScale));
    };
    std::vector<std::pair<int64_t, int64_t>> segs;
    for (int j = 0; j + 1 < ny; ++j)
        for (int i = 0; i + 1 < nx; ++i) {
            double a = val(i, j), b = val(i + 1, j), c = val(i + 1, j + 1), d = val(i, j + 1);
            int idx = (a > 0) | ((b > 0) << 1) | ((c > 0) << 2) | ((d > 0) << 3);
            if (idx == 0 || idx == 15) continue;
            int64_t e0 = hEdge(i, j), e1 = vEdge(i + 1, j), e2 = hEdge(i, j + 1), e3 = vEdge(i, j);
            bool centre = (a + b + c + d) > 0;
            switch (idx) {
                case 1: case 14: segs.push_back({e3, e0}); break;
                case 2: case 13: segs.push_back({e0, e1}); break;
                case 3: case 12: segs.push_back({e3, e1}); break;
                case 4: case 11: segs.push_back({e1, e2}); break;
                case 6: case 9: segs.push_back({e0, e2}); break;
                case 7: case 8: segs.push_back({e3, e2}); break;
                case 5:
                    if (centre) { segs.push_back({e0, e1}); segs.push_back({e2, e3}); }
                    else { segs.push_back({e3, e0}); segs.push_back({e1, e2}); }
                    break;
                case 10:
                    if (centre) { segs.push_back({e3, e0}); segs.push_back({e1, e2}); }
                    else { segs.push_back({e0, e1}); segs.push_back({e2, e3}); }
                    break;
            }
        }
    // chain segments into polylines through shared edge crossings
    std::unordered_map<int64_t, std::vector<int>> at;
    at.reserve(segs.size() * 2);
    for (int s = 0; s < (int)segs.size(); ++s) { at[segs[s].first].push_back(s); at[segs[s].second].push_back(s); }
    std::vector<bool> used(segs.size(), false);
    auto nextFrom = [&](int64_t e) -> int {
        auto it = at.find(e);
        if (it == at.end()) return -1;
        for (int s : it->second) if (!used[s]) return s;
        return -1;
    };
    Paths64 lines;
    for (int s0 = 0; s0 < (int)segs.size(); ++s0) {
        if (used[s0]) continue;
        used[s0] = true;
        std::vector<int64_t> fwd{segs[s0].first, segs[s0].second}, back;
        for (int64_t e = fwd.back();;) {
            int s = nextFrom(e);
            if (s < 0) break;
            used[s] = true;
            e = segs[s].first == e ? segs[s].second : segs[s].first;
            fwd.push_back(e);
        }
        for (int64_t e = fwd.front();;) {
            int s = nextFrom(e);
            if (s < 0) break;
            used[s] = true;
            e = segs[s].first == e ? segs[s].second : segs[s].first;
            back.push_back(e);
        }
        Path64 p;
        for (auto it = back.rbegin(); it != back.rend(); ++it) p.push_back(edgePoint(*it));
        for (int64_t e : fwd) p.push_back(edgePoint(e));
        if (p.size() >= 2) lines.push_back(SimplifyPath(p, 0.01 * kScale, false));
    }
    Clipper64 cl;
    cl.AddOpenSubject(lines);
    cl.AddClip(area);
    Paths64 closedSol, openSol;
    cl.Execute(ClipType::Intersection, FillRule::NonZero, closedSol, openSol);
    return openSol;
}

// Order open paths so each starts near where the last one ended (fewer, shorter travels).
Paths64 orderNearest(Paths64 ps) {
    Paths64 out;
    out.reserve(ps.size());
    std::vector<bool> done(ps.size(), false);
    Point64 cur = ps.empty() || ps[0].empty() ? Point64(0, 0) : ps[0].front();
    for (size_t n = 0; n < ps.size(); ++n) {
        size_t best = SIZE_MAX;
        bool flip = false;
        double bd = 1e300;
        for (size_t i = 0; i < ps.size(); ++i) {
            if (done[i] || ps[i].empty()) continue;
            double a = std::hypot((double)(ps[i].front().x - cur.x), (double)(ps[i].front().y - cur.y));
            double b = std::hypot((double)(ps[i].back().x - cur.x), (double)(ps[i].back().y - cur.y));
            if (a < bd) { bd = a; best = i; flip = false; }
            if (b < bd) { bd = b; best = i; flip = true; }
        }
        if (best == SIZE_MAX) break;
        done[best] = true;
        Path64 p = ps[best];
        if (flip) std::reverse(p.begin(), p.end());
        cur = p.back();
        out.push_back(std::move(p));
    }
    return out;
}

// Start a closed loop at its seam: the back-most point, a random one, or the one closest to `ref` (aligned).
void placeSeam(Path64& p, const std::string& seam, const Point64& ref, std::mt19937& rng) {
    if (p.size() < 3) return;
    size_t best = 0;
    if (seam == "back") {
        for (size_t i = 1; i < p.size(); ++i)
            if (p[i].y > p[best].y || (p[i].y == p[best].y && p[i].x < p[best].x)) best = i;
    } else if (seam == "random") {
        best = std::uniform_int_distribution<size_t>(0, p.size() - 1)(rng);
    } else {
        double bd = 1e300;
        for (size_t i = 0; i < p.size(); ++i) {
            double d = std::hypot((double)(p[i].x - ref.x), (double)(p[i].y - ref.y));
            if (d < bd) { bd = d; best = i; }
        }
    }
    std::rotate(p.begin(), p.begin() + best, p.end());
}

bool insideBed(const Path64& p, const SliceSettings& s, double margin) {
    bool ex = s.exMaxX > s.exMinX && s.exMaxY > s.exMinY;
    double x0 = 1e18, y0 = 1e18, x1 = -1e18, y1 = -1e18;
    for (auto& pt : p) {
        double x = pt.x / kScale, y = pt.y / kScale;
        if (x < s.bedMinX + margin || y < s.bedMinY + margin || x > s.bedMaxX - margin || y > s.bedMaxY - margin) return false;
        x0 = std::min(x0, x); x1 = std::max(x1, x); y0 = std::min(y0, y); y1 = std::max(y1, y);
    }
    // loops are convex-ish rings around parts: reject any whose box reaches into the no-print box
    if (ex && !(x1 < s.exMinX - margin || x0 > s.exMaxX + margin || y1 < s.exMinY - margin || y0 > s.exMaxY + margin)) {
        for (auto& pt : p) {
            double x = pt.x / kScale, y = pt.y / kScale;
            if (x > s.exMinX - margin && x < s.exMaxX + margin && y > s.exMinY - margin && y < s.exMaxY + margin) return false;
        }
    }
    return true;
}

}  // namespace

PlateSlice slicePlate(const Project& proj, int plateIdx, const SliceSettings& base, const std::vector<SliceSettings>& objSet,
                      const std::function<void(double)>& progress) {
    PlateSlice out;
    const Plate& plate = proj.plates.at(plateIdx);

    // 1. place volumes in printer coordinates
    std::vector<PlacedVolume> vols;
    for (int oi : plate.objects) {
        const Object& o = proj.objects[oi];
        for (auto& v : o.volumes) {
            PlacedVolume pv;
            pv.object = oi;
            pv.filament = v.filament;
            pv.tris = &v.tris;
            pv.v.resize(v.verts.size());
            for (size_t k = 0; k + 2 < v.verts.size(); k += 3) {
                double x, y, z;
                o.item.apply(v.verts[k], v.verts[k + 1], v.verts[k + 2], x, y, z);
                pv.v[k] = (float)(x - plate.ox);
                pv.v[k + 1] = (float)(y - plate.oy);
                pv.v[k + 2] = (float)z;
                pv.zmin = std::min(pv.zmin, (float)z);
                pv.zmax = std::max(pv.zmax, (float)z);
            }
            size_t nt = v.tris.size() / 3;
            pv.tzmin.resize(nt); pv.tzmax.resize(nt);
            for (size_t t = 0; t < nt; ++t) {
                float a = pv.v[3 * v.tris[3 * t] + 2], b = pv.v[3 * v.tris[3 * t + 1] + 2], c = pv.v[3 * v.tris[3 * t + 2] + 2];
                pv.tzmin[t] = std::min(a, std::min(b, c));
                pv.tzmax[t] = std::max(a, std::max(b, c));
            }
            out.maxZ = std::max(out.maxZ, (double)pv.zmax);
            vols.push_back(std::move(pv));
        }
    }
    if (vols.empty()) { out.warnings.push_back("This plate is empty."); return out; }

    // 2. layer heights
    const double h = base.layerH, h0 = base.firstH;
    int n = std::max(1, (int)std::ceil((out.maxZ - h0) / h - 1e-6) + 1);
    std::vector<double> zTop(n), zH(n);
    for (int i = 0; i < n; ++i) { zTop[i] = h0 + i * h; zH[i] = i == 0 ? h0 : h; }

    // 3. slice every volume
    size_t nv = vols.size();
    std::vector<std::vector<Paths64>> R(nv, std::vector<Paths64>(n));
    for (int i = 0; i < n; ++i) {
        double zs = zTop[i] - zH[i] / 2 + 1.37e-5;
        for (size_t vi = 0; vi < nv; ++vi)
            if (zs >= vols[vi].zmin && zs <= vols[vi].zmax) R[vi][i] = sliceVolume(vols[vi], zs);
        if (progress) progress(0.5 * (i + 1) / n);
    }
    // later volumes of the same object win where parts overlap
    for (size_t a = 0; a < nv; ++a)
        for (size_t b = a + 1; b < nv; ++b) {
            if (vols[a].object != vols[b].object) continue;
            for (int i = 0; i < n; ++i)
                if (!R[a][i].empty() && !R[b][i].empty()) R[a][i] = Difference(R[a][i], R[b][i], FillRule::NonZero);
        }

    // X-Y hole / contour compensation (per object settings)
    for (size_t vi = 0; vi < nv; ++vi) {
        const SliceSettings& S = (vols[vi].object < (int)objSet.size()) ? objSet[vols[vi].object] : base;
        if (std::abs(S.xyContour) < 1e-6 && std::abs(S.xyHole) < 1e-6) continue;
        for (int i = 0; i < n; ++i) R[vi][i] = compensateXY(R[vi][i], S.xyContour, S.xyHole);
    }

    // 4. toolpaths per layer
    out.layers.resize(n);
    std::vector<int> used;
    bool patternWarned = false, surfaceWarned = false;
    std::mt19937 rng(12345);
    std::vector<Point64> seamRef(nv);
    std::vector<bool> seamRefSet(nv, false);
    for (int i = 0; i < n; ++i) {
        LayerPlan& L = out.layers[i];
        L.z = zTop[i];
        L.h = zH[i];
        bool first = i == 0;
        for (size_t vi = 0; vi < nv; ++vi) {
            if (R[vi][i].empty() || area(R[vi][i]) < 0.01) continue;
            const SliceSettings& S = (vols[vi].object < (int)objSet.size()) ? objSet[vols[vi].object] : base;
            Paths64 reg = R[vi][i];
            // elephant foot: the first layer(s) shrink so their squish doesn't bulge past the walls above
            if (i < S.elephantFootLayers && S.elephantFoot > 1e-6) {
                double e = S.elephantFoot * (1.0 - (double)i / S.elephantFootLayers);
                Paths64 r2 = offset(reg, -e);
                if (!r2.empty() && area(r2) > 0.25 * area(reg)) reg = r2;
            }
            double we = first ? S.wFirst : S.wOuter, wi = first ? S.wFirst : S.wInner;
            double se = spacing(we, L.h), si = spacing(wi, L.h);
            Island isl;
            isl.object = vols[vi].object;
            isl.filament = vols[vi].filament;

            // walls
            std::vector<Paths64> loops;
            double innerEdge = 0;
            for (int k = 0; k < S.walls; ++k) {
                double c = k == 0 ? we / 2 : we / 2 + (se + si) / 2 + (k - 1) * si;
                Paths64 lp = offset(reg, -c);
                if (lp.empty()) break;
                loops.push_back(lp);
                innerEdge = c + (k == 0 ? se / 2 : si / 2);
            }
            if (S.seam == "aligned" && !seamRefSet[vi] && !loops.empty() && !loops[0].empty()) {
                const Path64& p0 = loops[0][0];
                Point64 b = p0[0];
                for (auto& q : p0) if (q.y > b.y) b = q;
                seamRef[vi] = b;
                seamRefSet[vi] = true;
            }
            bool fuzzLayer = S.fuzzy != "none" && (!first || S.fuzzyFirstLayer);
            bool seamed = S.seam == "back" || S.seam == "random" || S.seam == "aligned";
            auto addLoops = [&](const Paths64& ps, Role r, double w) {
                bool firstContour = true;
                for (auto& p0 : ps) {
                    if (p0.size() < 3) continue;
                    Path64 p = p0;
                    bool contour = IsPositive(p0);
                    if (fuzzLayer && (S.fuzzy == "allwalls" || (r == Role::Outer && (S.fuzzy == "all" || contour))))
                        p = fuzz(p, S.fuzzyThickness, S.fuzzyPointDist, rng);
                    ToolPath tp{r, w, true, p};
                    if (seamed) {
                        placeSeam(tp.pts, S.seam, seamRef[vi], rng);
                        tp.seamSet = true;
                        // the outer contour's seam leads the next layer's (aligned seams stack up)
                        if (S.seam == "aligned" && r == Role::Outer && contour && firstContour) { seamRef[vi] = tp.pts[0]; firstContour = false; }
                    }
                    isl.paths.push_back(std::move(tp));
                }
            };
            bool outerFirst = S.wallSequence == "outer wall/inner wall";
            if (outerFirst && !loops.empty()) addLoops(loops[0], Role::Outer, we);
            for (int k = (int)loops.size() - 1; k >= 1; --k) addLoops(loops[k], Role::Inner, wi);
            if (!outerFirst && !loops.empty()) addLoops(loops[0], Role::Outer, we);

            // fill surfaces
            Paths64 fillSurf = loops.empty() ? Paths64{} : offset(reg, -innerEdge);
            if (!fillSurf.empty()) {
                int T = std::max(S.topLayers, (int)std::ceil(S.topThickness / S.layerH - 1e-6));
                int B = std::max(S.bottomLayers, (int)std::ceil(S.bottomThickness / S.layerH - 1e-6));
                Paths64 up, down;
                bool upEmpty = false, downEmpty = false;
                for (int k = 1; k <= T; ++k) {
                    if (i + k >= n || R[vi][i + k].empty()) { upEmpty = true; break; }
                    up = k == 1 ? R[vi][i + k] : Intersect(up, R[vi][i + k], FillRule::NonZero);
                }
                for (int k = 1; k <= B; ++k) {
                    if (i - k < 0 || R[vi][i - k].empty()) { downEmpty = true; break; }
                    down = k == 1 ? R[vi][i - k] : Intersect(down, R[vi][i - k], FillRule::NonZero);
                }
                if (T == 0) { up = fillSurf; upEmpty = false; }
                if (B == 0) { down = fillSurf; downEmpty = false; }
                Paths64 sparse = (upEmpty || downEmpty || S.density >= 0.999) ? Paths64{}
                                 : Intersect(Intersect(fillSurf, up, FillRule::NonZero), down, FillRule::NonZero);
                sparse = opening(sparse, S.wSparse);
                Paths64 solid = Difference(fillSurf, sparse, FillRule::NonZero);
                Paths64 top = (i + 1 >= n) ? solid : Difference(solid, R[vi][i + 1], FillRule::NonZero);
                Paths64 bottom = first ? solid : Difference(solid, R[vi][i - 1], FillRule::NonZero);
                if (!first) bottom = opening(Difference(bottom, top, FillRule::NonZero), S.wSolid);
                top = first ? Paths64{} : opening(top, S.wTop);
                Paths64 internal = Difference(Difference(solid, top, FillRule::NonZero), bottom, FillRule::NonZero);

                double ov = S.infillOverlap;
                auto lines = [&](const Paths64& ar, Role r, double w, double ang, double sp, double phase = 0, double flow = 1.0) {
                    if (ar.empty()) return;
                    Paths64 clipArea = offset(ar, -(w / 2) + ov * w);
                    for (auto& p : hatch(clipArea, ang, sp, phase)) {
                        ToolPath tp{r, w, false, p};
                        tp.flow = flow;
                        isl.paths.push_back(std::move(tp));
                    }
                };
                auto loopsFill = [&](const Paths64& ar, Role r, double w, double sp, double flow = 1.0) {
                    for (auto& p : concentricLoops(ar, w / 2, sp)) {
                        ToolPath tp{r, w, true, p};
                        tp.flow = flow;
                        isl.paths.push_back(std::move(tp));
                    }
                };
                // solid surfaces: concentric loops or rectilinear lines (monotonic and aligned print as lines too)
                auto surface = [&](const Paths64& ar, Role r, double w, double ang, const std::string& pat, double flow) {
                    if (ar.empty()) return;
                    if (pat == "concentric") { loopsFill(ar, r, w, spacing(w, L.h), flow); return; }
                    if (pat != "monotonic" && pat != "monotonicline" && pat != "zig-zag" && pat != "alignedrectilinear" && pat != "rectilinear" &&
                        !pat.empty() && !surfaceWarned) {
                        out.warnings.push_back("Surface pattern \"" + pat + "\" isn't supported yet; using rectilinear.");
                        surfaceWarned = true;
                    }
                    double a = pat == "alignedrectilinear" ? S.solidAngle : ang;
                    lines(ar, r, w, a, spacing(w, L.h), 0, flow);
                };
                double ang = (i % 2 == 0) ? S.solidAngle : S.solidAngle + 90;
                if (first) {
                    surface(solid, Role::Bottom, S.wFirst, ang, S.bottomPattern, 1.0);
                } else {
                    surface(bottom, Role::Bottom, S.wSolid, ang, S.bottomPattern, S.bottomFlow);
                    surface(internal, Role::Solid, S.wSolid, ang, S.solidPattern, 1.0);
                    if (!sparse.empty() && S.density > 0.001) {
                        double w = S.wSparse, d = S.density;
                        std::string pat = S.pattern;
                        double z = L.z;
                        if (pat == "line" || pat == "zig-zag") {
                            lines(sparse, Role::Sparse, w, (i % 2 == 0) ? S.sparseAngle : S.sparseAngle + 90, w / d);
                        } else if (pat == "alignedrectilinear") {
                            lines(sparse, Role::Sparse, w, S.sparseAngle, w / d);
                        } else if (pat == "triangles" || pat == "tri-hexagon") {
                            double sp = 3 * w / d;
                            for (int k = 0; k < 3; ++k)
                                lines(sparse, Role::Sparse, w, S.sparseAngle + 60 * k, sp, (pat == "tri-hexagon" && k == 2) ? sp / 2 : 0);
                        } else if (pat == "cubic" || pat == "adaptivecubic" || pat == "supportcubic") {
                            // three line sets that shift with height, so the cells close up into cubes
                            double sp = 3 * w / d, shift = std::fmod(z * M_SQRT1_2, sp);
                            lines(sparse, Role::Sparse, w, S.sparseAngle, sp, shift);
                            lines(sparse, Role::Sparse, w, S.sparseAngle + 60, sp, sp - shift);
                            lines(sparse, Role::Sparse, w, S.sparseAngle + 120, sp, 0);
                        } else if (pat == "gyroid") {
                            Paths64 clipArea = offset(sparse, -(w / 2) + ov * w);
                            for (auto& p : orderNearest(gyroid(clipArea, z, 2.45 * w / d))) isl.paths.push_back({Role::Sparse, w, false, p});
                        } else if (pat == "concentric") {
                            loopsFill(sparse, Role::Sparse, w, w / d);
                        } else {
                            if (pat != "grid" && pat != "crosshatch" && !patternWarned) {
                                out.warnings.push_back("Infill pattern \"" + pat + "\" isn't supported yet; using grid.");
                                patternWarned = true;
                            }
                            double sp = 2 * w / d;
                            lines(sparse, Role::Sparse, w, S.sparseAngle, sp);
                            lines(sparse, Role::Sparse, w, S.sparseAngle + 90, sp);
                        }
                    }
                    double topAng = (i % 2 == 0) ? S.topAngle : S.topAngle + 90;
                    surface(top, Role::Top, S.wTop, topAng, S.topPattern, S.topFlow);
                    // ironing: a nearly dry second pass over the top surfaces
                    bool topmost = i + 1 >= n || R[vi][i + 1].empty();
                    bool iron = !top.empty() && (S.ironingType == "top" || S.ironingType == "solid" || (S.ironingType == "topmost" && topmost));
                    if (iron) {
                        Paths64 ia = offset(top, -(S.ironingInset + S.wTop / 2));
                        double flow = S.ironingFlow * std::min(1.0, S.ironingSpacing / std::max(0.05, S.wTop));
                        if (S.ironingPattern == "concentric") {
                            for (auto& p : concentricLoops(ia, 0, S.ironingSpacing)) {
                                ToolPath tp{Role::Ironing, S.wTop, true, p};
                                tp.flow = flow;
                                isl.paths.push_back(std::move(tp));
                            }
                        } else {
                            for (auto& p : hatch(ia, S.ironingAngle, S.ironingSpacing)) {
                                ToolPath tp{Role::Ironing, S.wTop, false, p};
                                tp.flow = flow;
                                isl.paths.push_back(std::move(tp));
                            }
                        }
                    }
                }
            }
            if (!isl.paths.empty()) {
                L.islands.push_back(std::move(isl));
                if (std::find(used.begin(), used.end(), vols[vi].filament) == used.end()) used.push_back(vols[vi].filament);
            }
        }
        if (progress) progress(0.5 + 0.45 * (i + 1) / n);
    }

    // 5. brim + skirt on the first layer
    if (!out.layers.empty()) {
        LayerPlan& L0 = out.layers[0];
        double w = base.wFirst, sp = spacing(w, L0.h);
        bool edgeClipped = false;
        bool outerBrim = base.brimType == "outer_only" || base.brimType == "outer_and_inner";
        bool innerBrim = base.brimType == "inner_only" || base.brimType == "outer_and_inner";
        if (outerBrim || innerBrim) {
            std::map<int, Paths64> objArea;
            std::map<int, std::pair<int, double>> objFil;  // object -> (filament, area)
            for (size_t vi = 0; vi < nv; ++vi) {
                if (R[vi][0].empty()) continue;
                int o = vols[vi].object;
                objArea[o] = Union(objArea[o], R[vi][0], FillRule::NonZero);
                double a = area(R[vi][0]);
                if (!objFil.count(o) || objFil[o].second < a) objFil[o] = {vols[vi].filament, a};
            }
            for (auto& kv : objArea) {
                Paths64 outer;
                for (auto& p : kv.second) if (IsPositive(p)) outer.push_back(p);
                Island b;
                b.object = kv.first;
                b.filament = objFil[kv.first].first;
                int loopsN = std::max(1, (int)std::floor(base.brimWidth / sp));
                for (int k = loopsN - 1; outerBrim && k >= 0; --k) {
                    Paths64 lp = offset(outer, base.brimGap + w / 2 + k * sp);
                    for (auto& p : lp)
                        if (IsPositive(p)) {
                            if (insideBed(p, base, 0.5)) b.paths.push_back({Role::Brim, w, true, p});
                            else edgeClipped = true;
                        }
                }
                // inner brim: loops inside the holes, as far in as the brim width or the hole allows
                if (innerBrim) {
                    Paths64 holes;
                    for (auto& p : kv.second) if (!IsPositive(p)) holes.push_back(reversed(p));
                    for (int k = loopsN - 1; k >= 0; --k) {
                        Paths64 lp = offset(holes, -(base.brimGap + w / 2 + k * sp));
                        for (auto& p : lp) if (IsPositive(p) && p.size() >= 3) b.paths.push_back({Role::Brim, w, true, p});
                    }
                }
                // brim goes first: prepend to that object's island of the same filament
                bool merged = false;
                for (auto& isl : L0.islands)
                    if (isl.object == b.object && isl.filament == b.filament) {
                        isl.paths.insert(isl.paths.begin(), b.paths.begin(), b.paths.end());
                        merged = true;
                        break;
                    }
                if (!merged && !b.paths.empty()) L0.islands.insert(L0.islands.begin(), b);
            }
        } else if (base.brimType == "brim_ears" || base.brimType == "painted") {
            out.warnings.push_back("Brim type \"" + base.brimType + "\" isn't supported yet; printing without a brim.");
        }
        if (base.skirtLoops > 0 && !L0.islands.empty()) {
            Path64 pts;
            for (auto& isl : L0.islands) for (auto& tp : isl.paths) for (auto& p : tp.pts) pts.push_back(p);
            // convex hull (monotone chain)
            std::sort(pts.begin(), pts.end(), [](const Point64& a, const Point64& b) { return a.x != b.x ? a.x < b.x : a.y < b.y; });
            auto cross = [](const Point64& o, const Point64& a, const Point64& b) {
                return (double)(a.x - o.x) * (double)(b.y - o.y) - (double)(a.y - o.y) * (double)(b.x - o.x);
            };
            Path64 hull(2 * pts.size());
            size_t k = 0;
            for (size_t i = 0; i < pts.size(); ++i) { while (k >= 2 && cross(hull[k - 2], hull[k - 1], pts[i]) <= 0) k--; hull[k++] = pts[i]; }
            for (size_t i = pts.size() - 1, t = k + 1; i > 0; --i) { while (k >= t && cross(hull[k - 2], hull[k - 1], pts[i - 1]) <= 0) k--; hull[k++] = pts[i - 1]; }
            hull.resize(k > 0 ? k - 1 : 0);
            if (hull.size() >= 3) {
                Island sk;
                sk.object = L0.islands.front().object;
                sk.filament = L0.islands.front().filament;
                for (int s = base.skirtLoops - 1; s >= 0; --s) {
                    Paths64 lp = InflatePaths({hull}, (base.skirtDistance + w / 2 + s * sp) * kScale, JoinType::Round, EndType::Polygon);
                    for (auto& p : lp) {
                        if (insideBed(p, base, 0.5)) sk.paths.push_back({Role::Skirt, w, true, p});
                        else edgeClipped = true;
                    }
                }
                L0.islands.front().paths.insert(L0.islands.front().paths.begin(), sk.paths.begin(), sk.paths.end());
                // taller skirt: the same loops on the next layers (a low wall that shields the first layers)
                for (int li = 1; li < base.skirtHeight && li < (int)out.layers.size(); ++li) {
                    LayerPlan& Ln = out.layers[li];
                    if (Ln.islands.empty()) break;
                    std::vector<ToolPath> up = sk.paths;
                    for (auto& tp : up) tp.width = base.wOuter;
                    Ln.islands.front().paths.insert(Ln.islands.front().paths.begin(), up.begin(), up.end());
                }
            }
        }
        if (edgeClipped) out.warnings.push_back("Parts sit close to the bed edge, so some skirt or brim loops were left out.");
    }

    // 6. stats
    std::sort(used.begin(), used.end());
    out.filamentsUsed = used;
    for (int i = 0; i < n; ++i)
        for (auto& isl : out.layers[i].islands)
            for (auto& tp : isl.paths)
                for (auto& p : tp.pts) {
                    double x = p.x / kScale, y = p.y / kScale;
                    out.minX = std::min(out.minX, x); out.maxX = std::max(out.maxX, x);
                    out.minY = std::min(out.minY, y); out.maxY = std::max(out.maxY, y);
                    if (i == 0) {
                        out.firstMinX = std::min(out.firstMinX, x); out.firstMaxX = std::max(out.firstMaxX, x);
                        out.firstMinY = std::min(out.firstMinY, y); out.firstMaxY = std::max(out.firstMaxY, y);
                    }
                }
    // drop empty trailing layers
    while (!out.layers.empty() && out.layers.back().islands.empty()) out.layers.pop_back();
    if (progress) progress(1.0);
    return out;
}

}  // namespace a1
