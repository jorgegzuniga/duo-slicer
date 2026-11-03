#!/usr/bin/env python3
"""Checks that the OrcaSlicer settings the iPhone slicer acts on really change the G-code.

usage: check_settings.py ./a1cli project.3mf

Slices plate 0 for the Snapmaker U1 (plain G-code) and the X1 Carbon (.gcode.3mf) with one setting changed at a
time and compares against the defaults: ironing, infill patterns, surface patterns, elephant foot and X-Y
compensation, seam position, fuzzy skin, skirt height, inner brim, flow ratios and per-filament overrides.
Every sliced file also goes through check_gcode.py. Prints "settings check passed" when everything holds.
"""
import json
import os
import re
import subprocess
import sys
import tempfile
import zipfile

cli, project = sys.argv[1], sys.argv[2]
tmp = tempfile.mkdtemp()
here = os.path.dirname(os.path.abspath(__file__))
failures = []


def slice_(printer, opts, name):
    o = os.path.join(tmp, name + ".json")
    json.dump(opts, open(o, "w"))
    out = os.path.join(tmp, name + (".gcode" if printer == "snapmaker-u1" else ".gcode.3mf"))
    r = subprocess.run([cli, f"Resources/profiles/{printer}.json", project, "0", o, out], capture_output=True, text=True)
    try:
        summary = json.loads(r.stdout.strip().splitlines()[-1])
    except Exception:
        raise SystemExit(f"{name}: no summary\n{r.stdout}\n{r.stderr}")
    if not summary.get("ok"):
        raise SystemExit(f"{name}: {summary}")
    if out.endswith(".3mf"):
        z = zipfile.ZipFile(out)
        g = z.read([n for n in z.namelist() if n.endswith(".gcode")][0]).decode()
        gpath = out[:-4]
        open(gpath, "w").write(g)
    else:
        g = open(out).read()
        gpath = out
    args = [sys.executable, os.path.join(here, "check_gcode.py"), gpath]
    if printer == "snapmaker-u1":
        args += ["--bed", "0.5,1,270.5,271", "--tools", "4"]
    chk = subprocess.run(args, capture_output=True, text=True).stdout
    if "problems 0" not in chk:
        failures.append(f"{name}: check_gcode found problems\n{chk}")
    return summary, g


def features(g):
    """Extruded mm of filament per feature."""
    feat, out = None, {}
    for l in g.split("\n"):
        if l.startswith("; FEATURE: "):
            feat = l[11:].strip()
        elif l.startswith("G1 ") and " E" in l and feat:
            m = re.search(r" E(-?[0-9.]+)", l)
            if m and float(m.group(1)) > 0:
                out[feat] = out.get(feat, 0) + float(m.group(1))
    return out


def feature_moves(g, name):
    """(x, y) of extrusion moves of one feature, per layer."""
    feat, layer, out = None, -1, {}
    for l in g.split("\n"):
        if l.startswith("; CHANGE_LAYER") or l.startswith(";LAYER_CHANGE"):
            layer += 1
        elif l.startswith("; FEATURE: "):
            feat = l[11:].strip()
        elif l.startswith("G1 ") and " E" in l and feat == name:
            m = re.search(r"X(-?[0-9.]+) Y(-?[0-9.]+)", l)
            if m:
                out.setdefault(layer, []).append((float(m.group(1)), float(m.group(2))))
    return out


def first_layer_box(g):
    pts = feature_moves(g, "Outer wall")
    if not pts:
        return None
    first = pts[min(pts)]
    xs, ys = [p[0] for p in first], [p[1] for p in first]
    return max(xs) - min(xs), max(ys) - min(ys)


def check(cond, msg):
    print(("ok   " if cond else "FAIL ") + msg)
    if not cond:
        failures.append(msg)


U1 = "snapmaker-u1"
X1 = "bambu-x1c"
base_s, base = slice_(U1, {}, "base")
fb = features(base)

# ironing
_, g = slice_(U1, {"overrides": {"ironing_type": "top"}}, "ironing")
f = features(g)
check(f.get("Ironing", 0) > 0, "ironing_type top adds an Ironing pass")
check(f.get("Ironing", 0) < 0.5 * f.get("Top surface", 1), "ironing extrudes far less than the top surface")
_, g = slice_(U1, {"overrides": {"ironing_type": "topmost"}}, "ironing-topmost")
check(features(g).get("Ironing", 0) > 0, "ironing_type topmost irons the last layer")
_, g = slice_(X1, {"overrides": {"ironing_type": "top", "ironing_speed": "17"}}, "ironing-x1")
check("; FEATURE: Ironing" in g and "F1020" in g, "ironing on the X1 Carbon at ironing_speed (17 mm/s = F1020)")

# sparse infill patterns
for pat in ["gyroid", "cubic", "triangles", "tri-hexagon", "concentric", "alignedrectilinear", "line"]:
    s, g = slice_(U1, {"overrides": {"sparse_infill_pattern": pat, "sparse_infill_density": "20%"}}, "infill-" + pat)
    f = features(g)
    check(f.get("Sparse infill", 0) > 0 and not any("isn't supported" in w for w in s.get("warnings", [])),
          f"infill pattern {pat} prints sparse infill without a warning")
s, _ = slice_(U1, {"overrides": {"sparse_infill_pattern": "honeycomb"}}, "infill-honeycomb")
check(any("honeycomb" in w for w in s.get("warnings", [])), "an unsupported infill pattern says it prints as grid")
_, g10 = slice_(U1, {"overrides": {"sparse_infill_pattern": "gyroid", "sparse_infill_density": "10%"}}, "gyroid10")
_, g40 = slice_(U1, {"overrides": {"sparse_infill_pattern": "gyroid", "sparse_infill_density": "40%"}}, "gyroid40")
check(features(g40)["Sparse infill"] > 2.5 * features(g10)["Sparse infill"], "gyroid density scales the infill")

# surfaces
_, g = slice_(U1, {"overrides": {"top_surface_pattern": "concentric"}}, "top-concentric")
check(features(g).get("Top surface", 0) > 0 and g != base, "concentric top surface")
_, g = slice_(U1, {"overrides": {"top_solid_infill_flow_ratio": "0.8"}}, "topflow")
# (colour changes prime under the last feature label, so multi-colour plates land a little above 0.8)
check(0.78 < features(g)["Top surface"] / fb["Top surface"] < 0.86, "top surface flow ratio 0.8 scales top extrusion")
_, g = slice_(U1, {"overrides": {"bottom_solid_infill_flow_ratio": "120%"}}, "bottomflow")
check(features(g).get("Bottom surface", 0) > fb.get("Bottom surface", 0), "bottom surface flow ratio 120% adds bottom extrusion")

# dimensional compensation
_, g = slice_(U1, {"overrides": {"elefant_foot_compensation": "0"}}, "efc0")
b0 = first_layer_box(g)
_, g = slice_(U1, {"overrides": {"elefant_foot_compensation": "0.5"}}, "efc")
b1 = first_layer_box(g)
check(b0 and b1 and abs((b0[0] - b1[0]) - 1.0) < 0.15, f"elephant foot 0.5 mm shrinks the first layer by 1 mm across ({b0} -> {b1})")
_, g = slice_(U1, {"overrides": {"xy_contour_compensation": "0.3", "elefant_foot_compensation": "0"}}, "xyc")
b2 = first_layer_box(g)
check(b2 and abs((b2[0] - b0[0]) - 0.6) < 0.15, f"X-Y contour compensation 0.3 mm grows the part by 0.6 mm ({b0} -> {b2})")

# seams: back starts every outer wall loop at its back-most point
def loops(g, name):
    """Outer wall loops: (start, points) from the last position before each run of extrusions of that feature."""
    feat, pos, cur, out = None, None, None, []
    for l in g.split("\n"):
        if l.startswith("; FEATURE: "):
            feat = l[11:].strip()
            continue
        m = re.match(r"G[01] (?:.* )?X(-?[0-9.]+) Y(-?[0-9.]+)", l)
        if not m:
            continue
        p = (float(m.group(1)), float(m.group(2)))
        if " E" in l and feat == name:
            if cur is None:
                cur = (pos, [])
                out.append(cur)
            cur[1].append(p)
        else:
            cur = None
        pos = p
    return [c for c in out if c[0] and len(c[1]) >= 3]


_, g = slice_(U1, {"overrides": {"seam_position": "back"}}, "seam-back")
ls = loops(g, "Outer wall")
good = sum(1 for st, pts in ls if st[1] >= max(p[1] for p in pts) - 0.3)
check(ls and good == len(ls), f"seam_position back starts outer walls at the back ({good} of {len(ls)} loops)")

# fuzzy skin
_, g = slice_(U1, {"overrides": {"fuzzy_skin": "external", "fuzzy_skin_point_distance": "0.5"}}, "fuzzy")
n0 = sum(len(v) for v in feature_moves(base, "Outer wall").values())
n1 = sum(len(v) for v in feature_moves(g, "Outer wall").values())
check(n1 > 3 * n0, f"fuzzy skin adds points to the outer wall ({n0} -> {n1} moves)")

# skirt height, inner brim
_, g = slice_(U1, {"overrides": {"skirt_loops": "1", "skirt_height": "3"}}, "skirt3")
check(len(feature_moves(g, "Skirt")) == 3, "skirt_height 3 prints the skirt on three layers")
_, gi = slice_(U1, {"overrides": {"brim_type": "outer_and_inner"}}, "brim-inner")
_, go = slice_(U1, {"overrides": {"brim_type": "outer_only"}}, "brim-outer")
check(features(gi).get("Brim", 0) >= features(go).get("Brim", 0), "outer and inner brim prints at least the outer brim")

# per-filament override: F1's nozzle temperature only
_, g = slice_(U1, {"filament_overrides": [{"nozzle_temperature": "233", "nozzle_temperature_initial_layer": "233"}]}, "fil-override")
check(re.search(r"M10[49] .*S233", g) is not None, "a per-filament nozzle temperature reaches the G-code")
_, g = slice_(U1, {"overrides": {"outer_wall_speed": "41"}}, "speed")
check("F2460" in g, "outer_wall_speed 41 mm/s (F2460)")

if failures:
    print("\n".join(failures))
    sys.exit(1)
print("settings check passed")
