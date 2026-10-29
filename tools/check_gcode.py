#!/usr/bin/env python3
"""Sanity checks for G-code written by the engine.

usage: check_gcode.py file.gcode [--bed x0,y0,x1,y1] [--exclude x0,y0,x1,y1] [--height H] [--tools N]

Reports layers, extrusion totals and bounding boxes, then lists problems:
extrusion off the bed or inside the no-print box, unusually heavy extrusion, leftover template syntax,
NaN values, unbalanced exclude-object blocks, tool numbers out of range and odd temperatures.
Prints "problems N" (the self-tests look for "problems 0").
"""
import argparse
import math
import re

ap = argparse.ArgumentParser()
ap.add_argument("file")
ap.add_argument("--bed", default="0,0,256,256")
ap.add_argument("--exclude", default="")
ap.add_argument("--height", type=float, default=0)
ap.add_argument("--tools", type=int, default=0, help="tool changer: number of toolheads (T0..T{N-1})")
a = ap.parse_args()
bx0, by0, bx1, by1 = (float(v) for v in a.bed.split(","))
ex = [float(v) for v in a.exclude.split(",")] if a.exclude else None

g = open(a.file, encoding="utf-8", errors="replace").read().split("\n")
x = y = z = 0.0
e_tot = 0
ext_box = [1e9, 1e9, -1e9, -1e9]
trav_box = [1e9, 1e9, -1e9, -1e9]
zmin_ext, zmax_ext = 1e9, 0
bad = []
layer = -1
layer_e = {}
ext_moves = 0
maxF = 0
label_open = None
labels_defined = set()
tools_seen = set()
for i, l in enumerate(g):
    if l.startswith("; CHANGE_LAYER"):
        layer += 1
    c = l.split(";")[0].strip()
    if not c:
        continue
    if "nan" in c.lower() or "inf" in c.lower().split():
        bad.append((i, "NaN/inf " + l))
    if re.search(r"[{}]|\[[a-z_]+\]", c):
        bad.append((i, "template syntax left in G-code: " + l))
    if c.startswith("EXCLUDE_OBJECT_DEFINE"):
        m = re.search(r"NAME=(\S+)", c)
        labels_defined.add(m.group(1) if m else "")
    elif c.startswith("EXCLUDE_OBJECT_START"):
        m = re.search(r"NAME=(\S+)", c)
        if label_open:
            bad.append((i, "EXCLUDE_OBJECT_START inside " + label_open))
        label_open = m.group(1) if m else "?"
        if label_open not in labels_defined:
            bad.append((i, "object not defined: " + label_open))
    elif c.startswith("EXCLUDE_OBJECT_END"):
        if not label_open:
            bad.append((i, "EXCLUDE_OBJECT_END without start"))
        label_open = None
    m = re.match(r"^T(\d+)$", c)
    if m:
        tools_seen.add(int(m.group(1)))
        if a.tools and int(m.group(1)) >= a.tools:
            bad.append((i, "tool out of range " + l))
    m = re.match(r"^M10[49]\s(.*)", c)
    if m:
        s = re.search(r"\bS(-?[\d.]+)", m.group(1))
        if s and not (0 <= float(s.group(1)) <= 320):
            bad.append((i, "odd nozzle temperature " + l))
    m = re.match(r"G[01]\s(.*)", c)
    if not m:
        continue
    d = dict((t[0], float(t[1:])) for t in m.group(1).split() if t[0] in "XYZEF" and re.match(r"^-?[\d.]+$", t[1:]))
    nx, ny, nz, e = d.get("X", x), d.get("Y", y), d.get("Z", z), d.get("E", 0)
    if "F" in d:
        maxF = max(maxF, d["F"])
    if e > 0 and ("X" in d or "Y" in d) and layer >= 0:
        ext_moves += 1
        e_tot += e
        layer_e[layer] = layer_e.get(layer, 0) + e
        ext_box = [min(ext_box[0], nx), min(ext_box[1], ny), max(ext_box[2], nx), max(ext_box[3], ny)]
        zmin_ext, zmax_ext = min(zmin_ext, nz), max(zmax_ext, nz)
        if nx < bx0 - 0.01 or ny < by0 - 0.01 or nx > bx1 + 0.01 or ny > by1 + 0.01:
            bad.append((i, "extrude off bed " + l))
        if ex and ex[0] < nx < ex[2] and ex[1] < ny < ex[3]:
            bad.append((i, "extrude in no-print box " + l))
        if a.height and nz > a.height + 0.01:
            bad.append((i, "extrude above max height " + l))
        seglen = math.hypot(nx - x, ny - y)
        if seglen > 0 and e / seglen > 0.12:
            bad.append((i, "heavy extrusion %.3f mm/mm " % (e / seglen) + l))
    elif layer >= 0 and ("X" in d or "Y" in d):
        trav_box = [min(trav_box[0], nx), min(trav_box[1], ny), max(trav_box[2], nx), max(trav_box[3], ny)]
    x, y, z = nx, ny, nz
if label_open:
    bad.append((len(g), "EXCLUDE_OBJECT block left open: " + label_open))
print("layers", layer + 1, "extrusion moves", ext_moves, "E total %.1f mm" % e_tot)
print("extrude bbox", [round(v, 2) for v in ext_box], "z range", zmin_ext, zmax_ext)
print("travel bbox (incl templates)", [round(v, 2) for v in trav_box], "max F", maxF)
print("tools", sorted(tools_seen), "objects", len(labels_defined))
print("E per layer", [round(layer_e.get(k, 0)) for k in range(min(layer + 1, 400))])
print("problems", len(bad))
for b in bad[:12]:
    print(b)
