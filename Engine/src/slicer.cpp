#include "slicer.hpp"

#include <algorithm>
#include <cmath>
#include <functional>
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

    // 4. toolpaths per layer
    out.layers.resize(n);
    std::vector<int> used;
    bool patternWarned = false;
    for (int i = 0; i < n; ++i) {
        LayerPlan& L = out.layers[i];
        L.z = zTop[i];
        L.h = zH[i];
        bool first = i == 0;
        for (size_t vi = 0; vi < nv; ++vi) {
            const Paths64& reg = R[vi][i];
            if (reg.empty() || area(reg) < 0.01) continue;
            const SliceSettings& S = (vols[vi].object < (int)objSet.size()) ? objSet[vols[vi].object] : base;
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
            auto addLoops = [&](const Paths64& ps, Role r, double w) {
                for (auto& p : ps) if (p.size() >= 3) isl.paths.push_back({r, w, true, p});
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
                auto lines = [&](const Paths64& ar, Role r, double w, double ang, double sp) {
                    if (ar.empty()) return;
                    Paths64 clipArea = offset(ar, -(w / 2) + ov * w);
                    for (auto& p : hatch(clipArea, ang, sp)) isl.paths.push_back({r, w, false, p});
                };
                double ang = (i % 2 == 0) ? S.solidAngle : S.solidAngle + 90;
                if (first) {
                    lines(solid, Role::Bottom, S.wFirst, ang, spacing(S.wFirst, L.h));
                } else {
                    lines(bottom, Role::Bottom, S.wSolid, ang, spacing(S.wSolid, L.h));
                    lines(internal, Role::Solid, S.wSolid, ang, spacing(S.wSolid, L.h));
                    if (!sparse.empty() && S.density > 0.001) {
                        double w = S.wSparse;
                        std::string pat = S.pattern;
                        if (pat == "line" || pat == "zig-zag" || pat == "alignedrectilinear") {
                            lines(sparse, Role::Sparse, w, (i % 2 == 0) ? 45 : 135, w / S.density);
                        } else {
                            if (pat != "grid" && pat != "crosshatch" && !patternWarned) {
                                out.warnings.push_back("Infill pattern \"" + pat + "\" isn't supported yet; using grid.");
                                patternWarned = true;
                            }
                            double sp = 2 * w / S.density;
                            lines(sparse, Role::Sparse, w, S.sparseAngle, sp);
                            lines(sparse, Role::Sparse, w, S.sparseAngle + 90, sp);
                        }
                    }
                    lines(top, Role::Top, S.wTop, (i % 2 == 0) ? S.topAngle : S.topAngle + 90, spacing(S.wTop, L.h));
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
        if (base.brimType == "outer_only" || base.brimType == "outer_and_inner") {
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
                for (int k = loopsN - 1; k >= 0; --k) {
                    Paths64 lp = offset(outer, base.brimGap + w / 2 + k * sp);
                    for (auto& p : lp)
                        if (IsPositive(p)) {
                            if (insideBed(p, base, 0.5)) b.paths.push_back({Role::Brim, w, true, p});
                            else edgeClipped = true;
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
        } else if (base.brimType == "brim_ears" || base.brimType == "inner_only") {
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
